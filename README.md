# Tenax Protocol

A self-sustaining, fully on-chain forecasting network on Base, with a token whose value comes from scarcity.

> **Status:** design phase. The whitepaper is a draft under review and no contracts have been written or deployed.

## What it is

Participants lock TENAX to obtain veTENAX and submit probability forecasts on the 24-hour volatility of BTC and ETH. Forecasts are committed before the outcome is known, revealed afterwards, scored with the Brier score and combined into a reputation-weighted aggregate that any contract can read. There is no betting: nobody can lose locked principal, and rewards only go to forecasters whose skill is statistically significant.

The protocol's only revenue is the trading fee of a Uniswap v4 pool whose liquidity it owns and can never withdraw. ETH fees go to forecasters, veTENAX holders and a rule-based treasury that pays keepers and buys back and burns TENAX with the surplus. TENAX fees are burned. Emissions follow a schedule measured in Ethereum L1 blocks and are always delivered locked.

## Design in one table

| Property | How |
|---|---|
| Clean token | Fixed supply of 100M minted once; no owner, mint, pause, blacklist or transfer tax |
| Skill, not luck | Brier score against a moving base rate; rewards require z ≥ 1.64 over at least 20 rounds |
| Scarcity | Locks of up to 2 years, locked emissions, sell-fee burn, early exit burn, buybacks, unused reserve burn |
| Permanent liquidity | Protocol-owned Uniswap v4 position with no withdrawal function |
| Self-sufficiency | Every recurring task is permissionless and paid by the protocol |
| Bounded governance | Immutable contracts; governance adjusts parameters within hard limits and controls no funds |

## Documents

- [Whitepaper](docs/WHITEPAPER.md): the full design, mechanism math, tokenomics, security model and risks
- [Implementation plan](docs/IMPLEMENTATION.md): roadmap, repository layout, deployment sequence, launch checklist and decision log
- [Contributing](CONTRIBUTING.md): branch, commit, pull request and code conventions

## Roadmap

| Phase | Deliverable |
|---|---|
| 0 | Whitepaper, volatility backtest and economic simulation |
| 1 to 7 | Contracts, phase by phase: token, vote escrow, forecasting, emissions, revenue, governance, launch hook |
| 8 to 9 | Security review and a public test season on Base Sepolia |
| 10 to 11 | Front-end and mainnet launch |

Details in the [implementation plan](docs/IMPLEMENTATION.md).

## Stack

Solidity 0.8.26, Foundry, OpenZeppelin Contracts v5, Uniswap v4, Chainlink Data Feeds, Halmos, Slither and Aderyn. Front-end in Vite, React, TypeScript, wagmi and viem.

## License

[MIT](LICENSE)
