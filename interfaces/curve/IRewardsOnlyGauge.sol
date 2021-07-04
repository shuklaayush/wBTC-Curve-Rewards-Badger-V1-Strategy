// SPDX-License-Identifier: MIT

pragma solidity ^0.6.11;

interface IRewardsOnlyGauge {
    function deposit(uint256) external;

    function balanceOf(address) external view returns (uint256);

    function totalSupply() external view returns (uint256);

    function lp_token() external view returns (address);

    function reward_tokens(uint256) external view returns (address);

    function withdraw(uint256) external;

    function claimed_reward(address _addr, address _token)
        external
        view
        returns (uint256);

    function claimable_reward(address _addr, address _token)
        external
        view
        returns (uint256);

    function claim_rewards() external;

    function claim_rewards(address) external;

    function last_claim() external view returns (uint256);
}
