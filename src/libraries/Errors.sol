// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

library Errors {
    error MarketNotCreated();
    error UserNotMemberOfMarket();

    error AddressIsZero();
    error AmountIsZero();

    error SupplyIsPaused();
    error BorrowIsPaused();
    error RepayIsPaused();
    error WithdrawIsPaused();
    error LiquidateCollateralIsPaused();
    error LiquidateBorrowIsPaused();

    error BorrowingNotEnabled();
    error PriceOracleSentinelBorrowDisabled();
    error PriceOracleSentinelBorrowPaused();
    error UnauthorisedBorrow();

    error WithdrawUnauthorized();
    error UnauthorisedLiquidate();

    error ExceedsMaxBasisPoints();
    error MarketIsNotListedOnAave();
    error MarketAlreadyCreated();
    error MaxSortedUsersCannotBeZero();
}
