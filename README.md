# wBTC Curve Rewards Badger V1 Strategy

![Logo](https://user-images.githubusercontent.com/27727946/124469287-cb083b00-ddb7-11eb-934e-4ed6b25ac24f.png)

**Video**: https://youtu.be/zmuH1VRoTeI

This strategy will deposit wBTC on [Polygon Curve ren pool](https://polygon.curve.fi/ren) and stake the received btcCRV tokens in the Curve Liquidity Gauge to earn interest and CRV/wMATIC rewards.
It will then claim the rewards, swap them into wBTC and compound the amount deposited.

The strategy uses [Chainlink price feeds](https://docs.chain.link/docs/matic-addresses) to determine the current price of CRV and wMATIC tokens for swapping. This prevents front-running attacks.

The swapping is done using [Sushi](https://sushi.com) through the CRV/wMATIC => wETH => wBTC path to ensure sufficient liquidity.

![Chart](https://user-images.githubusercontent.com/27727946/124488648-b5057500-ddcd-11eb-9d10-ab3eb2b08c7a.png)

## Functions
### Deposit
Deposit funds in the Curve Lending Pool and stake LP tokens in the Liquidity Gauge so that we earn interest as well as rewards.

### Withdraw
Unstake some Curve Liquidity Gauge tokens and liquidate the resultant LP tokens into wBTC if the amount of wBTC required is more than the balance of the strategy.

### Harvest
Harvest CRV and wMATIC, and swap them into wBTC through Sushi.

### Tend
If there's any wBTC in the strategy, deposit it in the pool.

## Expected Yield
At the time of writing, the expected yields are:
* Base APY of wBTC ren pool on Curve (2.4%)
* Rewards on the wBTC Deposit:
  * CRV rewards (3.85%)
  * wMATIC rewards (6.18%)

Giving a total expected yield of around 12.43% APY.

![Curve ren pool](https://user-images.githubusercontent.com/27727946/124488874-fc8c0100-ddcd-11eb-99c1-153d94fcaa60.png)


## Installation and Setup

1. Clone the repository.

2. Install [Ganache-CLI](https://github.com/trufflesuite/ganache-cli).

3. Copy the `.env.example` file and rename it to `.env`.

4. Sign up on [Infura](https://infura.io/) and generate an API key. Store it in `WEB3_INFURA_PROJECT_ID` environment variable. Go to Change Plan from Infura dashboard and add Polygon PoS network add-on (it's free as of now).

5. Sign up on [PolygonScan](https://polygonscan.com) and generate an API key. This is required for fetching source code of Polygon mainnet contracts that we will be interacting with. Store the API key in `POLYGONSCAN_TOKEN` environment variable.

6. Install dependencies:
```
## Javascript dependencies
npm i

## Python Dependencies
pip install virtualenv
virtualenv venv
source venv/bin/activate
pip install -r requirements.txt
```

## Notes
A couple of extra tests have been added to [`tests/test_custom.py`](tests/test_custom.py) to test reward claiming and price feeds (or absence of price feeds). A few original tests have been slightly modified to account for peculiarities of Curve contracts. View the diff between the template and this repo using:
```
git diff 60f2fcbfe7f0125e5af3109a4e4ac6b46939f7cd HEAD^
```

Run tests using:

```
brownie test
```

### Profitability while testing locally
The Curve reward contracts are implemented such that Liquidity Gauge boosted rewards are reset every week. While testing locally, this would result in rewards becoming zero after a few days (if you're using Brownie's `chain.sleep(days)`). There's a similar issue with the Base APY rewards on Curve. The Base APY reward is determined by the virtual price of the Curve LP token (see `get_virtual_price()`) which acts as an oracle. Again, this value won't increase just by doing `chain.sleep(...)` locally.

Hence, while testing locally, let's say you deposit 1wBTC into the strategy, harvest/tend daily by using `chain.sleep(days(1))` and then withdraw a few weeks later, then the value that you'll receive might be < 1wBTC. This is because, locally, Base APY is 0 and token rewards become 0 after a few days (also because there's a 0.75% withdrawal fee). In the real world/Mainnet, the strategy should be profitable and if you follow the same steps, your total balance after withdrawal should be > 1wBTC since the above mentioned issues won't be present.

### Removed checks

[This check](https://github.com/Badger-Finance/badger-strategy-mix-v1/blob/main/helpers/StrategyCoreResolver.py#L226-L235) from the original template has been removed since it's not relevant for this strategy. Essentially, this check says withdrawals should first use any free wBTC balance in the vault/strategy and hence, balance of wBTC in the vault/strategy should reduce. This makes sense for strategies where the exchange rate between LP token and want token is known exactly (eg. in AAVE, wBTC-amWBTC is 1:1 pegged) since you know how many LP tokens to liquidate for the required amount of want. Hence, there won't be any extra leftover want remaining in the strategy after withdrawal.

However, since this strategy uses Curve pools for which the exact exchange rate between the btcCRV token and wBTC is unknown and can only be estimated using `get_virtual_price()`*, there's a possibility of liquidating some extra wBTC. This extra wBTC would remain leftover in the strategy after withdrawal.

\* An alternative is to use `calc_withdraw_one_coin(...)` to get the exact amount of wBTC that one would receive after liquidating, but this is susceptible to front-running attacks and hence, not used.

## Contracts

This strategy interacts with the following contracts on Polygon Mainnet:
* Curve ren pool: [0xC2d95EEF97Ec6C17551d45e77B590dc1F9117C67](https://polygonscan.com/address/0xc2d95eef97ec6c17551d45e77b590dc1f9117c67#code)
* Sushi Router: [0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506](https://polygonscan.com/address/0x1b02da8cb0d097eb8d57a175b88c7d8b47997506#code)
* Chainlink CRV-ETH price feed: [0x1CF68C76803c9A415bE301f50E82e44c64B7F1D4](https://polygonscan.com/address/0x1cf68c76803c9a415be301f50e82e44c64b7f1d4#code)
* Chainlink wBTC-ETH price feed: [0xA338e0492B2F944E9F8C0653D3AD1484f2657a37](https://polygonscan.com/address/0xa338e0492b2f944e9f8c0653d3ad1484f2657a37#code)

## Known issues
### KeyError: 'polygon-main-fork'

Make sure you're using [this fork](https://github.com/shuklaayush/brownie) of Brownie as mentioned in `requirements.txt` (at least, until [this PR](https://github.com/eth-brownie/brownie/pull/1135) is merged). This fixes Polygon mainnet forking.

If it still doesn't work, try removing the local Brownie config folder and running again
```rm -r ~/.brownie```
