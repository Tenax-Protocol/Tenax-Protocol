# Contracts

Solidity contracts of Tenax Protocol, built with [Foundry](https://book.getfoundry.sh/).

## Setup

```
git submodule update --init --recursive
```

Dependencies are git submodules pinned to exact releases: OpenZeppelin Contracts v5.7.0, forge-std v1.16.2 and Uniswap `v4-periphery` 1.0.1 (with its `v4-core`).

## Commands

Run from this folder:

```
forge build                        # compile
forge test                         # unit, fuzz and invariant tests
FOUNDRY_PROFILE=ci forge test      # heavier fuzzing, as in CI
forge fmt                          # format
forge coverage                     # coverage report
```

Fork tests run against live Base mainnet contracts (Chainlink feeds, Uniswap v4, WETH) and are skipped unless `BASE_RPC_URL` is set:

```
BASE_RPC_URL=https://mainnet.base.org forge test --match-path "test/fork/*"
```

## Deployment

`script/Deploy.s.sol` deploys and launches the whole protocol in one run. External addresses default to Base mainnet
and can be overridden (`WETH`, `POOL_MANAGER`, `POSITION_MANAGER`, `BTC_USD_FEED`, `ETH_USD_FEED`, `SEQUENCER_FEED`,
`STALENESS`, `SEQUENCER_GRACE`). The launch inputs are required:

| Variable | Meaning |
|---|---|
| `SAFE` | Governance guardian |
| `CREATOR` | Beneficiary of the creator vesting |
| `GENESIS` | Opening time of round 0, a UTC midnight after the launch |
| `INITIAL_THRESHOLDS` | Initial X per asset (BTC, ETH), 1e18 fractions, comma separated |
| `INITIAL_BASE_RATES` | Initial b per asset (BTC, ETH), 1e18 fractions, comma separated |
| `AIRDROP_ROOT` | Merkle root of the airdrop |

Rehearsal on a local fork of Base:

```
anvil --fork-url https://mainnet.base.org --chain-id 31337
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --private-key <anvil key>
```

## Layout

```
src/        contracts, grouped by area (token, escrow, forecast, ...)
test/       unit/, fuzz/, invariant/, fork/
script/     deployment scripts
```

The protocol design is in the [whitepaper](../docs/WHITEPAPER.md), and the build order in the [implementation plan](../docs/IMPLEMENTATION.md).
