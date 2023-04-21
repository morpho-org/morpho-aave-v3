// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.17;

import {IWETH} from "src/interfaces/IWETH.sol";
import {IMorpho} from "src/interfaces/IMorpho.sol";
import {IWSTETH} from "src/interfaces/extensions/IWSTETH.sol";
import {IBulkerGateway} from "src/interfaces/extensions/IBulkerGateway.sol";

import {Types} from "src/libraries/Types.sol";
import {SafeTransferLib, ERC20} from "@solmate/utils/SafeTransferLib.sol";
import {ERC20 as ERC20Permit2, Permit2Lib} from "@permit2/libraries/Permit2Lib.sol";

/// @title BulkerGateway.
/// @author Morpho Labs.
/// @custom:contact security@morpho.xyz
/// @notice Contract allowing to bundle multiple interactions with Morpho together.
contract BulkerGateway is IBulkerGateway {
    using SafeTransferLib for ERC20;
    using Permit2Lib for ERC20Permit2;

    /* CONSTANTS */

    /// @dev The address of the WETH contract.
    address internal constant _WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /// @dev The address of the stETH contract.
    address internal constant _ST_ETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    /// @dev The address of the wstETH contract.
    address internal constant _WST_ETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    /* IMMUTABLES */

    IMorpho internal immutable _MORPHO;

    /* CONSTRUCTOR */

    constructor(address morpho) {
        if (morpho == address(0)) revert AddressIsZero();

        _MORPHO = IMorpho(morpho);

        ERC20(_WETH).safeApprove(morpho, type(uint256).max);
        ERC20(_ST_ETH).safeApprove(_WST_ETH, type(uint256).max);
        ERC20(_WST_ETH).safeApprove(morpho, type(uint256).max);
    }

    /* EXTERNAL */

    /// @notice Returns the address of the WETH contract.
    function WETH() external pure returns (address) {
        return _WETH;
    }

    /// @notice Returns the address of the stETH contract.
    function stETH() external pure returns (address) {
        return _ST_ETH;
    }

    /// @notice Returns the address of the wstETH contract.
    function wstETH() external pure returns (address) {
        return _WST_ETH;
    }

    /// @notice Returns the address of the Morpho protocol.
    function MORPHO() external view returns (address) {
        return address(_MORPHO);
    }

    /// @notice Executes the given batch of actions, with the given input data.
    /// @param actions The batch of action to execute, one after the other.
    /// @param data The array of data corresponding to each input action.
    function execute(ActionType[] calldata actions, bytes[] calldata data) external payable {
        uint256 nbActions = actions.length;
        if (nbActions != data.length) {
            revert InconsistentParameters(nbActions, data.length);
        }

        for (uint256 i; i < nbActions; ++i) {
            _performAction(actions[i], data[i]);
        }
    }

    /// @dev Only the WETH contract is allowed to transfer ETH to this contract.
    receive() external payable {
        if (msg.sender != _WETH) revert OnlyWETH();
    }

    /* INTERNAL */

    /// @dev Performs the given action, given its associated parameters.
    /// @param action The type of action to perform on behalf of the caller.
    /// @param data The data to decode, associated with the action.
    function _performAction(ActionType action, bytes calldata data) internal {
        if (action == ActionType.APPROVE2) {
            _approve2(data);
        } else if (action == ActionType.TRANSFER_FROM2) {
            _transferFrom2(data);
        } else if (action == ActionType.APPROVE_MANAGER) {
            _approveManager(data);
        } else if (action == ActionType.SUPPLY) {
            _supply(data);
        } else if (action == ActionType.SUPPLY_COLLATERAL) {
            _supplyCollateral(data);
        } else if (action == ActionType.BORROW) {
            _borrow(data);
        } else if (action == ActionType.REPAY) {
            _repay(data);
        } else if (action == ActionType.WITHDRAW) {
            _withdraw(data);
        } else if (action == ActionType.WITHDRAW_COLLATERAL) {
            _withdrawCollateral(data);
        } else if (action == ActionType.WRAP_ETH) {
            _wrapEth(data);
        } else if (action == ActionType.UNWRAP_ETH) {
            _unwrapEth(data);
        } else if (action == ActionType.WRAP_ST_ETH) {
            _wrapStEth(data);
        } else if (action == ActionType.UNWRAP_ST_ETH) {
            _unwrapStEth(data);
        } else if (action == ActionType.SKIM) {
            _skim(data);
        } else if (action == ActionType.CLAIM_REWARDS) {
            _claimRewards(data);
        } else {
            revert UnsupportedAction(action);
        }
    }

    /* INTERNAL ACTIONS */

    /// @dev Approves the given `amount` of `asset` from sender to be spent by this contract via Permit2 with the given `deadline` & EIP712 `signature`.
    function _approve2(bytes calldata data) internal {
        (address asset, uint256 amount, uint256 deadline, Types.Signature memory signature) =
            abi.decode(data, (address, uint256, uint256, Types.Signature));
        if (amount == 0) revert AmountIsZero();

        ERC20Permit2(asset).simplePermit2(
            msg.sender, address(this), amount, deadline, signature.v, signature.r, signature.s
        );
    }

    /// @dev Transfers the given `amount` of `asset` from sender to this contract via ERC20 transfer with Permit2 fallback.
    function _transferFrom2(bytes calldata data) internal {
        (address asset, uint256 amount) = abi.decode(data, (address, uint256));
        if (amount == 0) revert AmountIsZero();

        ERC20Permit2(asset).transferFrom2(msg.sender, address(this), amount);
    }

    /// @dev Approves this contract to manage the position of `msg.sender` via EIP712 `signature`.
    function _approveManager(bytes calldata data) internal {
        (bool isAllowed, uint256 nonce, uint256 deadline, Types.Signature memory signature) =
            abi.decode(data, (bool, uint256, uint256, Types.Signature));

        _MORPHO.approveManagerWithSig(msg.sender, address(this), isAllowed, nonce, deadline, signature);
    }

    /// @dev Supplies `amount` of `asset` of `onBehalf` using permit2 in a single tx.
    ///         The supplied amount cannot be used as collateral but is eligible for the peer-to-peer matching.
    function _supply(bytes calldata data) internal {
        (address asset, uint256 amount, address onBehalf, uint256 maxIterations) =
            abi.decode(data, (address, uint256, address, uint256));
        if (amount == 0) revert AmountIsZero();

        _approveMaxToMorpho(asset);

        _MORPHO.supply(asset, amount, onBehalf, maxIterations);
    }

    /// @dev Supplies `amount` of `asset` collateral to the pool on behalf of `onBehalf`.
    function _supplyCollateral(bytes calldata data) internal {
        (address asset, uint256 amount, address onBehalf) = abi.decode(data, (address, uint256, address));
        if (amount == 0) revert AmountIsZero();

        _approveMaxToMorpho(asset);

        _MORPHO.supplyCollateral(asset, amount, onBehalf);
    }

    /// @dev Borrows `amount` of `asset` on behalf of the sender. Sender must have previously approved the bulker as their manager on Morpho.
    function _borrow(bytes calldata data) internal {
        (address asset, uint256 amount, address receiver, uint256 maxIterations) =
            abi.decode(data, (address, uint256, address, uint256));
        if (amount == 0) revert AmountIsZero();

        _MORPHO.borrow(asset, amount, msg.sender, receiver, maxIterations);
    }

    /// @dev Repays `amount` of `asset` on behalf of `onBehalf`.
    function _repay(bytes calldata data) internal {
        (address asset, uint256 amount, address onBehalf) = abi.decode(data, (address, uint256, address));
        if (amount == 0) revert AmountIsZero();

        _approveMaxToMorpho(asset);

        _MORPHO.repay(asset, amount, onBehalf);
    }

    /// @dev Withdraws `amount` of `asset` on behalf of `onBehalf`. Sender must have previously approved the bulker as their manager on Morpho.
    function _withdraw(bytes calldata data) internal {
        (address asset, uint256 amount, address receiver, uint256 maxIterations) =
            abi.decode(data, (address, uint256, address, uint256));
        if (amount == 0) revert AmountIsZero();

        _MORPHO.withdraw(asset, amount, msg.sender, receiver, maxIterations);
    }

    /// @dev Withdraws `amount` of `asset` on behalf of sender. Sender must have previously approved the bulker as their manager on Morpho.
    function _withdrawCollateral(bytes calldata data) internal {
        (address asset, uint256 amount, address receiver) = abi.decode(data, (address, uint256, address));
        if (amount == 0) revert AmountIsZero();

        _MORPHO.withdrawCollateral(asset, amount, msg.sender, receiver);
    }

    /// @dev Wraps the given input of ETH to WETH.
    function _wrapEth(bytes calldata data) internal {
        (uint256 amount) = abi.decode(data, (uint256));
        if (amount == 0) revert AmountIsZero();

        IWETH(_WETH).deposit{value: amount}();
    }

    /// @dev Unwraps the given input of WETH to ETH.
    function _unwrapEth(bytes calldata data) internal {
        (uint256 amount, address receiver) = abi.decode(data, (uint256, address));
        if (amount == 0) revert AmountIsZero();
        if (receiver == address(this)) revert TransferToSelf();

        IWETH(_WETH).withdraw(amount);

        SafeTransferLib.safeTransferETH(receiver, amount);
    }

    /// @dev Wraps the given input of stETH to wstETH.
    function _wrapStEth(bytes calldata data) internal {
        (uint256 amount) = abi.decode(data, (uint256));
        if (amount == 0) revert AmountIsZero();

        IWSTETH(_WST_ETH).wrap(amount);
    }

    /// @dev Unwraps the given input of wstETH to stETH.
    function _unwrapStEth(bytes calldata data) internal {
        (uint256 amount, address receiver) = abi.decode(data, (uint256, address));
        if (amount == 0) revert AmountIsZero();
        if (receiver == address(this)) revert TransferToSelf();

        uint256 unwrapped = IWSTETH(_WST_ETH).unwrap(amount);

        ERC20(_ST_ETH).safeTransfer(receiver, unwrapped);
    }

    /// @dev Sends any ERC20 in this contract to the receiver.
    function _skim(bytes calldata data) internal {
        (address asset, address receiver) = abi.decode(data, (address, address));
        if (receiver == address(this)) revert TransferToSelf();
        uint256 balance = ERC20(asset).balanceOf(address(this));
        ERC20(asset).safeTransfer(receiver, balance);
    }

    /// @dev Claims rewards for the given assets, on behalf of an address, sending the funds to the given address.
    function _claimRewards(bytes calldata data) internal {
        (address[] memory assets, address onBehalf) = abi.decode(data, (address[], address));
        _MORPHO.claimRewards(assets, onBehalf);
    }

    /* INTERNAL HELPERS */

    /// @dev Gives the max approval to the Morpho contract to spend the given `asset` if not already approved.
    function _approveMaxToMorpho(address asset) internal {
        if (ERC20(asset).allowance(address(this), address(_MORPHO)) == 0) {
            ERC20(asset).safeApprove(address(_MORPHO), type(uint256).max);
        }
    }
}
