// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import {MarketLib, MarketBalanceLib} from "./libraries/Libraries.sol";
import {Types} from "./libraries/Types.sol";
import {Events} from "./libraries/Events.sol";
import {Errors} from "./libraries/Errors.sol";
import {DelegateCall} from "@morpho-utils/DelegateCall.sol";

import {MorphoGetters} from "./MorphoGetters.sol";
import {MorphoSetters} from "./MorphoSetters.sol";
import {EntryPositionsManager} from "./EntryPositionsManager.sol";
import {ExitPositionsManager} from "./ExitPositionsManager.sol";

import {IERC1155} from "./interfaces/IERC1155.sol";

// @note: To add: IERC1155, Ownable
contract Morpho is MorphoGetters, MorphoSetters {
    using MarketBalanceLib for Types.MarketBalances;
    using MarketLib for Types.Market;
    using DelegateCall for address;

    /// EXTERNAL ///

    function supply(address poolToken, uint256 amount, address onBehalf, uint256 maxLoops)
        external
        returns (uint256 supplied)
    {
        bytes memory returnData = _entryPositionsManager.functionDelegateCall(
            abi.encodeWithSelector(
                EntryPositionsManager.supplyLogic.selector, poolToken, amount, msg.sender, onBehalf, maxLoops
            )
        );
        return (abi.decode(returnData, (uint256)));
    }

    function supplyCollateral(address poolToken, uint256 amount, address onBehalf)
        external
        returns (uint256 supplied)
    {
        bytes memory returnData = _entryPositionsManager.functionDelegateCall(
            abi.encodeWithSelector(
                EntryPositionsManager.supplyCollateralLogic.selector, poolToken, amount, msg.sender, onBehalf
            )
        );
        return (abi.decode(returnData, (uint256)));
    }

    function borrow(address poolToken, uint256 amount, address receiver, uint256 maxLoops)
        external
        returns (uint256 borrowed)
    {
        bytes memory returnData = _entryPositionsManager.functionDelegateCall(
            abi.encodeWithSelector(
                EntryPositionsManager.borrowLogic.selector, poolToken, amount, msg.sender, receiver, maxLoops
            )
        );
        return (abi.decode(returnData, (uint256)));
    }

    function repay(address poolToken, uint256 amount, address onBehalf, uint256 maxLoops)
        external
        returns (uint256 repaid)
    {
        bytes memory returnData = _exitPositionsManager.functionDelegateCall(
            abi.encodeWithSelector(
                ExitPositionsManager.repayLogic.selector, poolToken, amount, msg.sender, onBehalf, maxLoops
            )
        );
        return (abi.decode(returnData, (uint256)));
    }

    function withdraw(address poolToken, uint256 amount, address to, uint256 maxLoops)
        external
        returns (uint256 withdrawn)
    {
        bytes memory returnData = _exitPositionsManager.functionDelegateCall(
            abi.encodeWithSelector(
                ExitPositionsManager.withdrawLogic.selector, poolToken, amount, msg.sender, to, maxLoops
            )
        );
        return (abi.decode(returnData, (uint256)));
    }

    function withdrawCollateral(address poolToken, uint256 amount, address to) external returns (uint256 withdrawn) {
        bytes memory returnData = _exitPositionsManager.functionDelegateCall(
            abi.encodeWithSelector(
                ExitPositionsManager.withdrawCollateralLogic.selector, poolToken, amount, msg.sender, to
            )
        );
        return (abi.decode(returnData, (uint256)));
    }

    function liquidate(address poolTokenBorrowed, address poolTokenCollateral, address user, uint256 amount)
        external
        returns (uint256 repaid, uint256 seized)
    {
        bytes memory returnData = _exitPositionsManager.functionDelegateCall(
            abi.encodeWithSelector(
                ExitPositionsManager.liquidateLogic.selector,
                poolTokenBorrowed,
                poolTokenCollateral,
                amount,
                user,
                msg.sender
            )
        );
        return (abi.decode(returnData, (uint256, uint256)));
    }
}
