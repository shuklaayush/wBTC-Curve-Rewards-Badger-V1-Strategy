// SPDX-License-Identifier: MIT

pragma solidity ^0.6.11;

interface IStableSwapREN {
    function get_virtual_price() external view returns (uint256);

    function add_liquidity(
        uint256[2] calldata _amounts,
        uint256 _min_mint_amount,
        bool _use_underlying
    ) external returns (uint256);

    function remove_liquidity_imbalance(
        uint256[2] calldata _amounts,
        uint256 _max_burn_amount,
        bool _use_underlying
    ) external returns (uint256[2] memory amounts);

    function remove_liquidity(
        uint256 _amount,
        uint256[2] calldata _min_amounts,
        bool _use_underlying
    ) external returns (uint256[2] memory amounts);

    function remove_liquidity_one_coin(
        uint256 _token_amount,
        int128 i,
        uint256 _min_amount,
        bool _use_underlying
    ) external returns (uint256);

    function calc_withdraw_one_coin(uint256 _token_amount, int128 i)
        external
        view
        returns (uint256);

    function exchange(
        int128 i,
        int128 j,
        uint256 dx,
        uint256 min_dy
    ) external returns (uint256);

    function exchange_underlying(
        int128 i,
        int128 j,
        uint256 dx,
        uint256 min_dy
    ) external returns (uint256);

    function balances(uint256) external view returns (uint256);

    function get_dy(
        int128 i,
        int128 j,
        uint256 dx
    ) external view returns (uint256);
}
