// SPDX-License-Identifier: MIT

pragma solidity ^0.6.11;
pragma experimental ABIEncoderV2;

import "../deps/@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "../deps/@openzeppelin/contracts-upgradeable/token/ERC20/IERC20MetadataUpgradeable.sol";
import "../deps/@openzeppelin/contracts-upgradeable/math/SafeMathUpgradeable.sol";
import "../deps/@openzeppelin/contracts-upgradeable/math/MathUpgradeable.sol";
import "../deps/@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "../deps/@openzeppelin/contracts-upgradeable/token/ERC20/SafeERC20Upgradeable.sol";

import "../interfaces/badger/IController.sol";

import "../interfaces/curve/IStableSwapREN.sol";
import "../interfaces/curve/IRewardsOnlyGauge.sol";

import "../interfaces/chainlink/AggregatorV2V3Interface.sol";
import "../interfaces/sushi/IUniswapV2Router02.sol";

import {BaseStrategy} from "../deps/BaseStrategy.sol";

contract MyStrategy is BaseStrategy {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using AddressUpgradeable for address;
    using SafeMathUpgradeable for uint256;

    // address public want // Inherited from BaseStrategy, the token the strategy wants, swaps into and tries to grow
    address public crvTokenGauge; // Token we provide liquidity with
    address public reward; // Token we farm and swap to want / crvTokenGauge

    uint256 public precisionDiv; // Want might have less than 18 decimals
    mapping(address => address) public priceFeeds; // Chainlink price feeds

    address public constant CURVE_POOL =
        0xC2d95EEF97Ec6C17551d45e77B590dc1F9117C67; // Curve Lending Pool
    address public constant ROUTER = 0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506; // Sushi Router

    address public constant WMATIC_TOKEN =
        0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270;
    address public constant WETH_TOKEN =
        0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619;

    address public constant MATIC_ETH_PRICE =
        0x327e23A4855b6F663a28c5161541d69Af8973302; // MATIC-ETH price feed

    // Max number of tokens given as reward in Curve Liquidity Gauge
    uint256 public constant MAX_REWARDS = 8;

    // Slippage tolerances (in basis points)
    uint256 public constant CURVE_SLIPPAGE_TOLERANCE = 100; // 1% for Curve LP token using virtual price
    uint256 public constant SWAP_SLIPPAGE_TOLERANCE = 500; // 5% for swaps using Chainlink price feeds

    function initialize(
        address _governance,
        address _strategist,
        address _controller,
        address _keeper,
        address _guardian,
        address[3] memory _wantConfig,
        uint256[3] memory _feeConfig,
        address[2] memory _priceFeeds
    ) public initializer {
        __BaseStrategy_init(
            _governance,
            _strategist,
            _controller,
            _keeper,
            _guardian
        );

        /// @dev Add config here
        want = _wantConfig[0]; // wBTC
        crvTokenGauge = _wantConfig[1]; // btcCRV-gauge
        reward = _wantConfig[2]; // CRV

        performanceFeeGovernance = _feeConfig[0];
        performanceFeeStrategist = _feeConfig[1];
        withdrawalFee = _feeConfig[2];

        // @dev Add price feeds here
        priceFeeds[want] = _priceFeeds[0];
        priceFeeds[reward] = _priceFeeds[1];
        priceFeeds[WMATIC_TOKEN] = MATIC_ETH_PRICE;

        // @dev Store precision divisor to account for fewer than 18 decimals
        uint256 wantDecimals = IERC20MetadataUpgradeable(want).decimals();
        precisionDiv = 10**(18 - wantDecimals);

        /// @dev do one off approvals here
        // Curve Lending Pool can transfer want tokens
        IERC20Upgradeable(want).safeApprove(CURVE_POOL, type(uint256).max);
        // Curve Liqidity Gauge can transfer Curve LP tokens
        address crvToken = IRewardsOnlyGauge(crvTokenGauge).lp_token();
        IERC20Upgradeable(crvToken).safeApprove(
            crvTokenGauge,
            type(uint256).max
        );
    }

    /// ===== View Functions =====

    // @dev Specify the name of the strategy
    function getName() external pure override returns (string memory) {
        return "wBTC-Curve-Rewards";
    }

    // @dev Specify the version of the Strategy, for upgrades
    function version() external pure returns (string memory) {
        return "1.0";
    }

    /// @dev Balance of want currently held in strategy positions
    function balanceOfPool() public view override returns (uint256) {
        return _crvTokenToWant(_balanceOfcrvTokenGauge()); // Estimate using virtual price of crvToken (LP token)
    }

    /// @dev Returns true if this strategy requires tending
    function isTendable() public view override returns (bool) {
        return balanceOfWant() > 0; // Tendable if contract has some want tokens
    }

    // @dev These are the tokens that cannot be moved except by the vault
    function getProtectedTokens()
        public
        view
        override
        returns (address[] memory)
    {
        address[] memory protectedTokens = new address[](4);
        protectedTokens[0] = want;
        protectedTokens[1] = crvTokenGauge;
        protectedTokens[2] = reward;
        protectedTokens[3] = WMATIC_TOKEN;
        return protectedTokens;
    }

    /// ===== Permissioned Actions: Governance =====
    /// @notice Delete if you don't need!
    function setKeepReward(uint256 _setKeepReward) external {
        _onlyGovernance();
    }

    /// ===== Permissioned Actions: Governance or Strategist =====
    /// @dev Modify/add Chainlink pricefeed
    function setPriceFeed(address _token, address _feed) external {
        _onlyGovernanceOrStrategist();
        priceFeeds[_token] = _feed;
    }

    /// ===== Internal Core Implementations =====

    /// @dev security check to avoid moving tokens that would cause a rugpull, edit based on strat
    function _onlyNotProtectedTokens(address _asset) internal override {
        address[] memory protectedTokens = getProtectedTokens();

        for (uint256 x = 0; x < protectedTokens.length; x++) {
            require(
                address(protectedTokens[x]) != _asset,
                "Asset is protected"
            );
        }
    }

    /// @dev invest the amount of want
    /// @notice When this function is called, the controller has already sent want to this
    /// @notice Just get the current balance and then invest accordingly
    function _deposit(uint256 _amount) internal override {
        // Expected crvToken (LP tokens) based on virtual price of LP tokens
        uint256 expectedcrvToken = _wantTocrvToken(_amount);
        // Deposit want tokens
        uint256 depositedAmount =
            IStableSwapREN(CURVE_POOL).add_liquidity(
                [_amount, 0],
                _calcMinAmountFromSlippage(
                    expectedcrvToken,
                    CURVE_SLIPPAGE_TOLERANCE
                ),
                true
            );
        // Stake crvToken on Liquididty Gauge to earn boosted rewards
        IRewardsOnlyGauge(crvTokenGauge).deposit(depositedAmount);
    }

    /// @dev utility function to withdraw everything for migration
    function _withdrawAll() internal override {
        // Balance of crvToken in contract
        uint256 amount = _balanceOfcrvTokenGauge();
        // Unstake crvToken from Liquidity Gauge
        IRewardsOnlyGauge(crvTokenGauge).withdraw(amount);
        // Expected want tokens based on virtual price of LP tokens
        uint256 expectedWant = _crvTokenToWant(amount);
        // Withdraw want tokens
        IStableSwapREN(CURVE_POOL).remove_liquidity_one_coin(
            amount,
            0,
            _calcMinAmountFromSlippage(expectedWant, CURVE_SLIPPAGE_TOLERANCE),
            true
        );
    }

    /// @dev liquidate crvTokenGauge to get specified amount of want
    function _liquidate(uint256 _amount) internal returns (uint256) {
        uint256 wantBalanceBefore = balanceOfWant();

        // Amount of crvToken required to get _amount of want (based on virtual price)
        uint256 amountcrvTokenGauge = _wantTocrvToken(_amount);

        // Cap amount to maximum available in contract
        if (amountcrvTokenGauge > _balanceOfcrvTokenGauge()) {
            amountcrvTokenGauge = _balanceOfcrvTokenGauge();
            _amount = _crvTokenToWant(amountcrvTokenGauge);
        }

        // Unstake crvToken from Liquidity Gauge
        IRewardsOnlyGauge(crvTokenGauge).withdraw(amountcrvTokenGauge);
        // Withdraw want tokens
        IStableSwapREN(CURVE_POOL).remove_liquidity_one_coin(
            amountcrvTokenGauge,
            0,
            _calcMinAmountFromSlippage(_amount, CURVE_SLIPPAGE_TOLERANCE),
            true
        );

        uint256 diff = balanceOfWant().sub(wantBalanceBefore);

        return MathUpgradeable.min(_amount, diff);
    }

    /// @dev withdraw the specified amount of want, liquidate from crvTokenGauge to want, paying off any necessary debt for the conversion
    function _withdrawSome(uint256 _amount)
        internal
        override
        returns (uint256)
    {
        uint256 liquidatedAmount;
        if (balanceOfWant() < _amount) {
            // Liquidate crvTokens if there's not enough want in contract
            liquidatedAmount = _liquidate(_amount.sub(balanceOfWant()));
        }
        return
            MathUpgradeable.min(_amount, liquidatedAmount.add(balanceOfWant()));
    }

    /// @dev Harvest from strategy mechanics, realizing increase in underlying position
    function harvest() external whenNotPaused returns (uint256 harvested) {
        _onlyAuthorizedActors();

        uint256 _before = balanceOfWant();

        // Claim rewards from Liquidity Gauge
        IRewardsOnlyGauge(crvTokenGauge).claim_rewards();

        // Iterate over all rewards and swap them into want
        for (uint256 i = 0; i < MAX_REWARDS; i++) {
            address tokenAddress =
                IRewardsOnlyGauge(crvTokenGauge).reward_tokens(i); // Reward token address
            if (tokenAddress == address(0)) {
                // No more rewards left
                break;
            }

            uint256 rewardAmount =
                IERC20Upgradeable(tokenAddress).balanceOf(address(this));
            if (rewardAmount == 0) {
                // Skip since no tokens are available
                continue;
            }

            // Approve Sushi to spend rewards if not already done so
            if (
                IERC20Upgradeable(tokenAddress).allowance(
                    address(this),
                    ROUTER
                ) == 0
            ) {
                IERC20Upgradeable(tokenAddress).safeApprove(
                    ROUTER,
                    type(uint256).max
                );
            }

            // Swap reward token => WETH => want on Sushi
            address[] memory path = new address[](3);
            path[0] = tokenAddress;
            path[1] = WETH_TOKEN;
            path[2] = want;

            uint256 minExpectedWant; // Minimum expected want after swap
            // Calculate minimum expected want using price feed and slippage factor. If no price feed is
            // present for this token, expect to get non-zero amount after swap and hope for the best.
            if (
                priceFeeds[tokenAddress] != address(0) &&
                priceFeeds[want] != address(0)
            ) {
                uint256 expectedWant =
                    _tokenToWantFromPriceFeed(rewardAmount, tokenAddress);
                minExpectedWant = _calcMinAmountFromSlippage(
                    expectedWant,
                    SWAP_SLIPPAGE_TOLERANCE
                );
            } else {
                // WARNING: SUSCEPTIBLE TO FRONTRUNNING
                minExpectedWant = 0;
            }
            // Swap reward => WETH => want
            IUniswapV2Router02(ROUTER).swapExactTokensForTokens(
                rewardAmount,
                minExpectedWant,
                path,
                address(this),
                now
            );
        }

        uint256 earned = balanceOfWant().sub(_before); // Want earned

        /// @notice Keep this in so you get paid!
        (uint256 governancePerformanceFee, uint256 strategistPerformanceFee) =
            _processPerformanceFees(earned);

        /// @dev Harvest event that every strategy MUST have, see BaseStrategy
        emit Harvest(earned, block.number);

        return earned;
    }

    /// @dev Compound by depositing any remaining want in contract
    function tend() external whenNotPaused {
        _onlyAuthorizedActors();

        if (balanceOfWant() > 0) {
            _deposit(balanceOfWant());
        }
    }

    /// ===== Internal Helper Functions =====

    /// @dev used to manage the governance and strategist fee, make sure to use it to get paid!
    function _processPerformanceFees(uint256 _amount)
        internal
        returns (
            uint256 governancePerformanceFee,
            uint256 strategistPerformanceFee
        )
    {
        governancePerformanceFee = _processFee(
            want,
            _amount,
            performanceFeeGovernance,
            IController(controller).rewards()
        );

        strategistPerformanceFee = _processFee(
            want,
            _amount,
            performanceFeeStrategist,
            strategist
        );
    }

    /// @dev Calculate minimum output amount expected based on given slippage
    function _calcMinAmountFromSlippage(uint256 _amount, uint256 _slippage)
        internal
        view
        returns (uint256)
    {
        return _amount.mul(MAX_FEE.sub(_slippage)).div(MAX_FEE);
    }

    /// @dev Get the balance of crvTokenGauge in strategy
    function _balanceOfcrvTokenGauge() internal view returns (uint256) {
        return IERC20Upgradeable(crvTokenGauge).balanceOf(address(this));
    }

    /// @dev Get the virtual price of crvToken in want
    function _virtualPrice() internal view returns (uint256) {
        return IStableSwapREN(CURVE_POOL).get_virtual_price();
    }

    /// @dev Convert _amount of crvToken into want using virtual price
    function _crvTokenToWant(uint256 _amount) internal view returns (uint256) {
        return _amount.mul(_virtualPrice()).div(1e18).div(precisionDiv);
    }

    /// @dev Convert _amount of want into crvToken using virtual price
    function _wantTocrvToken(uint256 _amount) internal view returns (uint256) {
        return _amount.mul(1e18).mul(precisionDiv).div(_virtualPrice());
    }

    /// @dev Chainlink price feed functions
    /// TODO: Maybe add a check to see if Chainlink price feed data is recently
    ///       updated and is not more than a few hours old (i.e. stale)?

    /// @dev Get price of want token in ETH from Chainlink price feed
    function _ethPerWant() internal view returns (uint256) {
        int256 ethPerWant =
            AggregatorV2V3Interface(priceFeeds[want]).latestAnswer();
        return uint256(ethPerWant);
    }

    /// @dev Convert _amount of token into want using Chainlink price feed
    function _tokenToWantFromPriceFeed(uint256 _amount, address _tokenAddress)
        internal
        view
        returns (uint256)
    {
        int256 ethPerToken =
            AggregatorV2V3Interface(priceFeeds[_tokenAddress]).latestAnswer();
        return
            _amount.mul(uint256(ethPerToken)).div(_ethPerWant()).div(
                precisionDiv
            );
    }
}
