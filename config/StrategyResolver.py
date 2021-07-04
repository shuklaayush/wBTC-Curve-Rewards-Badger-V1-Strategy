from helpers.StrategyCoreResolver import StrategyCoreResolver
from rich.console import Console

console = Console()

class StrategyResolver(StrategyCoreResolver):
    def hook_after_confirm_withdraw(self, before, after, params):
        """
            Specifies extra check for ordinary operation on withdrawal
            Use this to verify that balances in the get_strategy_destinations are properly set
        """
        ## Pool will send funds from crvToken
        ## crvToken sends funds to AAVE WBTC pool
        assert after.balances("want", "amWBTC") < before.balances("want", "amWBTC")

    def hook_after_confirm_deposit(self, before, after, params):
        """
            Specifies extra check for ordinary operation on deposit
            Use this to verify that balances in the get_strategy_destinations are properly set
        """
        ## Nothing specific during a deposit
        assert True

    def hook_after_earn(self, before, after, params):
        """
            Specifies extra check for ordinary operation on earn
            Use this to verify that balances in the get_strategy_destinations are properly set
        """
        ## Pool will send funds to crvToken during earn
        ## crvToken sends funds to AAVE WBTC pool
        assert after.balances("want", "amWBTC") > before.balances("want", "amWBTC")

    def confirm_harvest(self, before, after, tx):
        """
            Verfies that the Harvest produced yield and fees
        """
        console.print("=== Compare Harvest ===")
        self.manager.printCompare(before, after)
        self.confirm_harvest_state(before, after, tx)

        valueGained = after.get("sett.pricePerFullShare") > before.get(
            "sett.pricePerFullShare"
        )

        assert valueGained == True

        # # Strategist should earn if fee is enabled and value was generated
        if before.get("strategy.performanceFeeStrategist") > 0 and valueGained:
            assert after.balances("want", "strategist") > before.balances(
                "want", "strategist"
            )

        # # Strategist should earn if fee is enabled and value was generated
        if before.get("strategy.performanceFeeGovernance") > 0 and valueGained:
            assert after.balances("want", "governanceRewards") > before.balances(
                "want", "governanceRewards"
            )

    def confirm_harvest_state(self, before, after, tx):
        # Strategy want should increase
        assert after.get("strategy.balanceOf") >= before.get("strategy.balanceOf")

        # PPFS should not decrease
        assert after.get("sett.pricePerFullShare") >= before.get("sett.pricePerFullShare")

    def confirm_tend(self, before, after, tx):
        """
        Tend Should;
        - Increase the number of staked tended tokens in the strategy-specific mechanism
        - Reduce the number of tended tokens in the Strategy to zero

        (Strategy Must Implement)
        """
        ## If Tends work, then you can't tend again
        assert after.get("strategy.isTendable") == False

        ## Tendable if we have some balance of want in strat
        assert before.get("strategy.balanceOfWant") > 0
        ## If tend works then balance after will be 0
        assert after.get("strategy.balanceOfWant") == 0

        ## Since tends invest let's ensure balance of pool has grown
        assert after.get("strategy.balanceOfPool") > before.get("strategy.balanceOfPool")

    def get_strategy_destinations(self):
        """
        Track balances for all strategy implementations
        (Strategy Must Implement)
        """
        # E.G
        strategy = self.manager.strategy
        return {
            "crvToken": strategy.crvToken(),
            "curvePool": strategy.CURVE_POOL(),
            "amWBTC": "0x5c2ed810328349100A66B82b78a1791B101C9D61"
        }

        return {}
