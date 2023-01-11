// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.17;

import {IMorpho} from "./interfaces/IMorpho.sol";
import {IPositionsManager} from "./interfaces/IPositionsManager.sol";
import {IRewardsController} from "@aave/periphery-v3/contracts/rewards/interfaces/IRewardsController.sol";

import {Events} from "./libraries/Events.sol";
import {Errors} from "./libraries/Errors.sol";
import {Constants} from "./libraries/Constants.sol";
import {DelegateCall} from "@morpho-utils/DelegateCall.sol";
import {ERC20, SafeTransferLib} from "@solmate/utils/SafeTransferLib.sol";

import {MorphoStorage} from "./MorphoStorage.sol";
import {MorphoGetters} from "./MorphoGetters.sol";
import {MorphoSetters} from "./MorphoSetters.sol";

contract Morpho is IMorpho, MorphoGetters, MorphoSetters {
    using DelegateCall for address;
    using SafeTransferLib for ERC20;

    /// CONSTRUCTOR ///

    constructor(address addressesProvider) MorphoStorage(addressesProvider) {}

    /// EXTERNAL ///

    function supply(address underlying, uint256 amount, address onBehalf, uint256 maxLoops)
        external
        returns (uint256 supplied)
    {
        return _supply(underlying, amount, msg.sender, onBehalf, maxLoops);
    }

    function supplyWithPermit(
        address underlying,
        uint256 amount,
        address onBehalf,
        uint256 maxLoops,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 supplied) {
        ERC20(underlying).permit(msg.sender, address(this), amount, deadline, v, r, s);
        return _supply(underlying, amount, msg.sender, onBehalf, maxLoops);
    }

    function supplyCollateral(address underlying, uint256 amount, address onBehalf)
        external
        returns (uint256 supplied)
    {
        return _supplyCollateral(underlying, amount, msg.sender, onBehalf);
    }

    function supplyCollateralWithPermit(
        address underlying,
        uint256 amount,
        address onBehalf,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 supplied) {
        ERC20(underlying).permit(msg.sender, address(this), amount, deadline, v, r, s);
        return _supplyCollateral(underlying, amount, msg.sender, onBehalf);
    }

    function borrow(address underlying, uint256 amount, address onBehalf, address receiver, uint256 maxLoops)
        external
        returns (uint256 borrowed)
    {
        return _borrow(underlying, amount, onBehalf, receiver, maxLoops);
    }

    function repay(address underlying, uint256 amount, address onBehalf, uint256 maxLoops)
        external
        returns (uint256 repaid)
    {
        return _repay(underlying, amount, msg.sender, onBehalf, maxLoops);
    }

    function repayWithPermit(
        address underlying,
        uint256 amount,
        address onBehalf,
        uint256 maxLoops,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 repaid) {
        ERC20(underlying).permit(msg.sender, address(this), amount, deadline, v, r, s);
        return _repay(underlying, amount, msg.sender, onBehalf, maxLoops);
    }

    function withdraw(address underlying, uint256 amount, address onBehalf, address receiver, uint256 maxLoops)
        external
        returns (uint256 withdrawn)
    {
        return _withdraw(underlying, amount, onBehalf, receiver, maxLoops);
    }

    function withdrawCollateral(address underlying, uint256 amount, address onBehalf, address receiver)
        external
        returns (uint256 withdrawn)
    {
        return _withdrawCollateral(underlying, amount, onBehalf, receiver);
    }

    function liquidate(address underlyingBorrowed, address underlyingCollateral, address user, uint256 amount)
        external
        returns (uint256 repaid, uint256 seized)
    {
        return _liquidate(underlyingBorrowed, underlyingCollateral, amount, user, msg.sender);
    }

    function approveManager(address manager, bool isAllowed) external {
        _approveManager(msg.sender, manager, isAllowed);
    }

    function approveManagerWithSig(
        address owner,
        address manager,
        bool isAllowed,
        uint256 nonce,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        if (uint256(s) > Constants.MAX_VALID_ECDSA_S) revert Errors.InvalidValueS();
        // v ∈ {27, 28} (source: https://ethereum.github.io/yellowpaper/paper.pdf #308)
        if (v != 27 && v != 28) revert Errors.InvalidValueV();
        bytes32 structHash =
            keccak256(abi.encode(Constants.AUTHORIZATION_TYPEHASH, owner, manager, isAllowed, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _computeDomainSeparator(), structHash));
        address signatory = ecrecover(digest, v, r, s);
        if (signatory == address(0)) revert Errors.InvalidSignatory();
        if (owner != signatory) revert Errors.InvalidSignatory();
        if (nonce != _userNonce[signatory]++) revert Errors.InvalidNonce();
        if (block.timestamp >= deadline) revert Errors.SignatureExpired();
        _approveManager(signatory, manager, isAllowed);
    }

    /// @notice Claims rewards for the given assets.
    /// @param assets The assets to claim rewards from (aToken or variable debt token).
    /// @param onBehalf The address for which rewards are claimed and sent to.
    /// @return rewardTokens The addresses of each reward token.
    /// @return claimedAmounts The amount of rewards claimed (in reward tokens).
    function claimRewards(address[] calldata assets, address onBehalf)
        external
        returns (address[] memory rewardTokens, uint256[] memory claimedAmounts)
    {
        if (_isClaimRewardsPaused) revert Errors.ClaimRewardsPaused();

        (rewardTokens, claimedAmounts) = _rewardsManager.claimRewards(assets, onBehalf);
        IRewardsController(_rewardsManager.getRewardsController()).claimAllRewardsToSelf(assets);

        for (uint256 i; i < rewardTokens.length; ++i) {
            uint256 claimedAmount = claimedAmounts[i];

            if (claimedAmount > 0) {
                ERC20(rewardTokens[i]).safeTransfer(onBehalf, claimedAmount);
                emit Events.RewardsClaimed(onBehalf, rewardTokens[i], claimedAmount);
            }
        }
    }

    /// INTERNAL ///

    function _supply(address underlying, uint256 amount, address from, address onBehalf, uint256 maxLoops)
        internal
        returns (uint256 supplied)
    {
        bytes memory returnData = _positionsManager.functionDelegateCall(
            abi.encodeWithSelector(IPositionsManager.supplyLogic.selector, underlying, amount, from, onBehalf, maxLoops)
        );
        return (abi.decode(returnData, (uint256)));
    }

    function _supplyCollateral(address underlying, uint256 amount, address from, address onBehalf)
        internal
        returns (uint256 supplied)
    {
        bytes memory returnData = _positionsManager.functionDelegateCall(
            abi.encodeWithSelector(IPositionsManager.supplyCollateralLogic.selector, underlying, amount, from, onBehalf)
        );

        return (abi.decode(returnData, (uint256)));
    }

    function _borrow(address underlying, uint256 amount, address onBehalf, address receiver, uint256 maxLoops)
        internal
        returns (uint256 borrowed)
    {
        bytes memory returnData = _positionsManager.functionDelegateCall(
            abi.encodeWithSelector(
                IPositionsManager.borrowLogic.selector, underlying, amount, onBehalf, receiver, maxLoops
            )
        );

        return (abi.decode(returnData, (uint256)));
    }

    function _repay(address underlying, uint256 amount, address from, address onBehalf, uint256 maxLoops)
        internal
        returns (uint256 repaid)
    {
        bytes memory returnData = _positionsManager.functionDelegateCall(
            abi.encodeWithSelector(IPositionsManager.repayLogic.selector, underlying, amount, from, onBehalf, maxLoops)
        );

        return (abi.decode(returnData, (uint256)));
    }

    function _withdraw(address underlying, uint256 amount, address onBehalf, address receiver, uint256 maxLoops)
        internal
        returns (uint256 withdrawn)
    {
        bytes memory returnData = _positionsManager.functionDelegateCall(
            abi.encodeWithSelector(
                IPositionsManager.withdrawLogic.selector, underlying, amount, onBehalf, receiver, maxLoops
            )
        );

        return (abi.decode(returnData, (uint256)));
    }

    function _withdrawCollateral(address underlying, uint256 amount, address onBehalf, address receiver)
        internal
        returns (uint256 withdrawn)
    {
        bytes memory returnData = _positionsManager.functionDelegateCall(
            abi.encodeWithSelector(
                IPositionsManager.withdrawCollateralLogic.selector, underlying, amount, onBehalf, receiver
            )
        );

        return (abi.decode(returnData, (uint256)));
    }

    function _liquidate(
        address underlyingBorrowed,
        address underlyingCollateral,
        uint256 amount,
        address borrower,
        address liquidator
    ) internal returns (uint256 repaid, uint256 seized) {
        bytes memory returnData = _positionsManager.functionDelegateCall(
            abi.encodeWithSelector(
                IPositionsManager.liquidateLogic.selector,
                underlyingBorrowed,
                underlyingCollateral,
                amount,
                borrower,
                liquidator
            )
        );

        return (abi.decode(returnData, (uint256, uint256)));
    }
}
