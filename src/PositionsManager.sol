// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.17;

import {IPool} from "@aave-v3-core/interfaces/IPool.sol";
import {IPositionsManager} from "./interfaces/IPositionsManager.sol";

import {Types} from "./libraries/Types.sol";
import {Events} from "./libraries/Events.sol";
import {PoolLib} from "./libraries/PoolLib.sol";
import {MarketBalanceLib} from "./libraries/MarketBalanceLib.sol";

import {Math} from "@morpho-utils/math/Math.sol";
import {WadRayMath} from "@morpho-utils/math/WadRayMath.sol";
import {PercentageMath} from "@morpho-utils/math/PercentageMath.sol";

import {Permit2Lib} from "./libraries/Permit2Lib.sol";
import {ERC20, SafeTransferLib} from "@solmate/utils/SafeTransferLib.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {MorphoStorage} from "./MorphoStorage.sol";
import {PositionsManagerInternal} from "./PositionsManagerInternal.sol";

contract PositionsManager is IPositionsManager, PositionsManagerInternal {
    using PoolLib for IPool;
    using Permit2Lib for ERC20;
    using SafeTransferLib for ERC20;
    using MarketBalanceLib for Types.MarketBalances;
    using EnumerableSet for EnumerableSet.AddressSet;

    using WadRayMath for uint256;
    using PercentageMath for uint256;

    /// CONSTRUCTOR ///

    constructor(address addressesProvider) MorphoStorage(addressesProvider) {}

    /// EXTERNAL ///

    function supplyLogic(address underlying, uint256 amount, address from, address onBehalf, uint256 maxLoops)
        external
        returns (uint256)
    {
        _validateSupplyInput(underlying, amount, onBehalf);

        Types.Indexes256 memory indexes = _updateIndexes(underlying);

        ERC20(underlying).transferFrom2(from, address(this), amount);

        (uint256 onPool, uint256 inP2P, uint256 toRepay, uint256 toSupply) =
            _executeSupply(underlying, amount, onBehalf, maxLoops, indexes);

        _POOL.repayToPool(underlying, _market[underlying].variableDebtToken, toRepay);
        _POOL.supplyToPool(underlying, toSupply);

        emit Events.Supplied(from, onBehalf, underlying, amount, onPool, inP2P);

        return toSupply + toRepay;
    }

    function supplyCollateralLogic(address underlying, uint256 amount, address from, address onBehalf)
        external
        returns (uint256)
    {
        _validateSupplyCollateralInput(underlying, amount, onBehalf);

        Types.Indexes256 memory indexes = _updateIndexes(underlying);

        ERC20(underlying).transferFrom2(from, address(this), amount);

        _marketBalances[underlying].collateral[onBehalf] += amount.rayDivDown(indexes.supply.poolIndex);
        _userCollaterals[onBehalf].add(underlying);

        _POOL.supplyToPool(underlying, amount);

        emit Events.CollateralSupplied(
            from, onBehalf, underlying, amount, _marketBalances[underlying].collateral[onBehalf]
            );

        return amount;
    }

    function borrowLogic(address underlying, uint256 amount, address borrower, address receiver, uint256 maxLoops)
        external
        returns (uint256)
    {
        _validateBorrowInput(underlying, amount, borrower, receiver);

        Types.Indexes256 memory indexes = _updateIndexes(underlying);

        // The following check requires storage indexes to be up-to-date.
        _validateBorrow(underlying, amount, borrower);

        Types.OutPositionVars memory vars = _executeBorrow(underlying, amount, borrower, maxLoops, indexes);

        _POOL.withdrawFromPool(underlying, _market[underlying].aToken, vars.toWithdraw);
        _POOL.borrowFromPool(underlying, vars.toBorrow);
        ERC20(underlying).safeTransfer(receiver, amount);

        emit Events.Borrowed(borrower, underlying, amount, vars.onPool, vars.inP2P);

        return vars.toBorrow + vars.toWithdraw;
    }

    function withdrawLogic(address underlying, uint256 amount, address supplier, address receiver)
        external
        returns (uint256)
    {
        _validateWithdrawInput(underlying, amount, supplier, receiver);

        Types.Indexes256 memory indexes = _updateIndexes(underlying);
        amount = Math.min(_getUserSupplyBalanceFromIndexes(underlying, supplier, indexes.supply), amount);

        if (amount == 0) return 0;

        Types.OutPositionVars memory vars =
            _executeWithdraw(underlying, amount, supplier, _defaultMaxLoops.withdraw, indexes);

        _POOL.withdrawFromPool(underlying, _market[underlying].aToken, vars.toWithdraw);
        _POOL.borrowFromPool(underlying, vars.toBorrow);
        ERC20(underlying).safeTransfer(receiver, amount);

        emit Events.Withdrawn(supplier, receiver, underlying, amount, vars.onPool, vars.inP2P);

        return vars.toBorrow + vars.toWithdraw;
    }

    function withdrawCollateralLogic(address underlying, uint256 amount, address supplier, address receiver)
        external
        returns (uint256)
    {
        _validateWithdrawCollateralInput(underlying, amount, supplier, receiver);

        Types.Indexes256 memory indexes = _updateIndexes(underlying);
        amount = Math.min(_getUserCollateralBalanceFromIndex(underlying, supplier, indexes.supply.poolIndex), amount);

        if (amount == 0) return 0;

        // The following check requires storage indexes to be up-to-date.
        _validateWithdrawCollateral(underlying, amount, supplier);

        uint256 newBalance =
            _marketBalances[underlying].collateral[supplier] - amount.rayDivUp(indexes.supply.poolIndex);
        _marketBalances[underlying].collateral[supplier] = newBalance;
        if (newBalance == 0) _userCollaterals[supplier].remove(underlying);

        _POOL.withdrawFromPool(underlying, _market[underlying].aToken, amount);
        ERC20(underlying).safeTransfer(receiver, amount);

        emit Events.CollateralWithdrawn(
            supplier, receiver, underlying, amount, _marketBalances[underlying].collateral[supplier]
            );

        return amount;
    }

    function repayLogic(address underlying, uint256 amount, address repayer, address onBehalf)
        external
        returns (uint256 repaid)
    {
        _validateRepayInput(underlying, amount, onBehalf);

        Types.Indexes256 memory indexes = _updateIndexes(underlying);
        amount = Math.min(_getUserBorrowBalanceFromIndexes(underlying, onBehalf, indexes.borrow), amount);

        if (amount == 0) return 0;

        ERC20(underlying).transferFrom2(repayer, address(this), amount);

        (uint256 onPool, uint256 inP2P, uint256 toRepay, uint256 toSupply) =
            _executeRepay(underlying, amount, onBehalf, _defaultMaxLoops.repay, indexes);

        _POOL.repayToPool(underlying, _market[underlying].variableDebtToken, toRepay);
        _POOL.supplyToPool(underlying, toSupply);

        emit Events.Repaid(repayer, onBehalf, underlying, amount, onPool, inP2P);

        return toSupply + toRepay;
    }

    struct LiquidateVars {
        uint256 closeFactor;
        uint256 amountToLiquidate;
        uint256 amountToSeize;
        uint256 toSupply;
        uint256 toRepay;
        uint256 toBorrow;
        uint256 toWithdraw;
    }

    function liquidateLogic(
        address underlyingBorrowed,
        address underlyingCollateral,
        uint256 amount,
        address borrower,
        address liquidator
    ) external returns (uint256 liquidated, uint256 seized) {
        LiquidateVars memory vars;

        Types.Indexes256 memory borrowIndexes = _updateIndexes(underlyingBorrowed);
        Types.Indexes256 memory collateralIndexes = _updateIndexes(underlyingCollateral);

        vars.closeFactor = _validateLiquidate(underlyingBorrowed, underlyingCollateral, borrower);

        vars.amountToLiquidate = Math.min(
            amount,
            _getUserBorrowBalanceFromIndexes(underlyingBorrowed, borrower, borrowIndexes.borrow).percentMul(
                vars.closeFactor
            ) // Max liquidatable debt.
        );

        (vars.amountToLiquidate, vars.amountToSeize) = _calculateAmountToSeize(
            underlyingBorrowed, underlyingCollateral, vars.amountToLiquidate, borrower, collateralIndexes.supply
        );

        ERC20(underlyingBorrowed).transferFrom2(liquidator, address(this), vars.amountToLiquidate);

        (,, vars.toRepay, vars.toSupply) =
            _executeRepay(underlyingBorrowed, vars.amountToLiquidate, borrower, 0, borrowIndexes);
        Types.OutPositionVars memory withdrawVars =
            _executeWithdraw(underlyingCollateral, vars.amountToSeize, borrower, 0, collateralIndexes);

        vars.toWithdraw = withdrawVars.toWithdraw;
        vars.toBorrow = withdrawVars.toBorrow;

        _POOL.repayToPool(underlyingBorrowed, _market[underlyingBorrowed].variableDebtToken, vars.toRepay);
        _POOL.supplyToPool(underlyingBorrowed, vars.toSupply);
        _POOL.withdrawFromPool(underlyingCollateral, _market[underlyingCollateral].aToken, vars.toWithdraw);
        _POOL.borrowFromPool(underlyingCollateral, vars.toBorrow);

        ERC20(underlyingCollateral).safeTransfer(liquidator, vars.amountToSeize);

        emit Events.Liquidated(
            liquidator, borrower, underlyingBorrowed, vars.amountToLiquidate, underlyingCollateral, vars.amountToSeize
            );
        return (vars.amountToLiquidate, vars.amountToSeize);
    }
}
