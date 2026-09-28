# Security

This document is the security review of Tenax Protocol's smart contracts, written in the format of an audit report, and the policy for reporting vulnerabilities. It is an internal review by the protocol's developer, not an independent audit.

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub's [private vulnerability reporting](https://github.com/Tenax-Protocol/Tenax-Protocol/security/advisories/new) for this repository, not in a public issue. The contracts are immutable, so a confirmed vulnerability in deployed code is handled by warning users and, where needed, deploying a fixed version that users migrate to voluntarily.

---

## 1. Summary

| | |
|---|---|
| Scope | Every contract in `contracts/src` (19 contracts, about 3,500 lines of Solidity) |
| Version | Release `v0.8.0` of this repository |
| Compiler | Solidity 0.8.26, EVM version `cancun` |
| Methods | Manual review, Slither 0.11.6, Aderyn 0.6.8, unit, fuzz, invariant and fork tests |
| Result | 1 medium and 1 low severity issue, both fixed; 1 informational issue fixed; 9 informational notes acknowledged |

No critical or high severity issue was found. Every static analysis result was reviewed and is listed in [appendix A](#appendix-a-static-analysis-triage) with its disposition.

### Severity levels

| Severity | Meaning |
|---|---|
| Critical | Loss or permanent lock of funds, or takeover of the protocol, with no preconditions |
| High | Loss of funds or broken core mechanics under realistic conditions |
| Medium | Loss of value, broken guarantees or denial of service under specific conditions |
| Low | Bounded loss or unexpected behavior with limited impact |
| Informational | Design notes, trust assumptions and code quality |

## 2. Scope

| Area | Contracts |
|---|---|
| Token | `TenaxToken`, `ERC3009` |
| Vote escrow | `VotingEscrow`, `EscrowMath` |
| Forecasting | `ForecastRegistry`, `OracleAdapter`, `BrierMath` |
| Distribution | `EmissionSchedule`, `SeasonRewards`, `MerkleAirdrop`, `CreatorVesting` |
| Revenue | `RevenueRouter`, `FeeDistributor`, `Treasury` |
| Liquidity and launch | `LiquidityVault`, `LaunchFeeHook`, `PoolLauncher` |
| Governance | `TenaxGovernor`, `TenaxTimelock` |

Out of scope: the dependencies (OpenZeppelin Contracts 5.7.0, Uniswap v4 core and periphery 1.0.1), the deployment script beyond the roles it leaves in place, the front-end and off-chain keepers. The dependencies are used unmodified and pinned to exact releases.

## 3. Methodology

**Manual review.** Every contract was read against the [whitepaper](WHITEPAPER.md), with attention to value flows (who can move TENAX, WETH and ETH, and under which conditions), permissions and one-time initializers, arithmetic and rounding direction, external calls and reentrancy, oracle and price manipulation, keeper incentives, and governance powers.

**Static analysis.** Slither 0.11.6 (102 detectors) and Aderyn 0.6.8 (88 detectors) were run on `contracts/src`, excluding libraries, tests and scripts. Aderyn ran from its official Linux release binary, verified against the published SHA-256.

**Tests.** The suite has more than 350 tests, run in CI with 10,000 fuzz runs per property:

- unit and integration tests for every contract, including a run of the full deployment script followed by trading, fee collection and a buyback guarded by the real average price;
- 37 fuzz properties, including differential tests of the vote-escrow, early exit, scoring and emission math against closed-form references;
- 32 invariants in 6 stateful suites (token, vote escrow, forecasting, distribution with the treasury, fee distribution, liquidity), each run in CI for at least 128 campaigns of at least 200 random calls;
- fork tests against Base mainnet: Chainlink feeds, the Uniswap v4 pool manager and position manager, WETH, the `L1Block` predeploy and the standard CREATE2 factory.

Line coverage is 99.3% and function coverage 100% across `contracts/src`. The lines reported as uncovered are constructor argument checks, which have tests the coverage tool does not attribute, and a few lines of `FeeDistributor` that the tool misattributes in its minimal optimization mode.

**Deployment rehearsal.** The deployment script was broadcast in full to an Anvil fork of Base mainnet, and the resulting state was checked on chain.

## 4. Findings

| ID | Title | Severity | Status |
|---|---|---|---|
| TNX-01 | The guardian can cancel the proposal that removes it | Medium | Fixed |
| TNX-02 | Keepers can pad calldata to inflate their L1 data refund | Low | Fixed |
| TNX-03 | Revenue receivers do not declare the depositor interface; initialization events lack indexed addresses | Informational | Fixed |
| TNX-04 | A buyback can be sandwiched within the 2% band | Informational | Acknowledged |
| TNX-05 | Delivered locks extend the whole existing lock | Informational | Acknowledged |
| TNX-06 | `minVe` is only checked when committing | Informational | Acknowledged |
| TNX-07 | Donated revenue reduces the reserve top-up | Informational | Acknowledged |
| TNX-08 | Third-party liquidity shares the protocol pool's fees | Informational | Acknowledged |
| TNX-09 | A price in the last round of an old Chainlink phase cannot be proven | Informational | Acknowledged |
| TNX-10 | The deployer holds one-time powers until the deployment ends | Informational | Acknowledged |
| TNX-11 | The guardian can cancel any proposal during its term | Informational | Acknowledged |
| TNX-12 | External dependencies and immutability | Informational | Acknowledged |

### TNX-01. The guardian can cancel the proposal that removes it

**Severity:** Medium. **Status:** Fixed.

`TenaxGovernor` uses OpenZeppelin's `GovernorProposalGuardian`, which lets the guardian cancel any proposal, and the guardian Safe also holds the timelock's canceller role, which lets it cancel any queued operation. Both powers apply to the proposal that would remove the guardian, so removing it depended on the guardian's cooperation, while the design stated that governance can remove it.

**Fix.** The guardian's powers expire on their own 104 weeks after deployment. `TenaxGovernor.proposalGuardian()` returns zero from `guardianExpiry` on, after which proposers can again cancel their own proposals, and `TenaxTimelock.cancel` rejects the guardian after the same term, whatever roles it still holds. Governance can still remove the guardian earlier. Tests: `test_guardian_expiresOnItsOwnAfter104Weeks`, `test_guardian_termEndsProposerRestrictions`.

### TNX-02. Keepers can pad calldata to inflate their L1 data refund

**Severity:** Low. **Status:** Fixed.

`Treasury.execute` refunds a keeper's L2 gas and the L1 data fee, estimated from the length of the task's calldata. ABI decoding ignores trailing bytes, so a keeper could append arbitrary bytes to a valid call: the task would run normally while the L1 refund grew up to the per-call cap. The impact was bounded by the cap (0.0005 ETH per call) and the monthly budget (0.02 ETH), but let a keeper exhaust the budget with refunds above cost.

**Fix.** Every paid task takes fixed-size arguments, so each `Task` now records its exact calldata length, and `execute` rejects any other length. The deployment test checks each recorded length against the encoding of the real call. Tests: `test_RevertWhen_calldataIsPadded`, `test_deploy_keeperTasksExpectTheirExactCalldata`.

### TNX-03. Interface and event hygiene

**Severity:** Informational. **Status:** Fixed.

`SeasonRewards` and `FeeDistributor` implemented `depositEth` without inheriting the `IEthDepositor` interface the router calls, and `Treasury`'s one-time initialization events had unindexed address parameters. Both now inherit the interface from `src/interfaces/IEthDepositor.sol`, so the compiler enforces the signature, and the event addresses are indexed.

### TNX-04. A buyback can be sandwiched within the 2% band

**Severity:** Informational. **Status:** Acknowledged.

Anyone can call `buyback` once the 24-hour interval has passed. A trader can push the TENAX price up to just under 2% above its 30-minute average, trigger the buyback, and sell afterwards. The profit is bounded by the band, the cap per buyback (0.05 ETH initially) and the 0.3% pool fee paid on both legs, leaving at most about 1.4% of one buyback. Pushing the price further makes the buyback revert, and the swap never moves the price past 2% below the average.

### TNX-05. Delivered locks extend the whole existing lock

**Severity:** Informational. **Status:** Acknowledged.

`createLockFor` adds delivered tokens to the beneficiary's existing lock and extends its unlock time to the required minimum. A user with a short voluntary lock who claims a season reward (52 weeks) or an airdrop (up to 104 weeks) therefore also extends the voluntary portion, which raises its early exit penalty. This follows from the single lock per address. The front-end must show the new unlock time before a claim.

### TNX-06. `minVe` is only checked when committing

**Severity:** Informational. **Status:** Acknowledged.

`ForecastRegistry.commit` requires 5,000 veTENAX at the time of the commitment. A participant can then exit the voluntary part of the lock early and still reveal and be scored. Doing so costs the early exit penalty, burned, and the vote escrow keeps the delivered part locked, so the requirement keeps its purpose as a cost per wallet.

### TNX-07. Donated revenue reduces the reserve top-up

**Severity:** Informational. **Status:** Acknowledged.

`SeasonRewards.depositEth` is permissionless. ETH deposited during a season counts as that season's revenue, so a donor can reduce the treasury's top-up, and increase the burn of the unused allowance, by giving ETH to the season's forecasters. The effect is the same as real revenue arriving, and the donor pays for it in full.

### TNX-08. Third-party liquidity shares the protocol pool's fees

**Severity:** Informational. **Status:** Acknowledged.

The launch hook restricts the pool's initialization, not liquidity. Anyone can add a position to the protocol's pool and earn part of its fees, which reduces the protocol's share. The protocol's own position can never be removed, and competing liquidity is already listed as a risk in the whitepaper.

### TNX-09. A price in the last round of an old Chainlink phase cannot be proven

**Severity:** Informational. **Status:** Acknowledged.

`OracleAdapter` proves that a Chainlink round was active at a timestamp by showing that the next round started later. When Chainlink upgrades a feed, round ids jump to a new phase, and the last round of the old phase has no provable successor. A checkpoint falling in that round cannot be priced, its forecasting round cannot be resolved, and anyone can void it once its reveal window ends. Such rounds are rare and nobody is scored on them. Test: `test_RevertWhen_hintIsTheLastRoundOfAnOldPhase`.

### TNX-10. The deployer holds one-time powers until the deployment ends

**Severity:** Informational. **Status:** Acknowledged.

During the deployment script, the deployer is the timelock's admin and the only account allowed to call one-time initializers: the escrow's distributor list, the treasury's task list and market, the vault's position, the airdrop opening and the launch. Every one of them is consumed by the script and the admin role is renounced. `test_deploy_leavesTheDeployerNoPower` checks that none can be called again after deployment.

### TNX-11. The guardian can cancel any proposal during its term

**Severity:** Informational. **Status:** Acknowledged.

Until its term ends (TNX-01), the guardian Safe can cancel any proposal, including legitimate ones. This is a deliberate trust assumption for the protocol's first two years: governance only moves bounded parameters and holds no funds, so the guardian's power is limited to delaying parameter changes.

### TNX-12. External dependencies and immutability

**Severity:** Informational. **Status:** Acknowledged.

The protocol depends on Chainlink feeds and the L2 sequencer uptime feed, the OP Stack `L1Block` and `GasPriceOracle` predeploys, Uniswap v4, WETH and the standard CREATE2 factory, all used through their deployed addresses on Base. The contracts have no upgrade path: a flaw in deployed code requires a new deployment and a voluntary migration. The Chainlink feed variant used on Base is an open launch checklist item.

## 5. Issues resolved during development

The following issues were found by tests and design review while the contracts were being built, and fixed before this review:

| Issue | Resolution |
|---|---|
| A keeper resolving a round could pick a favorable price from the oracle's history | The price is the Chainlink round active at the exact checkpoint, proven on chain from round hints |
| Lazy scoring could change the reward denominator after some participants had claimed | A registration period settles each participant's scores before the season's budget is split |
| A buyback with the price exactly at the lower edge of the band reverted inside the pool | The band check and the swap's price limit were unified, so the buyback reverts with its own error |

## 6. Invariants verified

The stateful suites assert, after every call of random valid sequences:

- TENAX supply never increases and always equals the initial supply minus burns; balances sum to the supply; a used EIP-3009 nonce can never be replayed.
- The vote escrow's TENAX balance equals its recorded supply and the sum of locks; the sum of veTENAX balances equals the total supply; voting power never exceeds the locked amount; history stays consistent; tokens delivered by distributors never leave before unlock; supply only falls through burned early exit penalties.
- Each commitment is scored at most once; pending lists stay bounded; weights, reputation and aggregates stay within their ranges; asset state stays valid; season contributions require eligibility and their totals match the participants'.
- Cumulative emission never exceeds the schedule or the 35M bucket; season budgets are conserved and never overpaid; no emission, airdrop or keeper reward is ever delivered liquid.
- The airdrop never exceeds its 10M bucket; the treasury reserve never releases more than the allowances due, and every closed season's allowance is fully settled.
- Fee distribution never pays more than it received, and weekly revenue is conserved across rollovers.
- The protocol position's liquidity never decreases; every TENAX bought back or collected as fees is burned; the treasury's WETH is fully accounted for.

---

## Appendix A. Static analysis triage

Results of the final runs, after the fixes above. "False positive" means the detector's premise does not hold for the code; "by design" means the pattern is intended and safe for the stated reason.

### Slither 0.11.6: 77 results

| Detector | Results | Disposition |
|---|---|---|
| `uninitialized-state` (high) | 6 | False positive. `VotingEscrow`'s `epoch`, `userPointHistory`, `userPointEpoch` and `slopeChanges` are written in `_checkpoint`, and `SeasonRewards`' `_seasons` and `_registrations` through storage pointers; the invariant suites exercise all of them. |
| `weak-prng` (high) | 1 | False positive. The modulo in `LaunchFeeHook.meanTick` rounds a negative average toward negative infinity; it is not randomness. |
| `divide-before-multiply` (medium) | 3 | By design. Week rounding in `EscrowMath` and `FeeDistributor`, and a constant half-lock cap in the early exit penalty. |
| `incorrect-equality` (medium) | 6 | By design. Checks for zero amounts, unset deadlines and exact timestamps, none of which an attacker can steer toward a harmful result. |
| `reentrancy-no-eth` (medium) | 1 | By design. `Treasury._payKeeperInTenax` reverts its own accounting when the escrow rejects a delivery; `execute` cannot be reentered and the escrow is an immutable protocol contract. |
| `unused-return` (medium) | 10 | By design. Unused fields of Uniswap, Chainlink and escrow getters; the pool's initial tick, known in advance; and `settle`, whose amount is the value sent. |
| `calls-loop` (low) | 9 | By design. Loops bounded by the asset count (2) or 52 weeks, over protocol contracts. |
| `reentrancy-benign`, `reentrancy-events` (low) | 6 | By design. State and events after calls to Uniswap or protocol contracts that do not call back; the state that guards each function is written before the call. |
| `timestamp` (low) | 32 | By design. The protocol clock is the block timestamp (locks, rounds, seasons, intervals); second-level drift has no meaningful effect. |
| `cyclomatic-complexity` (informational) | 1 | Acknowledged. `VotingEscrow._checkpoint` follows Curve's reference implementation and is covered by differential tests. |
| `naming-convention` (informational) | 1 | By design. `CLOCK_MODE` is the name required by ERC-6372. |
| `constable-states` (optimization) | 1 | False positive. `VotingEscrow.epoch` changes on every checkpoint. |

### Aderyn 0.6.8: 13 detectors

| Detector | Instances | Disposition |
|---|---|---|
| `contract-locks-ether` (high) | 5 | False positive. `SeasonRewards`, `FeeDistributor`, `Treasury` and `LiquidityVault` only accept ETH from WETH or the pool manager and forward it in the same call; `CreatorVesting` releases ETH through `release()`. |
| `reentrancy-state-change` (high) | 29 | By design. Most are view calls in constructors and checks. The rest follow calls to protocol contracts that do not call back, or to Uniswap after the guarding state is written. |
| `unsafe-casting` (high) | 2 | By design. The average of valid ticks is a valid tick, and TENAX amounts are far below 2^128; both casts are commented in the code. |
| `costly-loop`, `require-revert-in-loop` (low) | 13 | By design. Bounded loops in one-time setup, weekly checkpoints and the pending-score list. |
| `division-before-multiplication` (low) | 1 | By design. Week rounding. |
| `large-numeric-literal`, `literal-instead-of-constant` (low) | 18 | Acknowledged. Literals are basis points, fee units and fixed schedule values next to their comments. |
| `missing-inheritance` (low) | 1 | False positive. `PoolLauncher` does not implement Uniswap's `IImmutableState`. |
| `state-change-without-event` (low) | 1 | By design. `VotingEscrow.checkpoint` only advances history; every balance change emits its own event. |
| `unchecked-return` (low) | 2 | By design. The pool's initial tick and the executed task's return data are not needed. |
| `uninitialized-local-variable` (low) | 1 | False positive. A loop counter starting at zero. |
| `unused-public-function` (low) | 1 | By design. `VotingEscrow.totalSupply` is part of its public interface. |
