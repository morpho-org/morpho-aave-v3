// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IAToken} from "src/interfaces/aave/IAToken.sol";
import {IAaveOracle} from "@aave-v3-origin/interfaces/IAaveOracle.sol";
import {IPriceOracleGetter} from "@aave-v3-origin/interfaces/IPriceOracleGetter.sol";
import {IACLManager} from "@aave-v3-origin/interfaces/IACLManager.sol";
import {IPoolConfigurator} from "@aave-v3-origin/interfaces/IPoolConfigurator.sol";
import {IPoolDataProvider} from "@aave-v3-origin/interfaces/IPoolDataProvider.sol";
import {IPool, IPoolAddressesProvider} from "@aave-v3-origin/interfaces/IPool.sol";
import {IVariableDebtToken} from "@aave-v3-origin/interfaces/IVariableDebtToken.sol";
import {IRewardsController} from "@aave-v3-periphery/rewards/interfaces/IRewardsController.sol";

import {ReserveDataLib} from "src/libraries/ReserveDataLib.sol";
import {ReserveDataTestLib} from "test/helpers/ReserveDataTestLib.sol";
import {Config, ConfigLib} from "config/ConfigLib.sol";
import {MathUtils} from "@aave-v3-origin/protocol/libraries/math/MathUtils.sol";
import {DataTypes} from "@aave-v3-origin/protocol/libraries/types/DataTypes.sol";
import {Errors as AaveErrors} from "@aave-v3-origin/protocol/libraries/helpers/Errors.sol";
import {ReserveConfiguration} from "@aave-v3-origin/protocol/libraries/configuration/ReserveConfiguration.sol";

import {PermitHash} from "@permit2/libraries/PermitHash.sol";
import {IAllowanceTransfer, AllowanceTransfer} from "@permit2/AllowanceTransfer.sol";

import {PriceOracleSentinelMock} from "test/mocks/PriceOracleSentinelMock.sol";
import {FlashBorrowerMock} from "test/mocks/FlashBorrowerMock.sol";
import {AaveOracleMock} from "test/mocks/AaveOracleMock.sol";
import {PoolAdminMock} from "test/mocks/PoolAdminMock.sol";
import {Configured} from "config/Configured.sol";
import "./BaseTest.sol";

