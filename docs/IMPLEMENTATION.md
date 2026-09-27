# Implementation Plan

Engineering plan for building and launching Tenax Protocol. The protocol design is described in the [whitepaper](WHITEPAPER.md); branch, commit and code conventions are in [CONTRIBUTING.md](../CONTRIBUTING.md).

> **Status:** draft, under review.

---

## 1. Roadmap

Each phase is developed on its own branch and is only complete when its tests pass.

| Phase | Deliverable | Completion criteria |
|---|---|---|
| 0 | Whitepaper + simulations | Whitepaper reviewed and closed; simulation published and initial price range set |
| 1 | TenaxToken + ERC-3009 | Unit and fuzz tests passing |
| 2 | VotingEscrow | Slope/bias invariants, differential tests and Halmos; early exit (`withdrawEarly`, `grantedAmount`, penalty burn) |
| 3 | OracleAdapter + ForecastRegistry + BrierMath | Fork tests; threshold and base rate updates; scoring, significance and aggregate invariants |
| 4 | EmissionSchedule + SeasonRewards + MerkleAirdrop + VestingWallet | Emission ≤ schedule; nothing is liquid |
| 5 | LiquidityVault + RevenueRouter + FeeDistributor + Treasury | End-to-end fee flow on a fork; buyback, reserve allowance and burns |
| 6 | TenaxGovernor + Timelock | Full proposal flow |
| 7 | LaunchFeeHook + launch script | Fork test with the real PoolManager; TWAP guard |
| 8 | Security review | `SECURITY.md` |
| 9 | Test season on Base Sepolia | Launch checklist (section 5) on testnet |
| 10 | Front-end | Working dApp on testnet |
| 11 | Mainnet launch | Launch checklist (section 5) |
| 12 | Announcement | Technical thread on X + LinkedIn post |

---

## 2. Economic simulation (phase 0)

Model in `simulation/` with low, medium and high volume scenarios, covering ETH revenue per holder and per forecaster, cumulative burn, liquid supply and pool depth.

**Required output:** the price range of the single-sided launch position (initial price and upper bound).

---

## 3. Repository layout

```
/
├── contracts/                  # Foundry
│   ├── src/
│   │   ├── token/TenaxToken.sol
│   │   ├── token/ERC3009.sol
│   │   ├── escrow/VotingEscrow.sol
│   │   ├── forecast/ForecastRegistry.sol
│   │   ├── forecast/OracleAdapter.sol
│   │   ├── forecast/BrierMath.sol
│   │   ├── liquidity/LiquidityVault.sol
│   │   ├── revenue/RevenueRouter.sol
│   │   ├── revenue/FeeDistributor.sol
│   │   ├── revenue/Treasury.sol
│   │   ├── distribution/SeasonRewards.sol
│   │   ├── distribution/EmissionSchedule.sol
│   │   ├── distribution/MerkleAirdrop.sol
│   │   ├── governance/TenaxGovernor.sol
│   │   └── hooks/LaunchFeeHook.sol
│   ├── test/ (unit/ fuzz/ invariant/ fork/ symbolic/)
│   ├── script/ (Deploy.s.sol, LaunchPool.s.sol)
│   └── foundry.toml
├── simulation/                 # economic and scoring model
├── frontend/                   # Vite + React + TypeScript
├── docs/ (WHITEPAPER.md, IMPLEMENTATION.md, ARCHITECTURE.md, SECURITY.md, TOKENOMICS.md)
└── README.md
```

**Toolchain:** Solidity 0.8.26 (`evm_version = cancun`), OpenZeppelin Contracts v5.x, Foundry, Halmos, Slither, Aderyn. The hook address salt is mined with `HookMiner`. Local tests simulate the OP Stack predeploys with `vm.etch` and `vm.mockCall`.

---

## 4. Deployment

1. Safe (existing) and `TimelockController`.
2. `TenaxToken`, minting the supply to the script address.
3. `VotingEscrow`, `OracleAdapter`, `ForecastRegistry`, `FeeDistributor`, `SeasonRewards`, `RevenueRouter`, `Treasury`, `LiquidityVault`, `MerkleAirdrop` (closed), `VestingWallet`, `TenaxGovernor`.
4. Authorize `SeasonRewards` and `MerkleAirdrop` on `createLockFor`.
5. Transfer allocations according to the tokenomics.
6. Configure Timelock roles and renounce the deployer's admin role.
7. Mine the salt and deploy `LaunchFeeHook`.
8. Create the pool and the single-sided TENAX position in a single transaction, with the position NFT minted straight to the `LiquidityVault`.
9. Open the airdrop claim.
10. Verify all contracts on Basescan.

**Environments:** Anvil → Base Sepolia → Base mainnet.
**Keys:** `cast wallet` (keystore) or a hardware wallet; never a plaintext key for mainnet.

---

## 5. Launch checklist

