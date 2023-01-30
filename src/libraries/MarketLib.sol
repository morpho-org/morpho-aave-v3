// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.17;

import {IPool} from "@aave-v3-core/interfaces/IPool.sol";

import {Types} from "./Types.sol";
import {Events} from "./Events.sol";

import {Math} from "@morpho-utils/math/Math.sol";
import {WadRayMath} from "@morpho-utils/math/WadRayMath.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {DataTypes} from "@aave-v3-core/protocol/libraries/types/DataTypes.sol";
import {ReserveConfiguration} from "@aave-v3-core/protocol/libraries/configuration/ReserveConfiguration.sol";

import {ERC20} from "@solmate/tokens/ERC20.sol";

/// @title MarketLib
/// @author Morpho Labs
/// @custom:contact security@morpho.xyz
/// @notice Library used to ease market reads and writes.
library MarketLib {
    using Math for uint256;
    using SafeCast for uint256;
    using WadRayMath for uint256;
    using ReserveConfiguration for DataTypes.ReserveConfigurationMap;

    function isCreated(Types.Market storage market) internal view returns (bool) {
        return market.aToken != address(0);
    }

    function isSupplyPaused(Types.Market storage market) internal view returns (bool) {
        return market.pauseStatuses.isSupplyPaused;
    }

    function isSupplyCollateralPaused(Types.Market storage market) internal view returns (bool) {
        return market.pauseStatuses.isSupplyCollateralPaused;
    }

    function isBorrowPaused(Types.Market storage market) internal view returns (bool) {
        return market.pauseStatuses.isBorrowPaused;
    }

    function isRepayPaused(Types.Market storage market) internal view returns (bool) {
        return market.pauseStatuses.isRepayPaused;
    }

    function isWithdrawPaused(Types.Market storage market) internal view returns (bool) {
        return market.pauseStatuses.isWithdrawPaused;
    }

    function isWithdrawCollateralPaused(Types.Market storage market) internal view returns (bool) {
        return market.pauseStatuses.isWithdrawCollateralPaused;
    }

    function isLiquidateCollateralPaused(Types.Market storage market) internal view returns (bool) {
        return market.pauseStatuses.isLiquidateCollateralPaused;
    }

    function isLiquidateBorrowPaused(Types.Market storage market) internal view returns (bool) {
        return market.pauseStatuses.isLiquidateBorrowPaused;
    }

    function isDeprecated(Types.Market storage market) internal view returns (bool) {
        return market.pauseStatuses.isDeprecated;
    }

    function isP2PDisabled(Types.Market storage market) internal view returns (bool) {
        return market.pauseStatuses.isP2PDisabled;
    }

    function setIsSupplyPaused(Types.Market storage market, bool isPaused) internal {
        market.pauseStatuses.isSupplyPaused = isPaused;

        emit Events.IsSupplyPausedSet(market.underlying, isPaused);
    }

    function setIsSupplyCollateralPaused(Types.Market storage market, bool isPaused) internal {
        market.pauseStatuses.isSupplyCollateralPaused = isPaused;

        emit Events.IsSupplyCollateralPausedSet(market.underlying, isPaused);
    }

    function setIsBorrowPaused(Types.Market storage market, bool isPaused) internal returns (bool) {
        if (isPaused || !market.pauseStatuses.isDeprecated) {
            market.pauseStatuses.isBorrowPaused = isPaused;
            emit Events.IsBorrowPausedSet(market.underlying, isPaused);
            return true;
        } else {
            return false;
        }
    }

    function setIsRepayPaused(Types.Market storage market, bool isPaused) internal {
        market.pauseStatuses.isRepayPaused = isPaused;

        emit Events.IsRepayPausedSet(market.underlying, isPaused);
    }

    function setIsWithdrawPaused(Types.Market storage market, bool isPaused) internal {
        market.pauseStatuses.isWithdrawPaused = isPaused;

        emit Events.IsWithdrawPausedSet(market.underlying, isPaused);
    }

    function setIsWithdrawCollateralPaused(Types.Market storage market, bool isPaused) internal {
        market.pauseStatuses.isWithdrawCollateralPaused = isPaused;

        emit Events.IsWithdrawCollateralPausedSet(market.underlying, isPaused);
    }

    function setIsLiquidateCollateralPaused(Types.Market storage market, bool isPaused) internal {
        market.pauseStatuses.isLiquidateCollateralPaused = isPaused;

        emit Events.IsLiquidateCollateralPausedSet(market.underlying, isPaused);
    }

    function setIsLiquidateBorrowPaused(Types.Market storage market, bool isPaused) internal {
        market.pauseStatuses.isLiquidateBorrowPaused = isPaused;

        emit Events.IsLiquidateBorrowPausedSet(market.underlying, isPaused);
    }

    function setIsDeprecated(Types.Market storage market, bool deprecated) internal returns (bool) {
        if (market.pauseStatuses.isBorrowPaused) {
            market.pauseStatuses.isDeprecated = deprecated;
            emit Events.IsDeprecatedSet(market.underlying, deprecated);
            return true;
        } else {
            return false;
        }
    }

    function setIsP2PDisabled(Types.Market storage market, bool p2pDisabled) internal {
        market.pauseStatuses.isP2PDisabled = p2pDisabled;

        emit Events.IsP2PDisabledSet(market.underlying, p2pDisabled);
    }

    function getSupplyIndexes(Types.Market storage market)
        internal
        view
        returns (Types.MarketSideIndexes256 memory supplyIndexes)
    {
        supplyIndexes.poolIndex = uint256(market.indexes.supply.poolIndex);
        supplyIndexes.p2pIndex = uint256(market.indexes.supply.p2pIndex);
    }

    function getBorrowIndexes(Types.Market storage market)
        internal
        view
        returns (Types.MarketSideIndexes256 memory borrowIndexes)
    {
        borrowIndexes.poolIndex = uint256(market.indexes.borrow.poolIndex);
        borrowIndexes.p2pIndex = uint256(market.indexes.borrow.p2pIndex);
    }

    function getIndexes(Types.Market storage market) internal view returns (Types.Indexes256 memory indexes) {
        indexes.supply = getSupplyIndexes(market);
        indexes.borrow = getBorrowIndexes(market);
    }

    function getProportionIdle(Types.Market storage market) internal view returns (uint256) {
        uint256 idleSupply = market.idleSupply;
        if (idleSupply == 0) return 0;

        uint256 totalP2PSupplied = market.deltas.supply.scaledTotalP2P.rayMul(market.indexes.supply.p2pIndex);
        return idleSupply.rayDivUp(totalP2PSupplied);
    }

    function setIndexes(Types.Market storage market, Types.Indexes256 memory indexes) internal {
        market.indexes.supply.poolIndex = indexes.supply.poolIndex.toUint128();
        market.indexes.supply.p2pIndex = indexes.supply.p2pIndex.toUint128();
        market.indexes.borrow.poolIndex = indexes.borrow.poolIndex.toUint128();
        market.indexes.borrow.p2pIndex = indexes.borrow.p2pIndex.toUint128();
        market.lastUpdateTimestamp = uint32(block.timestamp);
        emit Events.IndexesUpdated(
            market.underlying,
            indexes.supply.p2pIndex,
            indexes.borrow.p2pIndex,
            indexes.supply.poolIndex,
            indexes.borrow.poolIndex
            );
    }

    /// @dev Increases the idle supply if the supply cap is reached in a breaking repay, and returns a new toSupply amount.
    /// @param market The market storage.
    /// @param underlying The underlying address.
    /// @param amount The amount to repay. (by supplying on pool)
    /// @param configuration The reserve configuration for the market.
    /// @return toSupply The new amount to supply.
    function increaseIdle(
        Types.Market storage market,
        address underlying,
        uint256 amount,
        DataTypes.ReserveConfigurationMap memory configuration
    ) internal returns (uint256 toSupply) {
        uint256 supplyCap = configuration.getSupplyCap() * (10 ** configuration.getDecimals());
        if (supplyCap == 0) return amount;

        uint256 totalSupply = ERC20(market.aToken).totalSupply();
        if (totalSupply + amount <= supplyCap) return amount;

        toSupply = supplyCap.zeroFloorSub(totalSupply);
        uint256 newIdleSupply = market.idleSupply + amount - toSupply;
        market.idleSupply = newIdleSupply;

        emit Events.IdleSupplyUpdated(underlying, newIdleSupply);
    }

    /// @dev Decreases the idle supply.
    /// @param market The market storage.
    /// @param underlying The underlying address.
    /// @param amount The amount to borrow.
    /// @return The amount left to process, and the processed amount.
    function decreaseIdle(Types.Market storage market, address underlying, uint256 amount)
        internal
        returns (uint256, uint256)
    {
        if (amount == 0) return (0, 0);

        uint256 idleSupply = market.idleSupply;
        if (idleSupply == 0) return (amount, 0);

        uint256 matchedIdle = Math.min(idleSupply, amount); // In underlying.
        uint256 newIdleSupply = idleSupply.zeroFloorSub(matchedIdle);
        market.idleSupply = newIdleSupply;

        emit Events.IdleSupplyUpdated(underlying, newIdleSupply);

        return (amount - matchedIdle, matchedIdle);
    }
}
