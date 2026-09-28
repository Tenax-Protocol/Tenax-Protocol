# Implementation Plan

Engineering plan for building and launching Tenax Protocol. The protocol design is described in the [whitepaper](WHITEPAPER.md); branch, commit and code conventions are in [CONTRIBUTING.md](../CONTRIBUTING.md).

> **Status:** draft, under review.

---

## 1. Roadmap

Each phase is developed on its own branch and is only complete when its tests pass.

| Phase | Deliverable | Completion criteria |
|---|---|---|
| 0 | Whitepaper + simulations | Volatility backtest and economic simulation done; launch price range and $T_{ETH}$ set; whitepaper reviewed and closed |
| 1 | TenaxToken + ERC-3009 | Unit and fuzz tests passing |
| 2 | VotingEscrow | Slope/bias invariants and differential tests; early exit (`withdrawEarly`, `grantedAmount`, penalty burn) |
| 3 | OracleAdapter + ForecastRegistry + BrierMath | Fork tests; threshold and base rate updates; scoring, significance and aggregate invariants |
| 4 | EmissionSchedule + SeasonRewards + MerkleAirdrop + CreatorVesting | Emission ≤ schedule; nothing is liquid |
| 5a | RevenueRouter + FeeDistributor + Treasury | Revenue split, weekly fee distribution, keeper payments, reserve allowance, top-up and burns |
| 5b | LiquidityVault + buyback | End-to-end fee flow on a fork; buyback and burn with the TWAP guard |
| 6 | TenaxGovernor + Timelock | Full proposal flow |
| 7 | LaunchFeeHook + launch script | Fork test with the real PoolManager; TWAP guard |
| 8 | Security review | `SECURITY.md` |
| 9 | Test season on Base Sepolia | Launch checklist (section 5) on testnet |
| 10 | Front-end | Working dApp on testnet |
| 11 | Mainnet launch | Launch checklist (section 5) |
| 12 | Announcement | Technical thread on X + LinkedIn post |

---

## 2. Phase 0 models

### 2.1 Volatility backtest (done)

`simulation/volatility_backtest.py` replays the forecasting rules on daily BTC and ETH prices from 2019 to 2026. The results, in [simulation/results/volatility_backtest.md](../simulation/results/volatility_backtest.md), set the skill definition, $\gamma$, $K$, the mean skill floor and the three-season eligibility window.

### 2.2 Economic simulation (done)

