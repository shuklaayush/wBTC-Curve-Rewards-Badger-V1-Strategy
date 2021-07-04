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

import "../interfaces/sushi/IUniswapV2Router02.sol";

import {BaseStrategy} from "../deps/BaseStrategy.sol";

contract MyStrategy is BaseStrategy {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using AddressUpgradeable for address;
    using SafeMathUpgradeable for uint256;

    // address public want // Inherited from BaseStrategy, the token the strategy wants, swaps into and tries to grow
    address public crvToken; // Token we provide liquidity with
    address public reward; // Token we farm and swap to want / crvToken

    uint256 public precisionDiv;

    address public constant CURVE_POOL =
        0xC2d95EEF97Ec6C17551d45e77B590dc1F9117C67;
    address public constant ROUTER = 0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506; // SushiSwap Router

    address public constant btcCRV_TOKEN =
        0xf8a57c1d3b9629b77b6726a042ca48990A84Fb49;
    address public constant WETH_TOKEN =
        0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619;

    // Max number of tokens given as reward in curve pool
    uint256 public constant MAX_REWARDS = 8;

    uint256 public constant MAX_BPS = 10000;
    uint256 public constant SLIPPAGE_TOLERANCE = 100;

    function initialize(
        address _governance,
        address _strategist,
        address _controller,
        address _keeper,
        address _guardian,
        address[3] memory _wantConfig,
        uint256[3] memory _feeConfig
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
        crvToken = _wantConfig[1]; // btcCRV-gauge
        reward = _wantConfig[2]; // CRV

        performanceFeeGovernance = _feeConfig[0];
        performanceFeeStrategist = _feeConfig[1];
        withdrawalFee = _feeConfig[2];

        uint256 wantDecimals = IERC20MetadataUpgradeable(want).decimals();
        precisionDiv = 10**(18 - wantDecimals);

        /// @dev do one off approvals here
        IERC20Upgradeable(want).safeApprove(CURVE_POOL, type(uint256).max);
        IERC20Upgradeable(btcCRV_TOKEN).safeApprove(
            crvToken,
            type(uint256).max
        );
    }

    /// ===== View Functions =====

    // @dev Specify the name of the strategy
    function getName() external pure override returns (string memory) {
        return "wBTC-CRV-Rewards";
    }

    // @dev Specify the version of the Strategy, for upgrades
    function version() external pure returns (string memory) {
        return "1.0";
    }

    /// @dev Balance of want currently held in strategy positions
    function balanceOfPool() public view override returns (uint256) {
        return _crvTokenToWant(_balanceOfCrvToken());
    }

    /// @dev Returns true if this strategy requires tending
    function isTendable() public view override returns (bool) {
        return balanceOfWant() > 0;
    }

    // @dev These are the tokens that cannot be moved except by the vault
    function getProtectedTokens()
        public
        view
        override
        returns (address[] memory)
    {
        address[] memory protectedTokens = new address[](3);
        protectedTokens[0] = want;
        protectedTokens[1] = crvToken;
        protectedTokens[2] = reward;
        return protectedTokens;
    }

    /// ===== Permissioned Actions: Governance =====
    /// @notice Delete if you don't need!
    function setKeepReward(uint256 _setKeepReward) external {
        _onlyGovernance();
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
        // Deposit wBTC
        // crvToken and wBTC are not pegged 1:1 (exchange rate changes like cTokens)
        uint256 expectedCrvToken = _wantToCrvToken(_amount);
        uint256 depositedAmount =
            IStableSwapREN(CURVE_POOL).add_liquidity(
                [_amount, 0],
                expectedCrvToken.mul(MAX_BPS.sub(SLIPPAGE_TOLERANCE)).div(
                    MAX_BPS
                ),
                true
            );
        // Stake btcCRV LP in Curve
        IRewardsOnlyGauge(crvToken).deposit(depositedAmount);
    }

    /// @dev utility function to withdraw everything for migration
    function _withdrawAll() internal override {
        uint256 amount = _balanceOfCrvToken();
        // Unstake
        IRewardsOnlyGauge(crvToken).withdraw(amount);
        // Withdraw
        uint256 expectedWant = _crvTokenToWant(amount);
        IStableSwapREN(CURVE_POOL).remove_liquidity_one_coin(
            amount,
            0,
            expectedWant.mul(MAX_BPS.sub(SLIPPAGE_TOLERANCE)).div(MAX_BPS),
            true
        );
    }

    /// @dev liquidate crvToken to get specified amount of want
    function _liquidate(uint256 _amount) internal returns (uint256) {
        uint256 wantBalanceBefore = balanceOfWant();

        // crvTokens required based on virtual price
        uint256 amountCrvToken = _wantToCrvToken(_amount);

        if (amountCrvToken > _balanceOfCrvToken()) {
            amountCrvToken = _balanceOfCrvToken();
            _amount = _crvTokenToWant(amountCrvToken);
        }

        // Unstake
        IRewardsOnlyGauge(crvToken).withdraw(amountCrvToken);
        // Withdraw
        IStableSwapREN(CURVE_POOL).remove_liquidity_one_coin(
            amountCrvToken,
            0,
            _amount.mul(MAX_BPS.sub(SLIPPAGE_TOLERANCE)).div(MAX_BPS),
            true
        );

        uint256 diff = balanceOfWant().sub(wantBalanceBefore);

        return MathUpgradeable.min(_amount, diff);
    }

    /// @dev withdraw the specified amount of want, liquidate from crvToken to want, paying off any necessary debt for the conversion
    function _withdrawSome(uint256 _amount)
        internal
        override
        returns (uint256)
    {
        uint256 liquidatedAmount;
        if (balanceOfWant() < _amount) {
            liquidatedAmount = _liquidate(_amount.sub(balanceOfWant()));
        }
        return
            MathUpgradeable.min(_amount, liquidatedAmount.add(balanceOfWant()));
    }

    /// @dev Harvest from strategy mechanics, realizing increase in underlying position
    function harvest() external whenNotPaused returns (uint256 harvested) {
        _onlyAuthorizedActors();

        uint256 _before = balanceOfWant();

        // Figure out and claim our rewards
        IRewardsOnlyGauge(crvToken).claim_rewards();

        for (uint256 i = 0; i < MAX_REWARDS; i++) {
            address tokenAddress = IRewardsOnlyGauge(crvToken).reward_tokens(i);
            if (tokenAddress == address(0)) {
                break;
            }

            uint256 rewardsAmount =
                IERC20Upgradeable(tokenAddress).balanceOf(address(this));
            if (rewardsAmount == 0) {
                continue;
            }

            /// @dev Allowance for SushiSwap
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

            // Swap token to WETH to WBTC on Sushi
            address[] memory path = new address[](3);
            path[0] = tokenAddress;
            path[1] = WETH_TOKEN;
            path[2] = want;
            IUniswapV2Router02(ROUTER).swapExactTokensForTokens(
                rewardsAmount,
                uint256(0),
                path,
                address(this),
                now
            );
        }

        uint256 earned = balanceOfWant().sub(_before);

        /// @notice Keep this in so you get paid!
        (uint256 governancePerformanceFee, uint256 strategistPerformanceFee) =
            _processPerformanceFees(earned);

        /// @dev Harvest event that every strategy MUST have, see BaseStrategy
        emit Harvest(earned, block.number);

        return earned;
    }

    /// @dev Rebalance, Compound or Pay off debt here
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

    /// @notice Get the balance of crvToken in strategy
    function _balanceOfCrvToken() internal view returns (uint256) {
        return IERC20Upgradeable(crvToken).balanceOf(address(this));
    }

    /// @dev Get the virtual price of crvToken in WBTC
    function _virtualPrice() internal view returns (uint256) {
        return IStableSwapREN(CURVE_POOL).get_virtual_price();
    }

    /// @dev Converts balance of crvToken in WBTC
    function _crvTokenToWant(uint256 _tokens) internal view returns (uint256) {
        if (_tokens == 0) {
            return 0;
        }

        return _tokens.mul(_virtualPrice()).div(1e18).div(precisionDiv);
    }

    /// @dev Converts balance of crvToken in WBTC
    function _wantToCrvToken(uint256 _tokens) internal view returns (uint256) {
        if (_tokens == 0) {
            return 0;
        }

        return _tokens.mul(1e18).mul(precisionDiv).div(_virtualPrice());
    }
}
