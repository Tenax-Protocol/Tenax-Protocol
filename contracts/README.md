# Contracts

Solidity contracts of Tenax Protocol, built with [Foundry](https://book.getfoundry.sh/).

## Setup

```
git submodule update --init --recursive
```

Dependencies are git submodules pinned to exact releases: OpenZeppelin Contracts v5.7.0 and forge-std v1.16.2.

## Commands

Run from this folder:

```
forge build                        # compile
forge test                         # unit, fuzz and invariant tests
FOUNDRY_PROFILE=ci forge test      # heavier fuzzing, as in CI
forge fmt                          # format
forge coverage                     # coverage report
```

Fork tests run against live Chainlink feeds on Base mainnet and are skipped unless `BASE_RPC_URL` is set:

```
BASE_RPC_URL=https://mainnet.base.org forge test --match-path "test/fork/*"
```

## Layout

```
src/        contracts, grouped by area (token, escrow, forecast, ...)
test/       unit/, fuzz/, invariant/, fork/
script/     deployment scripts
```

The protocol design is in the [whitepaper](../docs/WHITEPAPER.md), and the build order in the [implementation plan](../docs/IMPLEMENTATION.md).