- [ ] Tests passing, ≥ 95% coverage on core contracts
- [ ] Slither/Aderyn with no open critical findings; Halmos properties proven
- [ ] `SECURITY.md` and `TOKENOMICS.md` published
- [ ] Full test season on Base Sepolia (forecasts, reveals, scoring, aggregate, fee collection, distribution, keepers, governance)
- [ ] Airdrop Merkle tree generated from the test season and published
- [ ] Contracts verified on mainnet
- [ ] Pool created with the hook and the position in the `LiquidityVault` in the same transaction
- [ ] Airdrop opened only after the pool
- [ ] README with addresses, allocations, wallets and the creator's lock and sell policy
- [ ] Scanner checks (GoPlus, Token Sniffer)
- [ ] Front-end published (static hosting or IPFS)
- [ ] Posts on X and LinkedIn focused on the engineering, never on price

---

## 6. Front-end (dApp)

**Stack:** Vite + React + TypeScript + wagmi + viem, static build with no server, deployable to IPFS. Published and linked from **brmz.dev**.

- Connect wallet (Base)
- **Lock:** lock TENAX, increase amount or duration, view veBalance and the decay curve; early exit of the voluntary portion with a penalty preview
- **Forecast:** open rounds with their threshold $X$ and base rate $b$, submit a probability (commit with a signature-derived salt), reminders and a reveal button
- **Leaderboard:** skill and significance ($z$) per season, eligibility status and history per participant
- **Aggregate:** public history of the aggregate forecast vs. outcomes, and the aggregate's Brier score
- **Revenue:** claimable ETH (holders and forecasters) and locked TENAX rewards
- **Keepers:** pending tasks and the reward for each
- **Token dashboard:** supply, burned (by source), locked, liquid supply, fees collected
- **Treasury:** ETH reserve, buybacks, current season allowance, top-up and amount to be burned
- **Governance** and **Airdrop** (with lock duration choice and the corresponding fraction)

---

## 7. Decision log

| # | Topic | Decision |
|---|---|---|
| 1 | Name and ticker | Tenax Protocol (`TENAX`); ve = `veTENAX` |
| 2 | Lock | Linear decay (Curve model), 1 week to 2 years |
| 3 | Delegation | No delegation in v1 |
| 4 | Upgrades | Immutable contracts, no proxies |
| 5 | v1 questions | Volatility of BTC/USD and ETH/USD: will the absolute 24 h move exceed $X$? |
| 6 | Round windows | 30 min submission / 24 h horizon (fixed) / 48 h reveal; one round per asset per day |
| 7 | `minVe` and `K` | 1,000 veTENAX; K = 4 (weight from 1× to 2×); EMA α = 1/32; threshold and base rate EMAs with β = γ = 1/30 |
| 8 | Season rewards | Linear in accumulated skill; eligible with ≥ 20 rounds and z ≥ 1.64 |
| 9 | Revenue split | 40 / 40 / 20 |
| 10 | Pool fee | 0.3% permanent (competitive with other pools); launch fee from 20% → 0.3% over 300 blocks |
| 11 | Keepers | `collectFees` every 24 h; gas refund × 1.5 with a cap |
| 12 | Airdrop | Test season participants who pass the significance test; 26/52/104-week lock receives 50/75/100% |
| 13 | Creator policy | ≥ 50% of each release locked + public monthly sell cap |
| 14 | Governance | 1 d delay, 5 d voting, 10% quorum, 100k veTENAX threshold, 2 d Timelock; parameters only, no control over funds |
| 15 | Emission | 35%, 2,628,000-block epochs, −50/−40/−30/−20 and a −15% floor |
| 16 | Emission clock | Ethereum L1 blocks via `L1Block` |
| 17 | Payout currency | WETH by default + optional `claimAsETH` |
| 18 | Front-end | Vite + React + TypeScript + wagmi + viem |
| 19 | Advanced verification | Halmos |
| 20 | Initial price range (FDV in ETH) | **Open:** set by the phase 0 simulation |
| 21 | Early exit | Voluntary portion only; penalty = min(time left / 104 weeks, 50%), burned; emissions and airdrop cannot exit early |
| 22 | Skill reference | Skill measured against the base rate: S = b(1 − b) − Brier |
| 23 | Value thesis | Value through scarcity: locked supply, locked emissions, sell burn, early exit burn, buybacks and unused reserve burn |
| 24 | Treasury | Rule-based `Treasury` contract with no withdrawal function; 20% of ETH revenue |
| 25 | Treasury ETH | Keeper reserve of 90 days of maximum budget; all surplus buys back TENAX and burns it (at most once per 24 h, capped, 2% TWAP guard) |
| 26 | Treasury TENAX | 20M reserve released at 1/60 per season (~5 years); pays locked keeper rewards and a season top-up that shrinks as ETH revenue reaches $T_{ETH}$; unused allowance burned |
| 27 | Airdrop leftovers | Unreceived fractions and unclaimed balances are burned |
