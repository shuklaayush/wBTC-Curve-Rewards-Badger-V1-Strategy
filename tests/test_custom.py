import brownie
from brownie import *
from helpers.constants import AddressZero, MaxUint256
from helpers.time import hours


def test_harvest_custom(want, deployer, vault, strategy, reward, wmatic):
    balance = want.balanceOf(deployer)
    wantDecimals = want.decimals()

    want.approve(vault, balance, {"from": deployer})
    vault.deposit(balance, {"from": deployer})
    vault.earn({"from": deployer})

    curvePool = Contract.from_explorer(strategy.CURVE_POOL())
    crvTokenGauge = Contract.from_explorer(strategy.crvTokenGauge())

    # Expected want in strategy based on virtual price
    crvTokenBalance = crvTokenGauge.balanceOf(strategy)
    virtualPrice = curvePool.get_virtual_price()
    expectedWant = int(crvTokenBalance * virtualPrice / 10 ** (36 - wantDecimals))

    assert strategy.balanceOfPool() == expectedWant

    chain.sleep(hours(2))
    chain.mine(500)

    # Update rewards
    crvTokenGauge.claimable_reward_write(
        strategy, strategy.reward(), {"from": deployer}
    )

    #  If we deposited, then we must have some rewards
    assert crvTokenGauge.claimable_reward(strategy, reward) > 0
    assert crvTokenGauge.claimable_reward(strategy, wmatic) > 0

    strategy.harvest({"from": deployer})

    #  Pending rewards should become zero after claiming
    assert crvTokenGauge.claimable_reward(strategy, reward) == 0
    assert crvTokenGauge.claimable_reward(strategy, wmatic) == 0
    # Strategy should have some want after swapping rewards
    assert strategy.balanceOfWant() > 0
    assert strategy.isTendable()
    # Strategy shouldn't have any rewards left
    assert reward.balanceOf(strategy) == 0
    assert wmatic.balanceOf(strategy) == 0

    strategy.tend({"from": deployer})
    # Strategy should re-deposit all extra want
    assert strategy.balanceOfWant() == 0


def test_no_price_feed(want, deployer, vault, strategy, reward, wmatic):
    balance = want.balanceOf(deployer)
    randomUser = accounts[8]

    want.approve(vault, balance, {"from": deployer})
    vault.deposit(balance, {"from": deployer})
    vault.earn({"from": deployer})

    chain.sleep(hours(2))
    chain.mine(500)

    # Remove Chainlink price feed oracle
    with brownie.reverts("onlyGovernanceOrStrategist"):
        strategy.setPriceFeed(strategy.want(), AddressZero, {"from": randomUser})

    strategy.setPriceFeed(strategy.want(), AddressZero, {"from": deployer})

    # Strategy should still harvest rewards and swap them into want
    strategy.harvest({"from": deployer})

    # Strategy should have some want after swapping rewards
    assert strategy.balanceOfWant() > 0
    # Strategy shouldn't have any rewards left
    assert reward.balanceOf(strategy) == 0
    assert wmatic.balanceOf(strategy) == 0
