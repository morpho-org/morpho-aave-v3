// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.17;

import {IPool} from "./interfaces/aave/IPool.sol";
import {IRewardsManager} from "./interfaces/IRewardsManager.sol";
import {IAaveOracle} from "@aave/core-v3/contracts/interfaces/IAaveOracle.sol";

import {Types} from "./libraries/Types.sol";
import {Events} from "./libraries/Events.sol";
import {Errors} from "./libraries/Errors.sol";
import {PoolLib} from "./libraries/PoolLib.sol";
import {MarketLib} from "./libraries/MarketLib.sol";
import {Constants} from "./libraries/Constants.sol";
import {MarketBalanceLib} from "./libraries/MarketBalanceLib.sol";
import {InterestRatesLib} from "./libraries/InterestRatesLib.sol";

import {Math} from "@morpho-utils/math/Math.sol";
import {WadRayMath} from "@morpho-utils/math/WadRayMath.sol";
import {PercentageMath} from "@morpho-utils/math/PercentageMath.sol";

import {ERC20, SafeTransferLib} from "@solmate/utils/SafeTransferLib.sol";

import {ThreeHeapOrdering} from "@morpho-data-structures/ThreeHeapOrdering.sol";

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {DataTypes} from "./libraries/aave/DataTypes.sol";
import {UserConfiguration} from "./libraries/aave/UserConfiguration.sol";
import {ReserveConfiguration} from "./libraries/aave/ReserveConfiguration.sol";

import {MorphoStorage} from "./MorphoStorage.sol";

import {ERC20} from "@solmate/tokens/ERC20.sol";

