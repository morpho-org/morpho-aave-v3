// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IWETHGateway} from "src/interfaces/extensions/IWETHGateway.sol";

import {WETHGateway} from "src/extensions/WETHGateway.sol";

import {EModeConfiguration} from "@aave-v3-origin/protocol/libraries/configuration/EModeConfiguration.sol";

import "test/helpers/IntegrationTest.sol";

contract TestIntegrationEModeNative is IntegrationTest {
    using Math for uint256;
    using PercentageMath for uint256;
    using TestMarketLib for TestMarket;
    using EModeConfiguration for uint128;

    function setUp() public virtual override {
        // Guess the eModeCategoryId for LSD to be 1.
        eModeCategoryId = 1;

        // Verify the guess that eModeCategoryId for LSD is 1.
        uint256 stNativeIndex = pool.getReserveData(stNative).id;
        DataTypes.CollateralConfig memory collateralConfig = pool.getEModeCategoryCollateralConfig(eModeCategoryId);
        require(collateralConfig.liquidationThreshold != 0, "not activated e-mode");
        require(
            pool.getEModeCategoryCollateralBitmap(eModeCategoryId).isReserveEnabledOnBitmap(stNativeIndex),
            "wrong e-mode category"
        );

        super.setUp();
    }

    function testShouldLeverageLsdNative(uint256 seed, uint256 rawCollateral, address onBehalf, address receiver)
        public
    {
        onBehalf = _boundOnBehalf(onBehalf);
        receiver = _boundReceiver(receiver);

        _assumeETHReceiver(receiver);
        _prepareOnBehalf(onBehalf);

        address lsdNative = _randomLsdNative(seed);

        TestMarket storage lsdNativeMarket = testMarkets[lsdNative];
        TestMarket storage wNativeMarket = testMarkets[wNative];

        rawCollateral = _boundCollateral(lsdNativeMarket, rawCollateral, wNativeMarket);
        uint256 borrowed = wNativeMarket.borrowable(lsdNativeMarket, rawCollateral, eModeCategoryId);

        user.approve(lsdNative, rawCollateral);
        user.supplyCollateral(lsdNative, rawCollateral, onBehalf);

        user.borrow(wNative, borrowed, onBehalf, receiver);

        user.withdrawCollateral(
            lsdNative,
            rawCollateral.zeroFloorSub(
                lsdNativeMarket.minCollateral(wNativeMarket, borrowed, eModeCategoryId).percentAdd(5)
            ),
            onBehalf,
            receiver
        );
    }

    function testShouldNotLeverageNotLsdNative(
        uint256 seed,
        uint256 rawCollateral,
        uint256 borrowed,
        address onBehalf,
        address receiver
    ) public {
        onBehalf = _boundOnBehalf(onBehalf);
        receiver = _boundReceiver(receiver);

        _assumeETHReceiver(receiver);
        _prepareOnBehalf(onBehalf);

        TestMarket storage wNativeMarket = testMarkets[wNative];

        TestMarket storage collateralMarket = testMarkets[_randomCollateral(seed)];

        _assumeNotLsdNative(collateralMarket.underlying);
        vm.assume(collateralMarket.underlying != wNative);

        rawCollateral = _boundCollateral(collateralMarket, rawCollateral, wNativeMarket);
        borrowed = bound(
            borrowed,
            wNativeMarket.borrowable(collateralMarket, rawCollateral, 0).percentAdd(20),
            wNativeMarket.borrowable(collateralMarket, rawCollateral, eModeCategoryId).percentAdd(20)
        );

        user.approve(collateralMarket.underlying, rawCollateral);
        user.supplyCollateral(collateralMarket.underlying, rawCollateral, onBehalf);

        vm.expectRevert(Errors.UnauthorizedBorrow.selector);
        user.borrow(wNative, borrowed, onBehalf, receiver);
    }

    function testShouldNotBorrowNotNative(uint256 seed, uint256 amount, address onBehalf, address receiver) public {
        onBehalf = _boundOnBehalf(onBehalf);
        receiver = _boundReceiver(receiver);

        _prepareOnBehalf(onBehalf);

        TestMarket storage market = testMarkets[_randomBorrowableNotInEMode(seed)];

        amount = _boundBorrow(market, amount);

        vm.expectRevert(Errors.InconsistentEMode.selector);
        user.borrow(market.underlying, amount, onBehalf, receiver);
    }
}
