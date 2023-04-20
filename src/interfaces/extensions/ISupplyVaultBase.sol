// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.5.0;

import {IERC4626Upgradeable} from "@openzeppelin-upgradeable/interfaces/IERC4626Upgradeable.sol";
import {IMorpho} from "src/interfaces/IMorpho.sol";

interface ISupplyVaultBase is IERC4626Upgradeable {
    /// EVENTS ///

    /// @notice Emitted when MORPHO rewards are transferred to `recipient`.
    /// @param recipient The recipient of the rewards.
    /// @param amount The amount of rewards transferred.
    event RewardsTransferred(address recipient, uint256 amount);

    /// ERRORS ///

    /// @notice Thrown when the zero address is passed as input or is the recipient address when calling `transferRewards`.
    error ZeroAddress();

    /// FUNCTIONS ///

    function morpho() external view returns (IMorpho);

    function underlying() external view returns (address);

    function recipient() external view returns (address);

    function transferRewards() external;
}
