// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IMorpho} from "src/interfaces/IMorpho.sol";
import {IPool} from "@aave-v3-origin/interfaces/IPool.sol";

import {DataTypes} from "@aave-v3-origin/protocol/libraries/types/DataTypes.sol";
import {Types} from "src/libraries/Types.sol";
import {PoolLib} from "src/libraries/PoolLib.sol";

import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {ReserveConfiguration} from "@aave-v3-origin/protocol/libraries/configuration/ReserveConfiguration.sol";

import {ERC20, SafeTransferLib} from "@solmate/utils/SafeTransferLib.sol";

import "test/helpers/InternalTest.sol";
import {PositionsManagerInternal} from "src/PositionsManagerInternal.sol";
import {TestMarket, TestMarketLib} from "test/helpers/TestMarketLib.sol";

contract TestInternalEMode is InternalTest, PositionsManagerInternal {
    using PoolLib for IPool;
    using WadRayMath for uint256;
    using PercentageMath for uint256;
    using Math for uint256;
    using ConfigLib for Config;
    using SafeTransferLib for ERC20;
    using ReserveConfiguration for DataTypes.ReserveConfigurationMap;

    struct AssetData {
        uint16 ltvEMode;
        uint16 ltEMode;
    }

    function setUp() public virtual override {
        super.setUp();

        _defaultIterations = Types.Iterations(10, 10);
        _createMarket(dai, 0, 3_333);
        _createMarket(wbtc, 0, 3_333);
        _createMarket(usdc, 0, 3_333);
        _createMarket(wNative, 0, 3_333);

        ERC20(dai).approve(address(_pool), type(uint256).max);
        ERC20(wbtc).approve(address(_pool), type(uint256).max);
        ERC20(usdc).approve(address(_pool), type(uint256).max);
        ERC20(wNative).approve(address(_pool), type(uint256).max);

        _pool.supplyToPool(dai, 100 ether, _pool.getReserveNormalizedIncome(dai));
        _pool.supplyToPool(wbtc, 1e8, _pool.getReserveNormalizedIncome(wbtc));
        _pool.supplyToPool(usdc, 1e8, _pool.getReserveNormalizedIncome(usdc));
        _pool.supplyToPool(wNative, 1 ether, _pool.getReserveNormalizedIncome(wNative));
    }

    function testLtvLiquidationThresholdEMode(uint256 seed, uint256 underlyingPrice, AssetData memory assetData)
        public
    {
        address underlying = _randomUnderlying(seed);
        (uint256 ltvConfig, uint256 ltConfig) = _getLtvLt(underlying);

        assetData.ltEMode = uint16(bound(assetData.ltEMode, 0, type(uint16).max));
        assetData.ltvEMode = uint16(bound(assetData.ltvEMode, 0, assetData.ltEMode));
        uint16 liquidationBonus = uint16(PercentageMath.PERCENTAGE_FACTOR + 1);
        underlyingPrice = bound(underlyingPrice, 0, type(uint96).max - 1);
        vm.assume(uint256(assetData.ltEMode).percentMul(uint256(liquidationBonus)) <= PercentageMath.PERCENTAGE_FACTOR);

        DataTypes.CollateralConfig memory eModeCollateralConfig = DataTypes.CollateralConfig({
            ltv: assetData.ltvEMode,
            liquidationThreshold: assetData.ltEMode,
            liquidationBonus: liquidationBonus
        });
        if (_eModeCategoryId != 0) {
            _setEModeCategoryAsset(eModeCollateralConfig, underlying, _eModeCategoryId);
        }

        oracle.setAssetPrice(underlying, underlyingPrice);

        Types.LiquidityVars memory vars;
        vars.oracle = oracle;
        vars.user = address(this);
        vars.eModeCollateralConfig = eModeCollateralConfig;
        (uint256 assetPrice, uint256 ltv, uint256 lt,) = _assetLiquidityData(underlying, vars);

        assertEq(
            uint16(ltv),
            _eModeCategoryId != 0 && ltvConfig != 0 ? assetData.ltvEMode : ltvConfig,
            "Loan to value E-mode"
        );
        assertEq(
            uint16(lt),
            _eModeCategoryId != 0 && ltvConfig != 0 ? assetData.ltEMode : ltConfig,
            "Liquidation Threshold E-Mode"
        );
        assertEq(assetPrice, underlyingPrice, "Underlying Price");
    }

    function testIsInEModeCollateralSameCategory(
        uint256 seed,
        uint8 eModeCategoryId,
        uint16 lt,
        uint16 ltv,
        uint16 liquidationBonus
    ) public {
        address underlying = _randomUnderlying(seed);

        eModeCategoryId = uint8(bound(uint256(eModeCategoryId), 1, type(uint8).max));

        ltv = uint16(bound(ltv, 1, PercentageMath.PERCENTAGE_FACTOR - 1));
        lt = uint16(bound(lt, ltv, PercentageMath.PERCENTAGE_FACTOR));
        liquidationBonus = uint16(bound(liquidationBonus, PercentageMath.PERCENTAGE_FACTOR + 1, type(uint16).max));
        vm.assume(uint256(lt).percentMul(liquidationBonus) <= PercentageMath.PERCENTAGE_FACTOR);

        DataTypes.CollateralConfig memory eModeCollateralConfig =
            DataTypes.CollateralConfig({ltv: ltv, liquidationThreshold: lt, liquidationBonus: liquidationBonus});
        _setEModeCategoryAsset(eModeCollateralConfig, underlying, eModeCategoryId);

        bool isInEModeCollateral = _hasTailoredParametersInEmode(underlying);
        bool sameCategory = _eModeCategoryId == eModeCategoryId;

        assert(!isInEModeCollateral || sameCategory);
    }

    function testAssetDataEMode(address underlying, uint256 underlyingPrice) public {
        underlyingPrice = bound(underlyingPrice, 0, type(uint256).max);
        oracle.setAssetPrice(underlying, underlyingPrice);

        DataTypes.ReserveConfigurationMap memory configuration = pool.getConfiguration(underlying);

        (uint256 price, uint256 assetUnit) = _assetData(underlying, oracle, configuration);

        assertEq(price, underlyingPrice, "price != expected price");
        assertEq(assetUnit, 10 ** configuration.getDecimals(), "assetUnit");
    }

    function testShouldNotAuthorizeBorrowInconsistentEmode(
        uint8 eModeCategoryId,
        Types.Indexes256 memory indexes,
        DataTypes.CollateralConfig memory eModeCollateralConfig
    ) public {
        eModeCategoryId = uint8(bound(uint256(eModeCategoryId), 1, type(uint8).max));
        eModeCollateralConfig.ltv = uint16(bound(eModeCollateralConfig.ltv, 1, PercentageMath.PERCENTAGE_FACTOR - 1));
        eModeCollateralConfig.liquidationThreshold = uint16(
            bound(
                eModeCollateralConfig.liquidationThreshold, eModeCollateralConfig.ltv, PercentageMath.PERCENTAGE_FACTOR
            )
        );

        eModeCollateralConfig.liquidationBonus = uint16(
            bound(
                eModeCollateralConfig.liquidationBonus,
                PercentageMath.PERCENTAGE_FACTOR + 1,
                2 * PercentageMath.PERCENTAGE_FACTOR
            )
        );

        vm.assume(
            uint256(eModeCollateralConfig.liquidationThreshold).percentMul(eModeCollateralConfig.liquidationBonus)
                <= PercentageMath.PERCENTAGE_FACTOR
        );

        _setEModeCategoryAsset(eModeCollateralConfig, dai, eModeCategoryId);

        indexes.supply.poolIndex = bound(indexes.supply.poolIndex, 0, type(uint96).max);
        indexes.supply.p2pIndex = bound(indexes.supply.p2pIndex, indexes.supply.poolIndex, type(uint96).max);
        indexes.borrow.p2pIndex = bound(indexes.borrow.p2pIndex, 0, type(uint96).max);
        indexes.borrow.poolIndex = bound(indexes.borrow.poolIndex, indexes.borrow.p2pIndex, type(uint96).max);

        // Keep the condition because the test reverts if _eModeCategoryId == 0
        if (_eModeCategoryId != 0) {
            vm.assume(_eModeCategoryId != eModeCategoryId);
            vm.expectRevert(Errors.InconsistentEMode.selector);
        }
        this.authorizeBorrow(dai, 0, indexes);
    }

    function authorizeBorrow(address underlying, uint256 amount, Types.Indexes256 memory indexes) public view {
        _authorizeBorrow(underlying, amount, indexes);
    }
}
