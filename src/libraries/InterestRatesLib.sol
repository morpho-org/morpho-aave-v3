// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Types} from "./Types.sol";

import {Math} from "@morpho-utils/math/Math.sol";
import {WadRayMath} from "@morpho-utils/math/WadRayMath.sol";
import {PercentageMath} from "@morpho-utils/math/PercentageMath.sol";

/// @title InterestRatesLib
/// @author Morpho Labs
/// @custom:contact security@morpho.xyz
/// @notice Library helping to compute the new peer-to-peer indexes.
library InterestRatesLib {
    using WadRayMath for uint256;
    using PercentageMath for uint256;

    function computeP2PIndexes(Types.IndexesParams memory params)
        external
        pure
        returns (uint256 newP2PSupplyIndex, uint256 newP2PBorrowIndex)
    {
        // Compute pool growth factors.
        Types.GrowthFactors memory growthFactors = computeGrowthFactors(
            params.poolSupplyIndex,
            params.poolBorrowIndex,
            params.lastSupplyIndexes.poolIndex,
            params.lastBorrowIndexes.poolIndex,
            params.p2pIndexCursor,
            params.reserveFactor
        );
        newP2PSupplyIndex = computeP2PIndex(
            growthFactors.poolSupplyGrowthFactor,
            growthFactors.p2pSupplyGrowthFactor,
            params.lastSupplyIndexes,
            params.deltas.supply.scaledDeltaPool,
            params.deltas.supply.scaledTotalP2P,
            params.proportionIdle
        );
        newP2PBorrowIndex = computeP2PIndex(
            growthFactors.poolBorrowGrowthFactor,
            growthFactors.p2pBorrowGrowthFactor,
            params.lastBorrowIndexes,
            params.deltas.borrow.scaledDeltaPool,
            params.deltas.borrow.scaledTotalP2P,
            0
        );
    }

    /// @notice Computes and returns the new growth factors associated to a given pool's supply/borrow index & Morpho's peer-to-peer index.
    /// @param newPoolSupplyIndex The pool's current supply index.
    /// @param newPoolBorrowIndex The pool's current borrow index.
    /// @param lastPoolSupplyIndex The pool's last supply index.
    /// @param lastPoolBorrowIndex The pool's last borrow index.
    /// @param p2pIndexCursor The peer-to-peer index cursor for the given market.
    /// @param reserveFactor The reserve factor of the given market.
    /// @return growthFactors The market's indexes growth factors (in ray).
    function computeGrowthFactors(
        uint256 newPoolSupplyIndex,
        uint256 newPoolBorrowIndex,
        uint256 lastPoolSupplyIndex,
        uint256 lastPoolBorrowIndex,
        uint256 p2pIndexCursor,
        uint256 reserveFactor
    ) internal pure returns (Types.GrowthFactors memory growthFactors) {
        growthFactors.poolSupplyGrowthFactor = newPoolSupplyIndex.rayDiv(lastPoolSupplyIndex);
        growthFactors.poolBorrowGrowthFactor = newPoolBorrowIndex.rayDiv(lastPoolBorrowIndex);

        if (growthFactors.poolSupplyGrowthFactor <= growthFactors.poolBorrowGrowthFactor) {
            uint256 p2pGrowthFactor = PercentageMath.weightedAvg(
                growthFactors.poolSupplyGrowthFactor, growthFactors.poolBorrowGrowthFactor, p2pIndexCursor
            );

            growthFactors.p2pSupplyGrowthFactor =
                p2pGrowthFactor - (p2pGrowthFactor - growthFactors.poolSupplyGrowthFactor).percentMul(reserveFactor);
            growthFactors.p2pBorrowGrowthFactor =
                p2pGrowthFactor + (growthFactors.poolBorrowGrowthFactor - p2pGrowthFactor).percentMul(reserveFactor);
        } else {
            // The case poolSupplyGrowthFactor > poolBorrowGrowthFactor happens because someone has done a flashloan on Aave:
            // the peer-to-peer growth factors are set to the pool borrow growth factor.
            growthFactors.p2pSupplyGrowthFactor = growthFactors.poolBorrowGrowthFactor;
            growthFactors.p2pBorrowGrowthFactor = growthFactors.poolBorrowGrowthFactor;
        }
    }

    /// @notice Computes and returns the new peer-to-peer index of a market given its parameters.
    /// @param poolGrowthFactor The pool growth factor.
    /// @param p2pGrowthFactor The P2P growth factor.
    /// @param lastIndexes The last pool & peer-to-peer indexes.
    /// @param p2pDelta The last P2P delta.
    /// @param p2pAmount The last P2P amount.
    /// @return newP2PIndex The updated peer-to-peer index (in ray).
    function computeP2PIndex(
        uint256 poolGrowthFactor,
        uint256 p2pGrowthFactor,
        Types.MarketSideIndexes256 memory lastIndexes,
        uint256 p2pDelta,
        uint256 p2pAmount,
        uint256 proportionIdle
    ) internal pure returns (uint256) {
        if (p2pAmount == 0 || p2pDelta == 0) {
            return lastIndexes.p2pIndex.rayMul(p2pGrowthFactor);
        }

        uint256 proportionDelta = Math.min(
            p2pDelta.rayMul(lastIndexes.poolIndex).rayDivUp(p2pAmount.rayMul(lastIndexes.p2pIndex)),
            WadRayMath.RAY - proportionIdle // To avoid proportionDelta + proportionIdle > 1 with rounding errors.
        ); // in ray.

        // Equivalent to:
        // lastP2PIndex * (
        // p2pGrowthFactor * (1 - proportionDelta - proportionIdle) +
        // poolGrowthFactor * proportionDelta +
        // idleGrowthFactor * proportionIdle)
        return lastIndexes.p2pIndex.rayMul(
            p2pGrowthFactor.rayMul(WadRayMath.RAY - proportionDelta - proportionIdle)
                + poolGrowthFactor.rayMul(proportionDelta) + proportionIdle
        );
    }
}