abstract contract MorphoInternal is MorphoStorage {
    using PoolLib for IPool;
    using MarketLib for Types.Market;
    using MarketBalanceLib for Types.MarketBalances;
    using EnumerableSet for EnumerableSet.AddressSet;
    using ThreeHeapOrdering for ThreeHeapOrdering.HeapArray;
    using UserConfiguration for DataTypes.UserConfigurationMap;
    using ReserveConfiguration for DataTypes.ReserveConfigurationMap;
    using SafeTransferLib for ERC20;

    using Math for uint256;
    using WadRayMath for uint256;
    using PercentageMath for uint256;

    /// MODIFIERS ///

    /// @notice Prevents to update a market not created yet.
    /// @param underlying The address of the market to check.
    modifier isMarketCreated(address underlying) {
        if (!_market[underlying].isCreated()) revert Errors.MarketNotCreated();
        _;
    }

    /// INTERNAL ///

    function _createMarket(address underlying, uint16 reserveFactor, uint16 p2pIndexCursor) internal {
        if (underlying == address(0)) revert Errors.AddressIsZero();
        if (p2pIndexCursor > PercentageMath.PERCENTAGE_FACTOR || reserveFactor > PercentageMath.PERCENTAGE_FACTOR) {
            revert Errors.ExceedsMaxBasisPoints();
        }

        DataTypes.ReserveData memory reserveData = _POOL.getReserveData(underlying);
        if (!reserveData.configuration.getActive()) revert Errors.MarketIsNotListedOnAave();

        Types.Market storage market = _market[underlying];

        if (market.isCreated()) revert Errors.MarketAlreadyCreated();

        Types.Indexes256 memory indexes;
        indexes.supply.p2pIndex = WadRayMath.RAY;
        indexes.borrow.p2pIndex = WadRayMath.RAY;
        (indexes.supply.poolIndex, indexes.borrow.poolIndex) = _POOL.getCurrentPoolIndexes(underlying);

        market.setIndexes(indexes);
        market.lastUpdateTimestamp = uint32(block.timestamp);

        market.underlying = underlying;
        market.aToken = reserveData.aTokenAddress;
        market.variableDebtToken = reserveData.variableDebtTokenAddress;
        market.reserveFactor = reserveFactor;
        market.p2pIndexCursor = p2pIndexCursor;

        _marketsCreated.push(underlying);

        ERC20(underlying).safeApprove(address(_POOL), type(uint256).max);

        emit Events.MarketCreated(underlying, reserveFactor, p2pIndexCursor);
    }

    function _increaseP2PDeltas(address underlying, uint256 amount) internal {
        Types.Indexes256 memory indexes = _updateIndexes(underlying);

        Types.Market storage market = _market[underlying];
        Types.Deltas memory deltas = market.deltas;
        uint256 poolSupplyIndex = indexes.supply.poolIndex;
        uint256 poolBorrowIndex = indexes.borrow.poolIndex;

        amount = Math.min(
            amount,
            Math.min(
                deltas.supply.scaledTotalP2P.rayMul(indexes.supply.p2pIndex).zeroFloorSub(
                    deltas.supply.scaledDeltaPool.rayMul(poolSupplyIndex)
                ),
                deltas.borrow.scaledTotalP2P.rayMul(indexes.borrow.p2pIndex).zeroFloorSub(
                    deltas.borrow.scaledDeltaPool.rayMul(poolBorrowIndex)
                )
            )
        );
        if (amount == 0) revert Errors.AmountIsZero();

        uint256 newSupplyDelta = deltas.supply.scaledDeltaPool + amount.rayDiv(poolSupplyIndex);
        uint256 newBorrowDelta = deltas.borrow.scaledDeltaPool + amount.rayDiv(poolBorrowIndex);

        market.deltas.supply.scaledDeltaPool = newSupplyDelta;
        market.deltas.borrow.scaledDeltaPool = newBorrowDelta;
        emit Events.P2PSupplyDeltaUpdated(underlying, newSupplyDelta);
        emit Events.P2PBorrowDeltaUpdated(underlying, newBorrowDelta);

        _POOL.borrowFromPool(underlying, amount);
        _POOL.supplyToPool(underlying, amount);

        emit Events.P2PDeltasIncreased(underlying, amount);
    }

    function _hashEIP712TypedData(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(Constants.EIP712_MSG_PREFIX, _DOMAIN_SEPARATOR, structHash));
    }

    function _approveManager(address owner, address manager, bool isAllowed) internal {
        _isManaging[owner][manager] = isAllowed;
        emit Events.ManagerApproval(owner, manager, isAllowed);
    }

    function _getUserBalanceFromIndexes(
        uint256 scaledPoolBalance,
        uint256 scaledP2PBalance,
        Types.MarketSideIndexes256 memory indexes
    ) internal pure returns (uint256) {
        return scaledPoolBalance.rayMul(indexes.poolIndex) + scaledP2PBalance.rayMul(indexes.p2pIndex);
    }

    function _getUserSupplyBalanceFromIndexes(
        address underlying,
        address user,
        Types.MarketSideIndexes256 memory indexes
    ) internal view returns (uint256) {
        Types.MarketBalances storage marketBalances = _marketBalances[underlying];
        return _getUserBalanceFromIndexes(
            marketBalances.scaledPoolSupplyBalance(user), marketBalances.scaledP2PSupplyBalance(user), indexes
        );
    }

    function _getUserBorrowBalanceFromIndexes(
        address underlying,
        address user,
        Types.MarketSideIndexes256 memory indexes
    ) internal view returns (uint256) {
        Types.MarketBalances storage marketBalances = _marketBalances[underlying];
        return _getUserBalanceFromIndexes(
            marketBalances.scaledPoolBorrowBalance(user), marketBalances.scaledP2PBorrowBalance(user), indexes
        );
    }

    function _getUserCollateralBalanceFromIndex(address underlying, address user, uint256 poolSupplyIndex)
        internal
        view
        returns (uint256)
    {
        return _marketBalances[underlying].scaledCollateralBalance(user).rayMulDown(poolSupplyIndex);
    }

    function _liquidityData(address underlying, address user, uint256 amountWithdrawn, uint256 amountBorrowed)
        internal
        view
        returns (Types.LiquidityData memory liquidityData)
    {
        Types.LiquidityVars memory vars;

        vars.eMode = uint8(_POOL.getUserEMode(address(this)));
        if (vars.eMode != 0) vars.eModeCategory = _POOL.getEModeCategoryData(vars.eMode);
        vars.morphoPoolConfig = _POOL.getUserConfiguration(address(this));
        vars.oracle = IAaveOracle(_ADDRESSES_PROVIDER.getPriceOracle());
        vars.user = user;

        (liquidityData.collateral, liquidityData.borrowable, liquidityData.maxDebt) =
            _totalCollateralData(underlying, vars, amountWithdrawn);

        liquidityData.debt = _totalDebt(underlying, vars, amountBorrowed);
    }

    function _totalCollateralData(address assetWithdrawn, Types.LiquidityVars memory vars, uint256 amountWithdrawn)
        internal
        view
        returns (uint256 collateral, uint256 borrowable, uint256 maxDebt)
    {
        address[] memory userCollaterals = _userCollaterals[vars.user].values();
        uint256[] memory prices = vars.oracle.getAssetsPrices(userCollaterals);

        for (uint256 i; i < userCollaterals.length; ++i) {
            (uint256 collateralSingle, uint256 borrowableSingle, uint256 maxDebtSingle) = _collateralData(
                userCollaterals[i], prices[i], vars, userCollaterals[i] == assetWithdrawn ? amountWithdrawn : 0
            );

            collateral += collateralSingle;
            borrowable += borrowableSingle;
            maxDebt += maxDebtSingle;
        }
    }

    function _totalDebt(address assetBorrowed, Types.LiquidityVars memory vars, uint256 amountBorrowed)
        internal
        view
        returns (uint256 debt)
    {
        address[] memory userBorrows = _userBorrows[vars.user].values();
        uint256[] memory prices = vars.oracle.getAssetsPrices(userBorrows);

        for (uint256 i; i < userBorrows.length; ++i) {
            debt += _debt(userBorrows[i], prices[i], vars, userBorrows[i] == assetBorrowed ? amountBorrowed : 0);
        }
        if (assetBorrowed != address(0) && !_userBorrows[vars.user].contains(assetBorrowed)) {
            debt += _debt(assetBorrowed, vars.oracle.getAssetPrice(assetBorrowed), vars, amountBorrowed);
        }
    }

    function _collateralData(
        address underlying,
        uint256 price,
        Types.LiquidityVars memory vars,
        uint256 amountWithdrawn
    ) internal view returns (uint256 collateral, uint256 borrowable, uint256 maxDebt) {
        uint256 ltv;
        uint256 liquidationThreshold;
        uint256 tokenUnit;
        (price, ltv, liquidationThreshold, tokenUnit) = _assetLiquidityData(underlying, price, vars);

        Types.Indexes256 memory indexes = _computeIndexes(underlying);
        collateral = (
            _getUserCollateralBalanceFromIndex(underlying, vars.user, indexes.supply.poolIndex) - amountWithdrawn
        ) * price / tokenUnit;

        borrowable = collateral.percentMulDown(ltv);
        maxDebt = collateral.percentMulDown(liquidationThreshold);
    }

    function _debt(address underlying, uint256 price, Types.LiquidityVars memory vars, uint256 amountBorrowed)
        internal
        view
        returns (uint256 debtValue)
    {
        uint256 tokenUnit;
        (price,,, tokenUnit) = _assetLiquidityData(underlying, price, vars);

        Types.Indexes256 memory indexes = _computeIndexes(underlying);
        debtValue = ((_getUserBorrowBalanceFromIndexes(underlying, vars.user, indexes.borrow) + amountBorrowed) * price)
            .divUp(tokenUnit);
    }

    function _assetLiquidityData(address underlying, uint256 price, Types.LiquidityVars memory vars)
        internal
        view
        returns (uint256, uint256, uint256, uint256)
    {
        uint256 ltv;
        uint256 liquidationThreshold;
        uint256 tokenUnit;

        uint256 decimals;
        uint256 eModeCat;
        DataTypes.ReserveData memory reserveData = _POOL.getReserveData(underlying);
        (ltv, liquidationThreshold,, decimals,, eModeCat) = reserveData.configuration.getParams();

        if (vars.eMode != 0 && vars.eMode == eModeCat) {
            if (vars.eModeCategory.priceSource != address(0)) {
                uint256 eModeUnderlyingPrice = vars.oracle.getAssetPrice(vars.eModeCategory.priceSource);
                if (eModeUnderlyingPrice != 0) price = eModeUnderlyingPrice;
            }

            if (ltv != 0) ltv = vars.eModeCategory.ltv;
            liquidationThreshold = vars.eModeCategory.liquidationThreshold;
        }

        // LTV should be zero if Morpho has not enabled this asset as collateral
        if (!vars.morphoPoolConfig.isUsingAsCollateral(reserveData.id)) {
            ltv = 0;
        }

        // If a LTV has been reduced to 0 on Aave v3, the other assets of the collateral are frozen.
        // In response, Morpho disables the asset as collateral and sets its liquidation threshold to 0.
        if (ltv == 0) {
            liquidationThreshold = 0;
        }

        unchecked {
            tokenUnit = 10 ** decimals;
        }

        return (price, ltv, liquidationThreshold, tokenUnit);
    }

    function _updateInDS(
        address poolToken,
        address user,
        ThreeHeapOrdering.HeapArray storage marketOnPool,
        ThreeHeapOrdering.HeapArray storage marketInP2P,
        uint256 onPool,
        uint256 inP2P
    ) internal {
        uint256 formerOnPool = marketOnPool.getValueOf(user);

        if (onPool != formerOnPool) {
            if (address(_rewardsManager) != address(0)) {
                _rewardsManager.updateUserRewards(user, poolToken, formerOnPool);
            }

            marketOnPool.update(user, formerOnPool, onPool, _maxSortedUsers);
        }

        marketInP2P.update(user, marketInP2P.getValueOf(user), inP2P, _maxSortedUsers);
    }

    function _updateSupplierInDS(address underlying, address user, uint256 onPool, uint256 inP2P) internal {
        _updateInDS(
            _market[underlying].aToken,
            user,
            _marketBalances[underlying].poolSuppliers,
            _marketBalances[underlying].p2pSuppliers,
            onPool,
            inP2P
        );
    }

    function _updateBorrowerInDS(address underlying, address user, uint256 onPool, uint256 inP2P) internal {
        _updateInDS(
            _market[underlying].variableDebtToken,
            user,
            _marketBalances[underlying].poolBorrowers,
            _marketBalances[underlying].p2pBorrowers,
            onPool,
            inP2P
        );
        if (onPool == 0 && inP2P == 0) _userBorrows[user].remove(underlying);
        else _userBorrows[user].add(underlying);
    }

    function _setPauseStatus(address underlying, bool isPaused) internal {
        Types.PauseStatuses storage pauseStatuses = _market[underlying].pauseStatuses;

        pauseStatuses.isSupplyPaused = isPaused;
        pauseStatuses.isSupplyCollateralPaused = isPaused;
        pauseStatuses.isBorrowPaused = isPaused;
        pauseStatuses.isWithdrawPaused = isPaused;
        pauseStatuses.isWithdrawCollateralPaused = isPaused;
        pauseStatuses.isRepayPaused = isPaused;
        pauseStatuses.isLiquidateCollateralPaused = isPaused;
        pauseStatuses.isLiquidateBorrowPaused = isPaused;

        emit Events.IsSupplyPausedSet(underlying, isPaused);
        emit Events.IsSupplyCollateralPausedSet(underlying, isPaused);
        emit Events.IsBorrowPausedSet(underlying, isPaused);
        emit Events.IsWithdrawPausedSet(underlying, isPaused);
        emit Events.IsWithdrawCollateralPausedSet(underlying, isPaused);
        emit Events.IsRepayPausedSet(underlying, isPaused);
        emit Events.IsLiquidateCollateralPausedSet(underlying, isPaused);
        emit Events.IsLiquidateBorrowPausedSet(underlying, isPaused);
    }

    function _updateIndexes(address underlying) internal returns (Types.Indexes256 memory indexes) {
        indexes = _computeIndexes(underlying);

        Types.Market storage market = _market[underlying];
        market.setIndexes(indexes);
    }

    function _computeIndexes(address underlying) internal view returns (Types.Indexes256 memory indexes) {
        Types.Market storage market = _market[underlying];
        Types.Indexes256 memory lastIndexes = market.getIndexes();
        if (block.timestamp == market.lastUpdateTimestamp) {
            return lastIndexes;
        }

        (indexes.supply.poolIndex, indexes.borrow.poolIndex) = _POOL.getCurrentPoolIndexes(underlying);

        (indexes.supply.p2pIndex, indexes.borrow.p2pIndex) = InterestRatesLib.computeP2PIndexes(
            Types.RatesParams({
                lastSupplyIndexes: lastIndexes.supply,
                lastBorrowIndexes: lastIndexes.borrow,
                poolSupplyIndex: indexes.supply.poolIndex,
                poolBorrowIndex: indexes.borrow.poolIndex,
                reserveFactor: market.reserveFactor,
                p2pIndexCursor: market.p2pIndexCursor,
                deltas: market.deltas,
                proportionIdle: _proportionIdle(underlying)
            })
        );
    }

    function _getUserHealthFactor(address underlying, address user, uint256 withdrawnAmount)
        internal
        view
        returns (uint256)
    {
        // If the user is not borrowing any asset, return an infinite health factor.
        if (_userBorrows[user].length() == 0) return type(uint256).max;

        Types.LiquidityData memory liquidityData = _liquidityData(underlying, user, withdrawnAmount, 0);

        return liquidityData.debt > 0 ? liquidityData.maxDebt.wadDiv(liquidityData.debt) : type(uint256).max;
    }

    function _calculateLiquidation(
        address underlyingBorrowed,
        address underlyingCollateral,
        uint256 liquidatable,
        address borrower,
        Types.MarketSideIndexes256 memory collateralIndexes
    ) internal view returns (uint256 repaid, uint256 seized) {
        repaid = liquidatable;

        (,, uint256 liquidationBonus, uint256 collateralTokenUnit,,) =
            _POOL.getConfiguration(underlyingCollateral).getParams();
        (,,, uint256 borrowTokenUnit,,) = _POOL.getConfiguration(underlyingBorrowed).getParams();

        unchecked {
            collateralTokenUnit = 10 ** collateralTokenUnit;
            borrowTokenUnit = 10 ** borrowTokenUnit;
        }

        address[] memory assets = new address[](2);
        assets[0] = underlyingBorrowed;
        assets[1] = underlyingCollateral;

        IAaveOracle oracle = IAaveOracle(_ADDRESSES_PROVIDER.getPriceOracle());
        uint256[] memory prices = oracle.getAssetsPrices(assets);
        uint256 borrowPrice = prices[0];
        uint256 collateralPrice = prices[1];

        seized = ((repaid * borrowPrice * collateralTokenUnit) / (borrowTokenUnit * collateralPrice)).percentMul(
            liquidationBonus
        );

        uint256 collateralBalance = _getUserSupplyBalanceFromIndexes(underlyingCollateral, borrower, collateralIndexes);

        if (seized > collateralBalance) {
            seized = collateralBalance;
            repaid = ((collateralBalance * collateralPrice * borrowTokenUnit) / (borrowPrice * collateralTokenUnit))
                .percentDiv(liquidationBonus);
        }
    }

    /// @dev Returns a ray.
    function _proportionIdle(address underlying) internal view returns (uint256) {
        Types.Market storage market = _market[underlying];
        uint256 idleSupply = market.idleSupply;
        if (idleSupply == 0) {
            return 0;
        }
        uint256 totalP2PSupplied = market.deltas.supply.scaledTotalP2P.rayMul(market.indexes.supply.p2pIndex);
        return idleSupply.rayDivUp(totalP2PSupplied);
    }
}
