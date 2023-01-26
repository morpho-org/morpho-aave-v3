// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.5.0;

interface IRewardsManager {
    function pool() external view returns (address);
    function morpho() external view returns (address);
    function rewardsController() external view returns (address);

    function getAllUserRewards(address[] calldata assets, address user)
        external
        view
        returns (address[] memory rewardsList, uint256[] memory unclaimedAmounts);
    function getUserRewards(address[] calldata assets, address user, address reward) external view returns (uint256);
    function getUserAccruedRewards(address[] calldata assets, address user, address reward)
        external
        view
        returns (uint256 totalAccrued);
    function getUserAssetIndex(address user, address asset, address reward) external view returns (uint256);

    function claimRewards(address[] calldata assets, address user)
        external
        returns (address[] memory rewardsList, uint256[] memory claimedAmounts);
    function updateUserRewards(address user, address asset, uint256 userBalance) external;
}
