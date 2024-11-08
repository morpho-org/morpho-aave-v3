// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IPoolConfigurator} from "@aave-v3-origin/interfaces/IPoolConfigurator.sol";

contract PoolAdminMock {
    IPoolConfigurator internal immutable _POOL_CONFIGURATOR;

    constructor(IPoolConfigurator poolConfigurator) {
        _POOL_CONFIGURATOR = poolConfigurator;
    }

    function setSupplyCap(address asset, uint256 supplyCap) external {
        _POOL_CONFIGURATOR.setSupplyCap(asset, supplyCap);
    }

    function setBorrowCap(address asset, uint256 borrowCap) external {
        _POOL_CONFIGURATOR.setBorrowCap(asset, borrowCap);
    }

    function setEModeCategory(
        uint8 eModeCategoryId,
        uint16 ltv,
        uint16 liquidationThreshold,
        uint16 liquidationBonus,
        string memory label
    ) external {
        _POOL_CONFIGURATOR.setEModeCategory(eModeCategoryId, ltv, liquidationThreshold, liquidationBonus, label);
    }

    function setAssetBorrowableInEMode(address asset, uint8 eModeCategoryId, bool borrowable) external {
        _POOL_CONFIGURATOR.setAssetBorrowableInEMode(asset, eModeCategoryId, borrowable);
    }

    function setAssetCollateralInEMode(address asset, uint8 eModeCategoryId, bool collateral) external {
        _POOL_CONFIGURATOR.setAssetCollateralInEMode(asset, eModeCategoryId, collateral);
    }

    function setReserveBorrowing(address asset, bool enabled) external {
        _POOL_CONFIGURATOR.setReserveBorrowing(asset, enabled);
    }
}
