// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.17;

import {IAaveOracle} from "@aave/core-v3/contracts/interfaces/IAaveOracle.sol";
import {IPriceOracleSentinel} from "@aave/core-v3/contracts/interfaces/IPriceOracleSentinel.sol";

import {Types} from "./libraries/Types.sol";
import {Events} from "./libraries/Events.sol";
import {Errors} from "./libraries/Errors.sol";
import {Constants} from "./libraries/Constants.sol";
import {MarketLib} from "./libraries/MarketLib.sol";
import {MarketBalanceLib} from "./libraries/MarketBalanceLib.sol";

import {DataTypes} from "./libraries/aave/DataTypes.sol";
import {ReserveConfiguration} from "./libraries/aave/ReserveConfiguration.sol";

import {Math} from "@morpho-utils/math/Math.sol";
import {WadRayMath} from "@morpho-utils/math/WadRayMath.sol";
import {PercentageMath} from "@morpho-utils/math/PercentageMath.sol";
import {ThreeHeapOrdering} from "@morpho-data-structures/ThreeHeapOrdering.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {MatchingEngine} from "./MatchingEngine.sol";

import {ERC20} from "@solmate/tokens/ERC20.sol";

abstract contract PositionsManagerInternal is MatchingEngine {
    using Math for uint256;
    using WadRayMath for uint256;
    using PercentageMath for uint256;
    using MarketLib for Types.Market;
    using MarketBalanceLib for Types.MarketBalances;
    using EnumerableSet for EnumerableSet.AddressSet;
    using ThreeHeapOrdering for ThreeHeapOrdering.HeapArray;
    using ReserveConfiguration for DataTypes.ReserveConfigurationMap;

    function _validatePermission(address owner, address manager) internal view {
        if (!(owner == manager || _isManaging[owner][manager])) revert Errors.PermissionDenied();
    }

    function _validateInput(address underlying, uint256 amount, address user)
        internal
        view
        returns (Types.Market storage market)
    {
        if (user == address(0)) revert Errors.AddressIsZero();
        if (amount == 0) revert Errors.AmountIsZero();

        market = _market[underlying];
        if (!market.isCreated()) revert Errors.MarketNotCreated();
    }

    function _validateManagerInput(address underlying, uint256 amount, address onBehalf, address receiver)
        internal
        view
        returns (Types.Market storage market)
    {
        if (onBehalf == address(0)) revert Errors.AddressIsZero();

        market = _validateInput(underlying, amount, receiver);

        _validatePermission(onBehalf, msg.sender);
    }

    function _validateSupplyInput(address underlying, uint256 amount, address user) internal view {
        Types.Market storage market = _validateInput(underlying, amount, user);
        if (market.pauseStatuses.isSupplyPaused) revert Errors.SupplyIsPaused();
    }

    function _validateSupplyCollateralInput(address underlying, uint256 amount, address user) internal view {
        Types.Market storage market = _validateInput(underlying, amount, user);
        if (market.pauseStatuses.isSupplyCollateralPaused) revert Errors.SupplyCollateralIsPaused();
    }

    function _validateBorrowInput(address underlying, uint256 amount, address borrower, address receiver)
        internal
        view
    {
        Types.Market storage market = _validateManagerInput(underlying, amount, borrower, receiver);
        if (market.pauseStatuses.isBorrowPaused) revert Errors.BorrowIsPaused();

        DataTypes.ReserveConfigurationMap memory config = _POOL.getConfiguration(underlying);
        if (!config.getBorrowingEnabled()) revert Errors.BorrowingNotEnabled();

        uint256 eMode = _POOL.getUserEMode(address(this));
        if (eMode != 0 && eMode != config.getEModeCategory()) revert Errors.InconsistentEMode();

        // Aave can enable an oracle sentinel in specific circumstances which can prevent users to borrow.
        // In response, Morpho mirrors this behavior.
        address priceOracleSentinel = _ADDRESSES_PROVIDER.getPriceOracleSentinel();
        if (priceOracleSentinel != address(0) && !IPriceOracleSentinel(priceOracleSentinel).isBorrowAllowed()) {
            revert Errors.PriceOracleSentinelBorrowDisabled();
        }
    }

    function _validateBorrow(address underlying, uint256 amount, address borrower) internal view {
        Types.LiquidityData memory values = _liquidityData(underlying, borrower, 0, amount);
        if (values.debt > values.borrowable) revert Errors.UnauthorizedBorrow();
    }

    function _validateWithdrawInput(address underlying, uint256 amount, address supplier, address receiver)
        internal
        view
    {
        Types.Market storage market = _validateManagerInput(underlying, amount, supplier, receiver);
        if (market.pauseStatuses.isWithdrawPaused) revert Errors.WithdrawIsPaused();

        // Aave can enable an oracle sentinel in specific circumstances which can prevent users to borrow.
        // For safety concerns and as a withdraw on Morpho can trigger a borrow on pool, Morpho prevents withdrawals in such circumstances.
        address priceOracleSentinel = _ADDRESSES_PROVIDER.getPriceOracleSentinel();
        if (priceOracleSentinel != address(0) && !IPriceOracleSentinel(priceOracleSentinel).isBorrowAllowed()) {
            revert Errors.PriceOracleSentinelBorrowPaused();
        }
    }

    function _validateWithdrawCollateralInput(address underlying, uint256 amount, address supplier, address receiver)
        internal
        view
    {
        Types.Market storage market = _validateManagerInput(underlying, amount, supplier, receiver);
        if (market.pauseStatuses.isWithdrawCollateralPaused) revert Errors.WithdrawCollateralIsPaused();
    }

    function _validateWithdrawCollateral(address underlying, uint256 amount, address supplier) internal view {
        if (_getUserHealthFactor(underlying, supplier, amount) < Constants.DEFAULT_LIQUIDATION_THRESHOLD) {
            revert Errors.UnauthorizedWithdraw();
        }
    }

    function _validateRepayInput(address underlying, uint256 amount, address user) internal view {
        Types.Market storage market = _validateInput(underlying, amount, user);
        if (market.pauseStatuses.isRepayPaused) revert Errors.RepayIsPaused();
    }

    function _validateLiquidate(address underlyingBorrowed, address underlyingCollateral, address borrower)
        internal
        view
        returns (uint256 closeFactor)
    {
        Types.Market storage borrowMarket = _market[underlyingBorrowed];
        Types.Market storage collateralMarket = _market[underlyingCollateral];

        if (!collateralMarket.isCreated() || !borrowMarket.isCreated()) {
            revert Errors.MarketNotCreated();
        }
        if (collateralMarket.pauseStatuses.isLiquidateCollateralPaused) {
            revert Errors.LiquidateCollateralIsPaused();
        }
        if (borrowMarket.pauseStatuses.isLiquidateBorrowPaused) {
            revert Errors.LiquidateBorrowIsPaused();
        }
        if (
            !_userCollaterals[borrower].contains(underlyingCollateral)
                || !_userBorrows[borrower].contains(underlyingBorrowed)
        ) {
            revert Errors.UserNotMemberOfMarket();
        }

        if (borrowMarket.pauseStatuses.isDeprecated) {
            return Constants.MAX_CLOSE_FACTOR; // Allow liquidation of the whole debt.
        } else {
            uint256 healthFactor = _getUserHealthFactor(address(0), borrower, 0);
            address priceOracleSentinel = _ADDRESSES_PROVIDER.getPriceOracleSentinel();

            if (
                priceOracleSentinel != address(0) && !IPriceOracleSentinel(priceOracleSentinel).isLiquidationAllowed()
                    && healthFactor >= Constants.MIN_LIQUIDATION_THRESHOLD
            ) {
                revert Errors.UnauthorizedLiquidate();
            } else if (healthFactor >= Constants.DEFAULT_LIQUIDATION_THRESHOLD) {
                revert Errors.UnauthorizedLiquidate();
            }

            closeFactor = healthFactor > Constants.MIN_LIQUIDATION_THRESHOLD
                ? Constants.DEFAULT_CLOSE_FACTOR
                : Constants.MAX_CLOSE_FACTOR;
        }
    }

    function _executeSupply(
        address underlying,
        uint256 amount,
        address user,
        uint256 maxLoops,
        Types.Indexes256 memory indexes
    ) internal returns (Types.SupplyRepayVars memory vars) {
        Types.MarketBalances storage marketBalances = _marketBalances[underlying];
        Types.Deltas storage deltas = _market[underlying].deltas;

        vars.onPool = marketBalances.scaledPoolSupplyBalance(user);
        vars.inP2P = marketBalances.scaledP2PSupplyBalance(user);

        (vars.toRepay, amount) = _matchDelta(underlying, amount, indexes.borrow.poolIndex, true);

        uint256 promoted;
        (promoted, amount,) = _promoteRoutine(
            Types.PromoteVars({
                underlying: underlying,
                amount: amount,
                poolIndex: indexes.borrow.poolIndex,
                maxLoops: maxLoops,
                promote: _promoteBorrowers
            }),
            _marketBalances[underlying].poolBorrowers,
            deltas.borrow
        );
        vars.toRepay += promoted;
        deltas.borrow.scaledTotalP2P += promoted;

        vars.inP2P = _updateP2PDelta(underlying, vars.toRepay, indexes.supply.p2pIndex, vars.inP2P, deltas.supply);

        (vars.toSupply, vars.onPool) = _addToPool(amount, vars.onPool, indexes.supply.poolIndex);

        _updateSupplierInDS(underlying, user, vars.onPool, vars.inP2P);
    }

    function _executeBorrow(
        address underlying,
        uint256 amount,
        address user,
        uint256 maxLoops,
        Types.Indexes256 memory indexes
    ) internal returns (Types.BorrowWithdrawVars memory vars) {
        Types.Market storage market = _market[underlying];
        Types.MarketBalances storage marketBalances = _marketBalances[underlying];
        Types.Deltas storage deltas = market.deltas;

        vars.onPool = marketBalances.scaledPoolBorrowBalance(user);
        vars.inP2P = marketBalances.scaledP2PBorrowBalance(user);

        (amount, vars.inP2P) = _borrowIdle(market, amount, vars.inP2P, indexes.borrow.p2pIndex);
        (vars.toWithdraw, amount) = _matchDelta(underlying, amount, indexes.supply.poolIndex, false);

        uint256 promoted;
        (promoted, amount,) = _promoteRoutine(
            Types.PromoteVars({
                underlying: underlying,
                amount: amount,
                poolIndex: indexes.supply.poolIndex,
                maxLoops: maxLoops,
                promote: _promoteSuppliers
            }),
            _marketBalances[underlying].poolSuppliers,
            deltas.supply
        );
        vars.toWithdraw += promoted;
        deltas.supply.scaledTotalP2P += promoted;

        vars.inP2P = _updateP2PDelta(underlying, vars.toWithdraw, indexes.borrow.p2pIndex, vars.inP2P, deltas.borrow);

        (vars.toBorrow, vars.onPool) = _addToPool(amount, vars.onPool, indexes.borrow.poolIndex);

        _updateBorrowerInDS(underlying, user, vars.onPool, vars.inP2P);
    }

    function _executeRepay(
        address underlying,
        uint256 amount,
        address user,
        uint256 maxLoops,
        Types.Indexes256 memory indexes
    ) internal returns (Types.SupplyRepayVars memory vars) {
        Types.MarketBalances storage marketBalances = _marketBalances[underlying];
        Types.Deltas storage deltas = _market[underlying].deltas;

        vars.onPool = marketBalances.scaledPoolBorrowBalance(user);
        vars.inP2P = marketBalances.scaledP2PBorrowBalance(user);

        (vars.toRepay, amount, vars.onPool) = _subFromPool(amount, vars.onPool, indexes.borrow.poolIndex);
        if (amount == 0) {
            _updateBorrowerInDS(underlying, user, vars.onPool, vars.inP2P);
            return vars;
        }

        vars.inP2P -= Math.min(vars.inP2P, amount.rayDiv(indexes.borrow.p2pIndex)); // In peer-to-peer borrow unit.
        _updateBorrowerInDS(underlying, user, vars.onPool, vars.inP2P);

        (vars.toRepay, amount) = _matchDelta(underlying, amount, indexes.borrow.poolIndex, true);
        deltas.borrow.scaledTotalP2P -= vars.toRepay.rayDiv(indexes.borrow.p2pIndex);
        emit Events.P2PAmountsUpdated(underlying, deltas.supply.scaledTotalP2P, deltas.borrow.scaledTotalP2P);

        amount = _repayFee(underlying, amount, indexes);

        uint256 toRepayFromPromote;
        (toRepayFromPromote, amount, maxLoops) = _promoteRoutine(
            Types.PromoteVars({
                underlying: underlying,
                amount: amount,
                poolIndex: indexes.borrow.poolIndex,
                maxLoops: maxLoops,
                promote: _promoteBorrowers
            }),
            _marketBalances[underlying].poolBorrowers,
            _market[underlying].deltas.borrow
        );
        vars.toRepay += toRepayFromPromote;

        vars.toSupply = _demoteRoutine(underlying, amount, maxLoops, indexes, _demoteSuppliers, deltas, false);

        vars.toSupply = _handleSupplyCap(underlying, vars.toSupply);
    }

    function _executeWithdraw(
        address underlying,
        uint256 amount,
        address user,
        uint256 maxLoops,
        Types.Indexes256 memory indexes
    ) internal returns (Types.BorrowWithdrawVars memory vars) {
        Types.Market storage market = _market[underlying];
        Types.MarketBalances storage marketBalances = _marketBalances[underlying];
        Types.Deltas storage deltas = market.deltas;

        vars.onPool = marketBalances.scaledPoolSupplyBalance(user);
        vars.inP2P = marketBalances.scaledP2PSupplyBalance(user);

        (vars.toWithdraw, amount, vars.onPool) = _subFromPool(amount, vars.onPool, indexes.supply.poolIndex);
        if (amount == 0) {
            _updateSupplierInDS(underlying, user, vars.onPool, vars.inP2P);
            return vars;
        }
        vars.inP2P -= Math.min(vars.inP2P, amount.rayDiv(indexes.supply.p2pIndex)); // In peer-to-peer supply unit.

        _withdrawIdle(market, amount, vars.inP2P, indexes.supply.p2pIndex);
        _updateSupplierInDS(underlying, user, vars.onPool, vars.inP2P);

        (vars.toWithdraw, amount) = _matchDelta(underlying, amount, indexes.supply.poolIndex, false);
        deltas.supply.scaledTotalP2P -= vars.toWithdraw.rayDiv(indexes.supply.p2pIndex);
        emit Events.P2PAmountsUpdated(underlying, deltas.supply.scaledTotalP2P, deltas.borrow.scaledTotalP2P);

        uint256 toWithdrawFromPromote;
        (toWithdrawFromPromote, amount, maxLoops) = _promoteRoutine(
            Types.PromoteVars({
                underlying: underlying,
                amount: amount,
                poolIndex: indexes.supply.poolIndex,
                maxLoops: maxLoops,
                promote: _promoteSuppliers
            }),
            _marketBalances[underlying].poolSuppliers,
            _market[underlying].deltas.supply
        );
        vars.toWithdraw += toWithdrawFromPromote;

        vars.toBorrow = _demoteRoutine(underlying, amount, maxLoops, indexes, _demoteBorrowers, deltas, true);
    }

    /// @notice Given variables from a market side, calculates the amount to supply/borrow and a new on pool amount.
    /// @param amount The amount to supply/borrow.
    /// @param onPool The current user's scaled on pool balance.
    /// @param poolIndex The current pool index.
    /// @return The amount to supply/borrow and the new on pool amount.
    function _addToPool(uint256 amount, uint256 onPool, uint256 poolIndex) internal pure returns (uint256, uint256) {
        if (amount > 0) {
            onPool += amount.rayDiv(poolIndex); // In scaled balance.
        }
        return (amount, onPool);
    }

    /// @notice Given variables from a market side, calculates the amount to repay/withdraw, the amount left to process, and a new on pool amount.
    /// @param amount The amount to repay/withdraw.
    /// @param onPool The current user's scaled on pool balance.
    /// @param poolIndex The current pool index.
    /// @return The amount to repay/withdraw, the amount left to process, and the new on pool amount.
    function _subFromPool(uint256 amount, uint256 onPool, uint256 poolIndex)
        internal
        pure
        returns (uint256, uint256, uint256)
    {
        uint256 toProcess;
        if (onPool > 0) {
            toProcess = Math.min(onPool.rayMul(poolIndex), amount);
            amount -= toProcess;
            onPool -= Math.min(onPool, toProcess.rayDiv(poolIndex)); // In scaled balance.
        }
        return (toProcess, amount, onPool);
    }

    /// @notice Given variables from a market side, promotes users and calculates the amount to repay/withdraw from promote,
    ///         the amount left to process, and the number of loops left. Updates the market side delta accordingly.
    /// @param vars The variables for promotion.
    /// @param heap The heap to promote.
    /// @param promotedDelta The market side delta to update.
    /// @return The amount to repay/withdraw from promote, the amount left to process, and the number of loops left.
    function _promoteRoutine(
        Types.PromoteVars memory vars,
        ThreeHeapOrdering.HeapArray storage heap,
        Types.MarketSideDelta storage promotedDelta
    ) internal returns (uint256, uint256, uint256) {
        uint256 toProcess;
        if (vars.amount > 0 && !_market[vars.underlying].pauseStatuses.isP2PDisabled && heap.getHead() != address(0)) {
            (uint256 promoted, uint256 loopsDone) = vars.promote(vars.underlying, vars.amount, vars.maxLoops); // In underlying.

            toProcess = promoted;
            vars.amount -= promoted;
            promotedDelta.scaledTotalP2P += promoted.rayDiv(vars.poolIndex);
            vars.maxLoops -= loopsDone;
        }
        return (toProcess, vars.amount, vars.maxLoops);
    }

    /// @notice Given variables from a market side, demotes users and calculates the amount to supply/borrow from demote.
    ///         Updates the market side delta accordingly.
    /// @param underlying The underlying address.
    /// @param amount The amount to supply/borrow.
    /// @param maxLoops The maximum number of loops to run.
    /// @param indexes The current indexes.
    /// @param demote The demote function.
    /// @param deltas The market side deltas to update.
    /// @param borrow Whether the market side is borrow.
    /// @return toProcess The amount to supply/borrow from demote.
    function _demoteRoutine(
        address underlying,
        uint256 amount,
        uint256 maxLoops,
        Types.Indexes256 memory indexes,
        function(address, uint256, uint256) returns (uint256) demote,
        Types.Deltas storage deltas,
        bool borrow
    ) internal returns (uint256 toProcess) {
        Types.MarketSideIndexes256 memory demotedIndexes = borrow ? indexes.borrow : indexes.supply;
        Types.MarketSideIndexes256 memory counterIndexes = borrow ? indexes.supply : indexes.borrow;
        Types.MarketSideDelta storage demotedDelta = borrow ? deltas.borrow : deltas.supply;
        Types.MarketSideDelta storage counterDelta = borrow ? deltas.supply : deltas.borrow;

        if (amount > 0) {
            uint256 demoted = demote(underlying, amount, maxLoops);

            // Increase the peer-to-peer supply delta.
            if (demoted < amount) {
                demotedDelta.scaledDeltaPool += (amount - demoted).rayDiv(demotedIndexes.poolIndex);
                if (borrow) emit Events.P2PBorrowDeltaUpdated(underlying, demotedDelta.scaledDeltaPool);
                else emit Events.P2PSupplyDeltaUpdated(underlying, demotedDelta.scaledDeltaPool);
            }

            // Math.min as the last decimal might flip.
            demotedDelta.scaledTotalP2P -=
                Math.min(demoted.rayDiv(demotedIndexes.p2pIndex), demotedDelta.scaledTotalP2P);
            counterDelta.scaledTotalP2P -= Math.min(amount.rayDiv(counterIndexes.p2pIndex), counterDelta.scaledTotalP2P);
            emit Events.P2PAmountsUpdated(underlying, deltas.supply.scaledTotalP2P, deltas.borrow.scaledTotalP2P);

            toProcess = amount;
        }
    }

    /// @notice Given variables from a market side, matches the delta and calculates the amount to supply/borrow from delta.
    ///         Updates the market side delta accordingly.
    /// @param underlying The underlying address.
    /// @param amount The amount to supply/borrow.
    /// @param poolIndex The current pool index.
    /// @param borrow Whether the market side is borrow.
    /// @return The amount to repay/withdraw and the amount left to process.
    function _matchDelta(address underlying, uint256 amount, uint256 poolIndex, bool borrow)
        internal
        returns (uint256, uint256)
    {
        Types.MarketSideDelta storage sideDelta =
            borrow ? _market[underlying].deltas.borrow : _market[underlying].deltas.supply;
        uint256 toProcess;

        if (sideDelta.scaledDeltaPool > 0) {
            uint256 matchedDelta = Math.min(sideDelta.scaledDeltaPool.rayMul(poolIndex), amount); // In underlying.

            sideDelta.scaledDeltaPool = sideDelta.scaledDeltaPool.zeroFloorSub(amount.rayDiv(poolIndex));
            toProcess = matchedDelta;
            amount -= matchedDelta;
            if (borrow) emit Events.P2PBorrowDeltaUpdated(underlying, sideDelta.scaledDeltaPool);
            else emit Events.P2PSupplyDeltaUpdated(underlying, sideDelta.scaledDeltaPool);
        }
        return (toProcess, amount);
    }

    /// @notice Updates the delta and p2p amounts for a repay or withdraw after a promotion.
    /// @param underlying The underlying address.
    /// @param toProcess The amount to repay/withdraw.
    /// @param p2pIndex The current p2p index.
    /// @param inP2P The amount in p2p.
    /// @param marketSideDelta The market side delta to update.
    /// @return The new amount in p2p.
    function _updateP2PDelta(
        address underlying,
        uint256 toProcess,
        uint256 p2pIndex,
        uint256 inP2P,
        Types.MarketSideDelta storage marketSideDelta
    ) internal returns (uint256) {
        if (toProcess > 0) {
            Types.Deltas storage deltas = _market[underlying].deltas;
            uint256 toProcessP2P = toProcess.rayDiv(p2pIndex);

            marketSideDelta.scaledTotalP2P += toProcessP2P;
            inP2P += toProcessP2P;

            emit Events.P2PAmountsUpdated(underlying, deltas.supply.scaledTotalP2P, deltas.borrow.scaledTotalP2P);
        }
        return inP2P;
    }

    /// @notice Calculates a new amount accounting for any fee required to be deducted by the delta.
    /// @param underlying The underlying address.
    /// @param amount The amount to repay/withdraw.
    /// @param indexes The current indexes.
    /// @return The new amount left to process.
    function _repayFee(address underlying, uint256 amount, Types.Indexes256 memory indexes)
        internal
        returns (uint256)
    {
        // Repay the fee.
        if (amount > 0) {
            Types.Deltas storage deltas = _market[underlying].deltas;
            // Fee = (borrow.totalScaledP2P - borrow.delta) - (supply.totalScaledP2P - supply.delta).
            // No need to subtract borrow.delta as it is zero.
            uint256 feeToRepay = Math.zeroFloorSub(
                deltas.borrow.scaledTotalP2P.rayMul(indexes.borrow.p2pIndex),
                deltas.supply.scaledTotalP2P.rayMul(indexes.supply.p2pIndex).zeroFloorSub(
                    deltas.supply.scaledDeltaPool.rayMul(indexes.supply.poolIndex)
                )
            );

            if (feeToRepay > 0) {
                feeToRepay = Math.min(feeToRepay, amount);
                amount -= feeToRepay;
                deltas.borrow.scaledTotalP2P -= feeToRepay.rayDiv(indexes.borrow.p2pIndex);
                emit Events.P2PAmountsUpdated(underlying, deltas.supply.scaledTotalP2P, deltas.borrow.scaledTotalP2P);
            }
        }
        return amount;
    }

    /// @notice Adds to idle supply if the supply cap is reached in a breaking repay, and returns a new toSupply amount.
    /// @param underlying The underlying address.
    /// @param amount The amount to repay. (by supplying on pool)
    /// @return toSupply The new amount to supply.
    function _handleSupplyCap(address underlying, uint256 amount) internal returns (uint256 toSupply) {
        DataTypes.ReserveConfigurationMap memory config = _POOL.getConfiguration(underlying);
        uint256 supplyCap = config.getSupplyCap() * (10 ** config.getDecimals());
        if (supplyCap == 0) return amount;

        uint256 totalSupply = ERC20(_market[underlying].aToken).totalSupply();
        if (totalSupply + amount > supplyCap) {
            toSupply = supplyCap - totalSupply;
            _market[underlying].idleSupply += amount - toSupply;
        } else {
            toSupply = amount;
        }
    }

    /// @notice Withdraws idle supply.
    /// @param market The market storage.
    /// @param amount The amount to withdraw.
    /// @param inP2P The user's amount in p2p.
    /// @param p2pSupplyIndex The current p2p supply index.
    function _withdrawIdle(Types.Market storage market, uint256 amount, uint256 inP2P, uint256 p2pSupplyIndex)
        internal
    {
        if (amount > 0 && market.idleSupply > 0 && inP2P > 0) {
            uint256 matchedIdle = Math.min(Math.min(market.idleSupply, amount), inP2P.rayMul(p2pSupplyIndex));
            market.idleSupply -= matchedIdle;
        }
    }

    /// @notice Borrows idle supply and returns an updated p2p balance.
    /// @param market The market storage.
    /// @param amount The amount to borrow.
    /// @param inP2P The user's amount in p2p.
    /// @param p2pBorrowIndex The current p2p borrow index.
    /// @return The amount left to process, and the updated p2p amount of the user.
    function _borrowIdle(Types.Market storage market, uint256 amount, uint256 inP2P, uint256 p2pBorrowIndex)
        internal
        returns (uint256, uint256)
    {
        uint256 idleSupply = market.idleSupply;
        if (idleSupply > 0) {
            uint256 matchedIdle = Math.min(idleSupply, amount); // In underlying.
            market.idleSupply -= matchedIdle;
            amount -= matchedIdle;
            inP2P += matchedIdle.rayDiv(p2pBorrowIndex);
        }
        return (amount, inP2P);
    }
}
