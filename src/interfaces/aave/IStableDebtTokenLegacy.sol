// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.5.0;

interface IStableDebtTokenLegacy {
    function getSupplyData() external view returns (uint256, uint256, uint256, uint40);
}
