// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.17;

import {IPermit2} from "../interfaces/IPermit2.sol";
import {IAllowanceTransfer} from "../interfaces/IAllowanceTransfer.sol";

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {ERC20} from "@solmate/tokens/ERC20.sol";

/// @title Permit2Lib
/// @notice Enables efficient transfers and EIP-2612 permits for any token by using Permit2.
/// @dev Modified version of the Permit2Lib from https://github.com/Uniswap/permit2.
///      The original version is licensed under the MIT license and has been modified to AGPL-3.0-only.
///      The most noticable change is the removal of the call to the permit function on the token
///      contract in the permit2 function. This is to simplify the library and reduce the operational costs
///      since now only the Permit2 allowance is updated. Transfers still rely on the token's transfer method, then fallback to Permit2's transfer.
library Permit2Lib {
    using SafeCast for uint256;

    /// CONSTANTS ///

    /// @dev The address of the Permit2 contract the library will use.
    IPermit2 internal constant PERMIT2 = IPermit2(address(0x000000000022D473030F116dDEE9F6B43aC78BA3));

    /// INTERNAL ///

    /// @notice Transfers a given amount of tokens from one user to another.
    /// @param token The token to transfer.
    /// @param from The user to transfer from.
    /// @param to The user to transfer to.
    /// @param amount The amount to transfer.
    function transferFrom2(ERC20 token, address from, address to, uint256 amount) internal {
        // Generate calldata for a standard transferFrom call.
        bytes memory inputData = abi.encodeCall(ERC20.transferFrom, (from, to, amount));

        bool success; // Call the token contract as normal, capturing whether it succeeded.
        assembly {
            success :=
                and(
                    // Set success to whether the call reverted, if not we check it either
                    // returned exactly 1 (can't just be non-zero data), or had no return data.
                    or(eq(mload(0), 1), iszero(returndatasize())),
                    // Counterintuitively, this call() must be positioned after the or() in the
                    // surrounding and() because and() evaluates its arguments from right to left.
                    // We use 0 and 32 to copy up to 32 bytes of return data into the first slot of scratch space.
                    call(gas(), token, 0, add(inputData, 32), mload(inputData), 0, 32)
                )
        }

        // We'll fall back to using Permit2 if calling transferFrom on the token directly reverted.
        if (!success) PERMIT2.transferFrom(from, to, amount.toUint160(), address(token));
    }

    /// @notice Permits a user to spend a given amount of
    /// another user's tokens via the owner's EIP-712 signature.
    /// @param token The token to permit spending.
    /// @param owner The user to permit spending from.
    /// @param spender The user to permit spending to.
    /// @param amount The amount to permit spending.
    /// @param deadline  The timestamp after which the signature is no longer valid.
    /// @param v Must produce valid secp256k1 signature from the owner along with r and s.
    /// @param r Must produce valid secp256k1 signature from the owner along with v and s.
    /// @param s Must produce valid secp256k1 signature from the owner along with r and v.
    function permit2(
        ERC20 token,
        address owner,
        address spender,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal {
        IAllowanceTransfer.PackedAllowance memory packedAllowance = PERMIT2.allowance(owner, address(token), spender);
        if (uint160(amount) == packedAllowance.amount) return;

        PERMIT2.permit(
            owner,
            IAllowanceTransfer.PermitSingle({
                details: IAllowanceTransfer.PermitDetails({
                    token: address(token),
                    amount: amount.toUint160(),
                    // Use an unlimited expiration because it most
                    // closely mimics how a standard approval works.
                    expiration: type(uint48).max,
                    nonce: packedAllowance.nonce
                }),
                spender: spender,
                sigDeadline: deadline
            }),
            bytes.concat(r, s, bytes1(v))
        );
    }
}
