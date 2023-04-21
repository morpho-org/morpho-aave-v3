// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IWETHGateway} from "src/interfaces/extensions/IWETHGateway.sol";

import {WETHGateway} from "src/extensions/WETHGateway.sol";

import "test/helpers/IntegrationTest.sol";

contract TestIntegrationEModeNative is IntegrationTest {
    using PercentageMath for uint256;
    using TestMarketLib for TestMarket;
    using ReserveConfiguration for DataTypes.ReserveConfigurationMap;

    function setUp() public virtual override {
        DataTypes.ReserveConfigurationMap memory stakedConfig = pool.getConfiguration(sNative);

        eModeCategoryId = uint8(stakedConfig.getEModeCategory());

        super.setUp();
    }

    function testShouldLeverageStakedNative(uint256 rawCollateral, address onBehalf, address receiver) public {
        onBehalf = _boundOnBehalf(onBehalf);
        receiver = _boundReceiver(receiver);

        _assumeETHReceiver(receiver);
        _prepareOnBehalf(onBehalf);

        TestMarket storage sNativeMarket = testMarkets[sNative];
        TestMarket storage wNativeMarket = testMarkets[wNative];

        rawCollateral = _boundCollateral(sNativeMarket, rawCollateral, wNativeMarket);
        uint256 borrowed = wNativeMarket.borrowable(sNativeMarket, rawCollateral, eModeCategoryId);

        user.approve(sNative, rawCollateral);
        user.supplyCollateral(sNative, rawCollateral, onBehalf);

        user.borrow(wNative, borrowed, onBehalf, receiver);

        user.withdrawCollateral(
            sNative,
            wNativeMarket.collateralized(sNativeMarket, rawCollateral, eModeCategoryId) - borrowed,
            onBehalf,
            receiver
        );
    }

    function testShouldNotLeverageNotStakedNative(
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

        vm.assume(collateralMarket.underlying != wNative && collateralMarket.underlying != sNative);

        rawCollateral = _boundCollateral(collateralMarket, rawCollateral, wNativeMarket);
        borrowed = bound(
            borrowed,
            wNativeMarket.borrowable(collateralMarket, rawCollateral, 0).percentAdd(20),
            wNativeMarket.borrowable(collateralMarket, rawCollateral, collateralMarket.eModeCategoryId).percentAdd(20)
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
