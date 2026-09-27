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

## Layout

```
src/        contracts, grouped by area (token, escrow, forecast, ...)
test/       unit/, fuzz/, invariant/, fork/, symbolic/
script/     deployment scripts
```

The protocol design is in the [whitepaper](../docs/WHITEPAPER.md), and the build order in the [implementation plan](../docs/IMPLEMENTATION.md).
