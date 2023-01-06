// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.17;

import {IRewardsManager} from "./interfaces/IRewardsManager.sol";
import {IPool, IPoolAddressesProvider} from "./interfaces/aave/IPool.sol";
import {Initializable} from "@openzeppelin-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin-upgradeable/access/OwnableUpgradeable.sol";

import {Types} from "./libraries/Types.sol";
import {Errors} from "./libraries/Errors.sol";
import {Constants} from "./libraries/Constants.sol";
import {WadRayMath} from "@morpho-utils/math/WadRayMath.sol";

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

abstract contract MorphoStorage is Initializable, OwnableUpgradeable {
    /// IMMUTABLES ///

    IPool internal immutable _POOL;
    IPoolAddressesProvider internal immutable _ADDRESSES_PROVIDER;

    /// STORAGE ///

    address[] internal _marketsCreated; // Keeps track of the created markets.
    mapping(address => Types.Market) internal _market;
    mapping(address => Types.MarketBalances) internal _marketBalances;
    mapping(address => EnumerableSet.AddressSet) internal _userCollaterals; // The collateral markets entered by a user.
    mapping(address => EnumerableSet.AddressSet) internal _userBorrows; // The borrow markets entered by a user.
    mapping(address => mapping(address => bool)) public _isManaging; // Whether a user is allowed to borrow or withdraw on behalf of another user. owner => manager => bool
    mapping(address => uint256) public userNonce; // The nonce of a user. Used to prevent replay attacks.

    uint256 internal _maxSortedUsers; // The max number of users to sort in the data structure.
    Types.MaxLoops internal _defaultMaxLoops;

    address internal _positionsManager;
    IRewardsManager internal _rewardsManager;

    address internal _treasuryVault;
    bool internal _isClaimRewardsPaused; // Whether claiming rewards is paused or not.

    /// @dev The contract is automatically marked as initialized when deployed to prevent highjacking the implementation contract.
    constructor(address addressesProvider) {
        _disableInitializers();

        _ADDRESSES_PROVIDER = IPoolAddressesProvider(addressesProvider);
        _POOL = IPool(_ADDRESSES_PROVIDER.getPool());
    }
}
