## Ideally, they have one file with the settings for the strat and deployment
## This file would allow them to configure so they can test, deploy and interact with the strategy

BADGER_DEV_MULTISIG = "0xb65cef03b9b89f99517643226d76e286ee999e77"

WANT = "0x1bfd67037b42cf73acf2047067bd4f2c47d9bfd6" ## wBTC
LP_COMPONENT = "0xffbacce0cc7c19d46132f1258fc16cf6871d153c" ## btcCRV-gauge
REWARD_TOKEN = "0x172370d5cd63279efa6d502dab29171933a610af" ## CRV

PROTECTED_TOKENS = [WANT, LP_COMPONENT, REWARD_TOKEN]
## Fees in Basis Points
DEFAULT_GOV_PERFORMANCE_FEE = 1000
DEFAULT_PERFORMANCE_FEE = 1000
DEFAULT_WITHDRAWAL_FEE = 75

FEES = [DEFAULT_GOV_PERFORMANCE_FEE, DEFAULT_PERFORMANCE_FEE, DEFAULT_WITHDRAWAL_FEE]