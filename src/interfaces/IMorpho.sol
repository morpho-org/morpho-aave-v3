// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.5.0;

import {Types} from "../libraries/Types.sol";

interface IMorphoGetters {
    function POOL() external view returns (address);
    function ADDRESSES_PROVIDER() external view returns (address);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function E_MODE_CATEGORY_ID() external view returns (uint256);

    function market(address underlying) external view returns (Types.Market memory);
    function marketsCreated() external view returns (address[] memory);

    function scaledCollateralBalance(address underlying, address user) external view returns (uint256);
    function scaledP2PBorrowBalance(address underlying, address user) external view returns (uint256);
    function scaledP2PSupplyBalance(address underlying, address user) external view returns (uint256);
    function scaledPoolBorrowBalance(address underlying, address user) external view returns (uint256);
    function scaledPoolSupplyBalance(address underlying, address user) external view returns (uint256);

    function isManaging(address delegator, address manager) external view returns (bool);
    function userNonce(address user) external view returns (uint256);

    function defaultMaxIterations() external view returns (Types.MaxIterations memory);
    function positionsManager() external view returns (address);
    function rewardsManager() external view returns (address);
    function treasuryVault() external view returns (address);

    function isClaimRewardsPaused() external view returns (bool);

    function updatedIndexes(address underlying) external view returns (Types.Indexes256 memory);
    function liquidityData(address underlying, address user, uint256 amountWithdrawn, uint256 amountBorrowed)
        external
        view
        returns (Types.LiquidityData memory);
}

interface IMorphoSetters {
    function initialize(address newPositionsManager, Types.MaxIterations memory newDefaultMaxIterations) external;

    function createMarket(address underlying, uint16 reserveFactor, uint16 p2pIndexCursor) external;
    function increaseP2PDeltas(address underlying, uint256 amount) external;
    function claimToTreasury(address[] calldata underlyings, uint256[] calldata amounts) external;

    function setPositionsManager(address positionsManager) external;
    function setRewardsManager(address rewardsManager) external;
    function setTreasuryVault(address treasuryVault) external;
    function setDefaultMaxIterations(Types.MaxIterations memory defaultMaxIterations) external;
    function setP2PIndexCursor(address underlying, uint16 p2pIndexCursor) external;
    function setReserveFactor(address underlying, uint16 newReserveFactor) external;

    function setIsP2PDisabled(address underlying, bool isP2PDisabled) external;
    function setIsPaused(address underlying, bool isPaused) external;
    function setIsPausedForAllMarkets(bool isPaused) external;
    function setIsSupplyPaused(address underlying, bool isPaused) external;
    function setIsSupplyCollateralPaused(address underlying, bool isPaused) external;
    function setIsBorrowPaused(address underlying, bool isPaused) external;
    function setIsRepayPaused(address underlying, bool isPaused) external;
    function setIsWithdrawPaused(address underlying, bool isPaused) external;
    function setIsWithdrawCollateralPaused(address underlying, bool isPaused) external;
    function setIsLiquidateBorrowPaused(address underlying, bool isPaused) external;
    function setIsLiquidateCollateralPaused(address underlying, bool isPaused) external;
    function setIsDeprecated(address underlying, bool isDeprecated) external;
}

interface IMorpho is IMorphoGetters, IMorphoSetters {
    function supply(address underlying, uint256 amount, address onBehalf, uint256 maxIterations)
        external
        returns (uint256 supplied);
    function supplyWithPermit(
        address underlying,
        uint256 amount,
        address onBehalf,
        uint256 maxIterations,
        uint256 deadline,
        Types.Signature calldata signature
    ) external returns (uint256 supplied);
    function supplyCollateral(address underlying, uint256 amount, address onBehalf)
        external
        returns (uint256 supplied);
    function supplyCollateralWithPermit(
        address underlying,
        uint256 amount,
        address onBehalf,
        uint256 deadline,
        Types.Signature calldata signature
    ) external returns (uint256 supplied);

    function borrow(address underlying, uint256 amount, address onBehalf, address receiver, uint256 maxIterations)
        external
        returns (uint256 borrowed);

    function repay(address underlying, uint256 amount, address onBehalf) external returns (uint256 repaid);
    function repayWithPermit(
        address underlying,
        uint256 amount,
        address onBehalf,
        uint256 deadline,
        Types.Signature calldata signature
    ) external returns (uint256 repaid);

    function withdraw(address underlying, uint256 amount, address onBehalf, address receiver)
        external
        returns (uint256 withdrawn);
    function withdrawCollateral(address underlying, uint256 amount, address onBehalf, address receiver)
        external
        returns (uint256 withdrawn);

    function approveManager(address manager, bool isAllowed) external;
    function approveManagerWithSig(
        address delegator,
        address manager,
        bool isAllowed,
        uint256 nonce,
        uint256 deadline,
        Types.Signature calldata signature
    ) external;

    function liquidate(address underlyingBorrowed, address underlyingCollateral, address user, uint256 amount)
        external
        returns (uint256 repaid, uint256 seized);
}
