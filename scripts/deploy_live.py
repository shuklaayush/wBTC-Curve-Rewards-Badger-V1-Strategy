from brownie import *
from config import (
    BADGER_DEV_MULTISIG,
    WANT,
    PROTECTED_TOKENS,
    FEES,
    PRICE_FEEDS,
)
from dotmap import DotMap

WMATIC = "0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270"
WETH = "0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619"


def main():
    return deploy()


def deploy():
    """
    Deploys, vault, controller and strats and wires them up for you to test
    """
    deployer = accounts.load("ayush")

    strategist = deployer
    keeper = deployer
    guardian = deployer

    governance = accounts.at(BADGER_DEV_MULTISIG, force=True)

    controller = Controller.deploy({"from": deployer})
    controller.initialize(
        BADGER_DEV_MULTISIG, strategist, keeper, BADGER_DEV_MULTISIG, {"from": deployer}
    )

    sett = SettV3.deploy({"from": deployer})
    sett.initialize(
        WANT,
        controller,
        BADGER_DEV_MULTISIG,
        keeper,
        guardian,
        False,
        "prefix",
        "PREFIX",
        {"from": deployer},
    )

    sett.unpause({"from": governance})
    controller.setVault(WANT, sett, {"from": deployer})

    ## Start up Strategy
    strategy = MyStrategy.deploy({"from": deployer})
    strategy.initialize(
        BADGER_DEV_MULTISIG,
        strategist,
        controller,
        keeper,
        guardian,
        PROTECTED_TOKENS,
        FEES,
        PRICE_FEEDS,
        {"from": deployer},
    )

    ## Wire up Controller to Strart
    ## In testing will pass, but on live it will fail
    controller.approveStrategy(WANT, strategy, {"from": governance})
    controller.setStrategy(WANT, strategy, {"from": deployer})