contract ForkTest is BaseTest, Configured {
    using WadRayMath for uint256;
    using PercentageMath for uint256;
    using SafeTransferLib for ERC20;
    using ConfigLib for Config;
    using ReserveDataLib for DataTypes.ReserveDataLegacy;
    using ReserveDataTestLib for DataTypes.ReserveDataLegacy;
    using ReserveConfiguration for DataTypes.ReserveConfigurationMap;

    /* CONSTANTS */

    address internal constant POOL_ADMIN = address(0xB055);
    AllowanceTransfer internal constant PERMIT2 = AllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    /* STORAGE */

    uint256 internal forkId;

    IPool internal pool;
    IACLManager internal aclManager;
    IPoolConfigurator internal poolConfigurator;
    IPoolDataProvider internal poolDataProvider;
    IRewardsController internal rewardsController;
    IPoolAddressesProvider internal addressesProvider;

    address internal morphoDao;
    address internal aclAdmin;
    address internal emissionManager;

    AaveOracleMock internal oracle;
    PoolAdminMock internal poolAdmin;
    PriceOracleSentinelMock internal oracleSentinel;
    FlashBorrowerMock internal flashBorrower;

    uint256 internal snapshotId = type(uint256).max;

    constructor() {
        _initConfig();
        _loadConfig();

        deal(address(this), type(uint128).max);
        _setBalances(address(this), type(uint96).max);

        _mockPoolAdmin();
        _mockOracle();
        _mockOracleSentinel();
        _mockFlashBorrower();
    }

    function setUp() public virtual {
        _label();
    }

    function _fork() internal virtual {
        string memory rpcUrl = vm.rpcUrl(_rpcAlias());
        uint256 forkBlockNumber = config.getForkBlockNumber();

        forkId = forkBlockNumber == 0 ? vm.createSelectFork(rpcUrl) : vm.createSelectFork(rpcUrl, forkBlockNumber);
        vm.chainId(config.getChainId());
        console.log("fork block number", block.number);
    }

    function _loadConfig() internal virtual override {
        super._loadConfig();

        _fork();

        addressesProvider = IPoolAddressesProvider(config.getAddressesProvider());
        pool = IPool(addressesProvider.getPool());
        morphoDao = config.getMorphoDao();

        aclAdmin = addressesProvider.getACLAdmin();
        aclManager = IACLManager(addressesProvider.getACLManager());
        poolConfigurator = IPoolConfigurator(addressesProvider.getPoolConfigurator());
        poolDataProvider = IPoolDataProvider(addressesProvider.getPoolDataProvider());
        rewardsController = IRewardsController(addressesProvider.getAddress(keccak256("INCENTIVES_CONTROLLER")));
        emissionManager = rewardsController.getEmissionManager();
    }

    function _label() internal virtual {
        vm.label(address(pool), "Pool");
        vm.label(address(oracle), "PriceOracle");
        vm.label(address(rewardsController), "RewardsController");
        vm.label(address(addressesProvider), "AddressesProvider");

        vm.label(aclAdmin, "ACLAdmin");
        vm.label(address(aclManager), "ACLManager");
        vm.label(address(poolConfigurator), "PoolConfigurator");
        vm.label(address(poolDataProvider), "PoolDataProvider");

        for (uint256 i; i < allUnderlyings.length; ++i) {
            address underlying = allUnderlyings[i];
            string memory symbol = ERC20(underlying).symbol();

            vm.label(underlying, symbol);
        }
    }

    function _mockPoolAdmin() internal {
        poolAdmin = new PoolAdminMock(poolConfigurator);

        vm.startPrank(aclAdmin);
        aclManager.addPoolAdmin(address(poolAdmin));
        aclManager.addRiskAdmin(address(poolAdmin));
        aclManager.addEmergencyAdmin(address(poolAdmin));
        vm.stopPrank();
    }

    function _mockOracle() internal {
        oracle = new AaveOracleMock(IAaveOracle(addressesProvider.getPriceOracle()), allUnderlyings);

        vm.prank(aclAdmin);
        addressesProvider.setPriceOracle(address(oracle));
    }

    function _mockOracleSentinel() internal {
        oracleSentinel = new PriceOracleSentinelMock(address(addressesProvider));

        vm.prank(aclAdmin);
        addressesProvider.setPriceOracleSentinel(address(oracleSentinel));
    }

    function _mockFlashBorrower() internal {
        flashBorrower = new FlashBorrowerMock(address(pool));

        _setBalances(address(flashBorrower), type(uint96).max);
    }

    function _setBalances(address user, uint256 balance) internal {
        for (uint256 i; i < allUnderlyings.length; ++i) {
            address underlying = allUnderlyings[i];

            deal(underlying, user, balance / (10 ** (18 - ERC20(underlying).decimals())));
        }
    }

    function _assumeETHReceiver(address receiver) internal virtual override {
        vm.assume(receiver != weth);
        super._assumeETHReceiver(receiver);
    }

    /// @dev Avoids to revert because of AAVE token snapshots: https://github.com/aave/aave-token-v2/blob/master/contracts/token/base/GovernancePowerDelegationERC20.sol#L174
    function deal(address underlying, address user, uint256 amount) internal override {
        if (amount == 0) return;

        // Needed because AAVE packs the balance struct.
        if (underlying == aave) {
            uint256 initialBalance = ERC20(aave).balanceOf(user);
            require(amount <= type(uint104).max, "deal: amount exceeds AAVE balance limit");
            // The slot of the balance struct "_balances" is 0.
            bytes32 balanceSlot = keccak256(abi.encode(user, uint256(0)));
            bytes32 initialValue = vm.load(aave, balanceSlot);
            // The balance is stored in the first 104 bits.
            bytes32 finalValue = ((initialValue >> 104) << 104) | bytes32(uint256(amount));
            vm.store(aave, balanceSlot, finalValue);
            require(ERC20(aave).balanceOf(user) == uint256(amount), "deal: AAVE balance mismatch");

            uint256 totSup = ERC20(aave).totalSupply();
            if (amount < initialBalance) {
                totSup -= (initialBalance - amount);
            } else {
                totSup += (amount - initialBalance);
            }
            // The slot of the balance struct "totalSupply" is 2.
            bytes32 totalSupplySlot = bytes32(uint256(2));
            vm.store(aave, totalSupplySlot, bytes32(totSup));

            return;
        }

        if (underlying == weth) super.deal(weth, weth.balance + amount); // Refill wrapped Ether.

        super.deal(underlying, user, amount);
    }

    /// @dev Reverts the fork to its initial fork state.
    function _revert() internal {
        if (snapshotId < type(uint256).max) vm.revertToState(snapshotId);
        snapshotId = vm.snapshotState();
    }

    /// @dev Returns the total supply used towards the supply cap.
    function _totalSupplyToCap(address underlying) internal view returns (uint256) {
        DataTypes.ReserveDataLegacy memory reserve = pool.getReserveData(underlying);
        uint256 poolSupplyIndex = pool.getReserveNormalizedIncome(underlying);
        uint256 poolBorrowIndex = pool.getReserveNormalizedVariableDebt(underlying);

        return reserve.totalSupplyToCap(poolSupplyIndex, poolBorrowIndex);
    }

    function _getLtvLt(address underlying) internal view returns (uint256 ltvConfig, uint256 ltConfig) {
        DataTypes.ReserveConfigurationMap memory config = pool.getConfiguration(underlying);
        ltvConfig = config.getLtv();
        ltConfig = config.getLiquidationThreshold();
    }

    function _setEModeCategoryAsset(
        DataTypes.CollateralConfig memory eModeCollateralConfig,
        address underlying,
        uint8 eModeCategoryId
    ) internal {
        poolAdmin.setEModeCategory(
            eModeCategoryId,
            eModeCollateralConfig.ltv,
            eModeCollateralConfig.liquidationThreshold,
            eModeCollateralConfig.liquidationBonus,
            ""
        );
        poolAdmin.setAssetBorrowableInEMode(underlying, eModeCategoryId, true);
        poolAdmin.setAssetCollateralInEMode(underlying, eModeCategoryId, true);
    }

    function _assumeNotUnderlying(address input) internal view {
        for (uint256 i; i < allUnderlyings.length; ++i) {
            vm.assume(input != allUnderlyings[i]);
        }
    }

    function _assumeNotLsdNative(address input) internal view {
        for (uint256 i; i < lsdNatives.length; ++i) {
            vm.assume(input != lsdNatives[i]);
        }
    }

    function _randomUnderlying(uint256 seed) internal view returns (address) {
        return allUnderlyings[seed % allUnderlyings.length];
    }

    function _randomLsdNative(uint256 seed) internal view returns (address) {
        return lsdNatives[seed % lsdNatives.length];
    }
}