`simulation/economic_simulation.py` models the protocol pool, revenue split, buybacks, reserve, emissions, airdrop and vesting over 36 months, with Monte Carlo runs for weak, medium and strong demand. The results, in [simulation/results/economic_simulation.md](../simulation/results/economic_simulation.md), set the launch FDV (100 ETH, range up to the maximum price), $T_{ETH}$ (0.07 ETH per season) and `minVe` (5,000 veTENAX).

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
│   │   ├── distribution/CreatorVesting.sol
│   │   ├── interfaces/IWETH.sol
│   │   ├── interfaces/ISeasonTreasury.sol
│   │   ├── interfaces/IPriceObserver.sol
│   │   ├── governance/TenaxGovernor.sol
│   │   ├── governance/TenaxTimelock.sol
│   │   ├── hooks/LaunchFeeHook.sol
│   │   └── launch/PoolLauncher.sol
│   ├── test/ (unit/ fuzz/ invariant/ fork/)
│   ├── script/Deploy.s.sol
│   └── foundry.toml
├── simulation/                 # economic and scoring model
├── frontend/                   # Vite + React + TypeScript
├── docs/ (WHITEPAPER.md, IMPLEMENTATION.md, ARCHITECTURE.md, SECURITY.md, TOKENOMICS.md)
└── README.md
```

**Toolchain:** Solidity 0.8.26 (`evm_version = cancun`), OpenZeppelin Contracts v5.x, Uniswap v4 (`v4-periphery` 1.0.1 with its `v4-core`), Foundry, Slither, Aderyn. The hook address salt is mined in the deploy script for the standard CREATE2 factory. Local tests simulate the OP Stack predeploys with `vm.etch` and `vm.mockCall`.

---

## 4. Deployment

1. Safe (existing) and `TenaxTimelock`, with the deployer as temporary admin.
2. `TenaxToken`, minting the supply to the script address.
3. `VotingEscrow`, `OracleAdapter`, `ForecastRegistry`, `Treasury`, `SeasonRewards`, `FeeDistributor`, `RevenueRouter`, `LiquidityVault`, `MerkleAirdrop` (closed), `CreatorVesting`, `TenaxGovernor`.
4. Authorize `SeasonRewards`, `MerkleAirdrop` and `Treasury` on `createLockFor`, and initialize the `Treasury` with `SeasonRewards` and the keeper task list.
5. Transfer allocations according to the tokenomics; the 20M of initial liquidity go to the `PoolLauncher`.
6. Configure the timelock roles (the governor proposes and cancels, the Safe cancels, anyone executes) and renounce the deployer's admin role.
7. Mine the salt and deploy `LaunchFeeHook`, which only lets the `PoolLauncher` initialize the pool.
8. Through the `PoolLauncher`, create the pool and the single-sided TENAX position in a single transaction, with the position NFT minted straight to the `LiquidityVault`; then register the position in the vault and the pool and its hook in the `Treasury`.
9. Open the airdrop claim.
10. Verify all contracts on Basescan.

**Environments:** Anvil → Base Sepolia → Base mainnet.
**Keys:** `cast wallet` (keystore) or a hardware wallet; never a plaintext key for mainnet.

---

## 5. Launch checklist

- [ ] Tests passing, ≥ 95% coverage on core contracts
- [ ] Slither/Aderyn with no open critical findings
- [ ] `SECURITY.md` and `TOKENOMICS.md` published
- [ ] Deploy script rehearsed on an Anvil fork of Base and on Base Sepolia
- [ ] Full test season on Base Sepolia (forecasts, reveals, scoring, aggregate, fee collection, distribution, keepers, governance)
- [ ] Airdrop Merkle tree generated from the test season and published
- [ ] Uniswap v4 `PoolManager` and `PositionManager` addresses on Base confirmed
- [ ] Chainlink BTC/USD and ETH/USD feed addresses on Base confirmed (the data feed directory currently lists SVR variants)
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
- **Revenue:** claimable ETH (holders and forecasters) and locked TENAX rewards; season registration status and claims
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
| 7 | `minVe` and `K` | 5,000 veTENAX; K = 50 with weight capped at 2; EMA α = 1/32; threshold EMA β = 1/30, base rate EMA γ = 1/365 |
| 8 | Season rewards | Linear in the season's skill; eligible with ≥ 20 rounds in the season, and z ≥ 1.64 and mean skill ≥ 0.003 over the last 3 seasons |
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
| 19 | Advanced verification | Differential tests against closed-form formulas plus invariants; symbolic execution (Halmos) was tried and dropped because 256-bit division properties exceed solver limits |
| 20 | Launch price range | Launch FDV of 100 ETH: from 1e-6 ETH per TENAX up to the maximum price |
| 21 | Early exit | Voluntary portion only; penalty = min(time left / 104 weeks, 50%), burned; emissions and airdrop cannot exit early |
| 22 | Skill reference | Skill against the realized Brier of answering b: S = (b − o)² − (p − o)²; b stored in basis points and initialized from the last year of prices |
| 23 | Value thesis | Value through scarcity: locked supply, locked emissions, sell burn, early exit burn, buybacks and unused reserve burn |
| 24 | Treasury | Rule-based `Treasury` contract with no withdrawal function; 20% of ETH revenue |
| 25 | Treasury ETH | Keeper reserve of 90 days of maximum budget; all surplus buys back TENAX and burns it (at most once per 24 h, capped, 2% TWAP guard) |
| 26 | Treasury TENAX | 20M reserve released at 1/60 per season (~5 years); pays locked keeper rewards and a season top-up that shrinks as ETH revenue reaches $T_{ETH}$; unused allowance burned |
| 27 | Airdrop leftovers | Unreceived fractions and unclaimed balances are burned |
| 28 | Revenue target | $T_{ETH}$ = 0.07 ETH per season, about 0.07% of the launch FDV |
| 29 | Oracle prices | Exact price at each checkpoint: the keeper names the Chainlink round (and sequencer status round) active at that timestamp and the adapter verifies it |
| 30 | Reveal and scoring | Reveals open at the resolve time regardless of keepers; scoring is lazy, once the round resolves |
| 31 | Missed resolution | A round with no valid resolution by the end of its reveal window can be voided by anyone |
| 32 | Season reward accounting | Registration, then claim: from 8 d 6 h after a season ends, anyone registers eligible participants for 7 days, settling their scores; the budget is then fixed and split by the exact sum of registered contributions; with no registrations it carries over to the next season |
| 33 | Airdrop claim period | 90 days after opening; unclaimed balances are then burned |
| 34 | Creator vesting | `CreatorVesting` on OpenZeppelin's `VestingWallet`: 365-day cliff, then linear over 730 days |
| 35 | Phase 5 split | 5a: revenue router, fee distributor and treasury; 5b: liquidity vault and buyback on Uniswap v4 |
| 36 | Keeper payment | Tasks run through `Treasury.execute` against a task list fixed at deployment; the treasury measures the gas and pays; the underlying functions stay permissionless and unpaid |
| 37 | Keeper parameters | Initial values: 0.01 gwei maximum tip (bound 1 gwei), 0.0005 ETH per call (0.00001 to 0.01), 0.02 ETH per 30 days (0.001 to 1), 250 TENAX fallback (up to 2,500); revenue target bounds 0.01 to 10 ETH |
| 38 | Reserve settlement | `SeasonRewards` settles each season's allowance with the treasury when it closes the season; TENAX keeper rewards draw on the allowance of the season in progress |
| 39 | Uniswap v4 dependency | `v4-periphery` pinned at release 1.0.1 (commit `ea2bf2e`), matching the live deployment; tests deploy the position manager from its artifact, compiled through the IR pipeline |
| 40 | Buyback price guard | Reverts unless the spot tick is at most 198 ticks (about 2%) above the 30-minute average and strictly above the swap limit 198 ticks below it; unspent ETH is wrapped back |
| 41 | Buyback cap | 0.05 ETH per call initially, bounds 0.001 to 10 ETH |
| 42 | Fee collection | The vault distributes collected ETH through the router in the same call; `collectFees` and `buyback` are daily keeper tasks |
| 43 | Safe role | Guardian only: cancels any proposal, queued ones included, but never proposes; governance can replace or remove it |
| 44 | Governance bounds | Voting delay 1 h to 7 d, voting period 1 to 14 d, threshold 10k to 1M veTENAX, quorum 4% to 30%, timelock delay 1 to 14 d |
| 45 | Timelock roles | The governor proposes and cancels, the Safe cancels, anyone executes; the timelock is its own admin after the deployer renounces |
| 46 | Launch protection | Decaying launch fee only; no per-swap size limit |
| 47 | Pool creation | `PoolLauncher` is the only account the hook lets initialize the pool, once; it creates the pool and mints the position to the vault in the same transaction |
| 48 | Average price | Cumulative tick updated before the first swap of each block; 128 observations at least 30 s apart; exact between observations when no swap happened in between, interpolated otherwise |
| 49 | Deployment | One script (`Deploy.s.sol`) runs every step; the hook salt is mined for the standard CREATE2 factory; rehearsed with a full broadcast on an Anvil fork of Base |
| 50 | Keeper task list | Resolve, void and finalize rounds; register forecasters and close seasons; collect fees, buy back and distribute revenue (the last three at most once a day) |
| 51 | Guardian term | The guardian's cancel powers in the governor and the timelock expire 104 weeks after deployment, so it cannot veto its own removal indefinitely |
| 52 | Keeper calldata | Each keeper task records its exact calldata size; padded calldata is rejected, so the L1 data refund cannot be inflated |
| 53 | Security review | Manual review plus Slither 0.11.6 and Aderyn 0.6.8 (official Linux binary), every result triaged in `docs/SECURITY.md` |
