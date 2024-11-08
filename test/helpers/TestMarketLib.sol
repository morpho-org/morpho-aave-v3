// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Constants} from "src/libraries/Constants.sol";

import {Math} from "@morpho-utils/math/Math.sol";
import {PercentageMath} from "@morpho-utils/math/PercentageMath.sol";
import {DataTypes} from "@aave-v3-origin/protocol/libraries/types/DataTypes.sol";
import {EModeConfiguration} from "@aave-v3-origin/protocol/libraries/configuration/EModeConfiguration.sol";
import {collateralValue, rawCollateralValue} from "test/helpers/Utils.sol";

import {ERC20} from "@solmate/tokens/ERC20.sol";

struct TestMarket {
    address aToken;
    address variableDebtToken;
    address underlying;
    string symbol;
    uint256 decimals;
    uint256 reserveIndex;
    //
    uint256 ltv;
    uint256 lt;
    uint256 liquidationBonus;
    uint256 supplyCap;
    uint256 borrowCap;
    //
    uint16 reserveFactor;
    uint16 p2pIndexCursor;
    //
    uint256 price;
    uint256 minAmount;
    uint256 maxAmount;
    //
    DataTypes.CollateralConfig eModeCollateralConfig;
    uint128 eModeBorrowableBitmap;
    uint128 eModeCollateralBitmap;
    //
    bool isCollateral;
    bool isBorrowable;
}

library TestMarketLib {
    using Math for uint256;
    using PercentageMath for uint256;
    using EModeConfiguration for uint128;

    /// @dev Returns the quantity that can be borrowed/withdrawn from the market.
    function liquidity(TestMarket storage market) internal view returns (uint256) {
        return ERC20(market.underlying).balanceOf(market.aToken) * 99 / 100; // prevent an underflow in Aave's IRM
    }

    /// @dev Returns the quantity currently supplied on the market on AaveV3.
    function totalSupply(TestMarket storage market) internal view returns (uint256) {
        return ERC20(market.aToken).totalSupply();
    }

    /// @dev Returns the quantity currently borrowed (with variable only, stable being deprecated) on the market on AaveV3.
    function totalBorrow(TestMarket storage market) internal view returns (uint256) {
        return totalVariableBorrow(market);
    }

    /// @dev Returns the quantity currently borrowed with variable rate from the market on AaveV3.
    function totalVariableBorrow(TestMarket storage market) internal view returns (uint256) {
        return ERC20(market.variableDebtToken).totalSupply();
    }

    /// @dev Returns the quantity currently supplied on behalf of the user, on the market on AaveV3.
    function supplyOf(TestMarket storage market, address user) internal view returns (uint256) {
        return ERC20(market.aToken).balanceOf(user);
    }

    /// @dev Returns the quantity currently borrowed on behalf of the user, with variable rate, on the market on AaveV3.
    function variableBorrowOf(TestMarket storage market, address user) internal view returns (uint256) {
        return ERC20(market.variableDebtToken).balanceOf(user);
    }

    /// @dev Calculates the underlying amount that can be supplied on the given market on AaveV3, reaching the borrow cap.
    function borrowGap(TestMarket storage market) internal view returns (uint256) {
        return market.borrowCap.zeroFloorSub(totalBorrow(market));
    }

    /// @dev Quotes the given amount of base tokens as quote tokens.
    function quote(TestMarket storage quoteMarket, TestMarket storage baseMarket, uint256 amount)
        internal
        view
        returns (uint256)
    {
        return
            (amount * baseMarket.price * 10 ** quoteMarket.decimals) / (quoteMarket.price * 10 ** baseMarket.decimals);
    }

    function getHasTailoredParametersInEMode(TestMarket storage market, uint8 eModeCategoryId)
        internal
        view
        returns (bool)
    {
        if (eModeCategoryId == 0) return false;

        return market.eModeCollateralBitmap.isReserveEnabledOnBitmap(market.reserveIndex);
    }

    function getIsBorrowableInEMode(TestMarket storage market, uint8 eModeCategoryId) internal view returns (bool) {
        if (eModeCategoryId == 0) return true;

        return market.eModeBorrowableBitmap.isReserveEnabledOnBitmap(market.reserveIndex);
    }

    function getLtv(TestMarket storage collateralMarket, uint8 eModeCategoryId) internal view returns (uint256) {
        return getHasTailoredParametersInEMode(collateralMarket, eModeCategoryId)
            ? collateralMarket.eModeCollateralConfig.ltv
            : collateralMarket.ltv;
    }

    function getLt(TestMarket storage collateralMarket, uint8 eModeCategoryId) internal view returns (uint256) {
        uint256 ltv = getLtv(collateralMarket, eModeCategoryId);
        if (ltv == 0) return 0;

        return getHasTailoredParametersInEMode(collateralMarket, eModeCategoryId)
            ? collateralMarket.eModeCollateralConfig.liquidationThreshold
            : collateralMarket.lt;
    }

    /// @dev Calculates the maximum borrowable quantity collateralized by the given quantity of collateral.
    function borrowable(
        TestMarket storage borrowedMarket,
        TestMarket storage collateralMarket,
        uint256 rawCollateral,
        uint8 eModeCategoryId
    ) internal view returns (uint256) {
        uint256 ltv = getLtv(collateralMarket, eModeCategoryId);

        return quote(borrowedMarket, collateralMarket, collateralValue(rawCollateral))
            // The borrowable quantity is under-estimated because of decimals precision (especially for the pair WBTC/WETH).
            .percentMul(ltv - 10);
    }

    /// @dev Calculates the maximum borrowable quantity collateralized by the given quantity of collateral.
    function collateralized(
        TestMarket storage borrowedMarket,
        TestMarket storage collateralMarket,
        uint256 rawCollateral,
        uint8 eModeCategoryId
    ) internal view returns (uint256) {
        uint256 lt = getLt(collateralMarket, eModeCategoryId);

        return quote(borrowedMarket, collateralMarket, collateralValue(rawCollateral))
            // The collateralized quantity is under-estimated because of decimals precision (especially for the pair WBTC/WETH).
            .percentMul(lt - 10);
    }

    /// @dev Calculates the minimum collateral quantity necessary to collateralize the given quantity of debt while still being able to borrow.
    function minBorrowCollateral(
        TestMarket storage collateralMarket,
        TestMarket storage borrowedMarket,
        uint256 amount,
        uint8 eModeCategoryId
    ) internal view returns (uint256) {
        uint256 ltv = getLtv(collateralMarket, eModeCategoryId);

        return rawCollateralValue(
            quote(collateralMarket, borrowedMarket, amount)
                // The quantity of collateral required to open a borrow is over-estimated because of decimals precision (especially for the pair WBTC/WETH).
                .percentDiv(ltv - 15)
        );
    }

    /// @dev Calculates the minimum collateral quantity necessary to collateralize the given quantity of debt,
    ///      without necessarily being able to borrow more.
    function minCollateral(
        TestMarket storage collateralMarket,
        TestMarket storage borrowedMarket,
        uint256 amount,
        uint8 eModeCategoryId
    ) internal view returns (uint256) {
        uint256 lt = getLt(collateralMarket, eModeCategoryId);

        return rawCollateralValue(quote(collateralMarket, borrowedMarket, amount).percentDivUp(lt));
    }
}
