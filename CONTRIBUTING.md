# Contributing

Branch, commit, pull request and code conventions for Tenax Protocol.

## Workflow

1. Create a branch from an up-to-date `main`.
2. Make small commits, each with a single logical change.
3. Open a pull request against `main`.
4. Once checks pass, **squash merge**. The PR title becomes the commit message on `main`.
5. Delete the branch after merging.

`main` never receives direct pushes and must always have passing tests.

## Branches

Format: `<type>/<short-description>`, lowercase, words separated by hyphens.

| Type | Use | Example |
|---|---|---|
| `feat/` | New feature | `feat/voting-escrow-checkpoints` |
| `fix/` | Bug fix | `fix/fee-distributor-rounding` |
| `docs/` | Documentation only | `docs/security-report` |
| `test/` | Tests only | `test/escrow-invariants` |
| `refactor/` | Internal change with no behavior change | `refactor/brier-math-fixed-point` |
| `chore/` | Configuration, dependencies, tooling | `chore/foundry-setup` |
| `ci/` | CI pipelines | `ci/slither-workflow` |

Each roadmap phase (section 1 of the [implementation plan](docs/IMPLEMENTATION.md)) gets its own branch, with the phase number: `feat/phase-1-token`, `feat/phase-2-voting-escrow`.

## Commits

Commits follow [Conventional Commits 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/):

```
<type>(<scope>): <subject>

<body>

<footer>
```

**Types:** `feat`, `fix`, `docs`, `test`, `refactor`, `perf`, `chore`, `ci`, `build`, `style`, `revert`.

**Scopes:**

| Scope | Area |
|---|---|
| `token` | `TenaxToken`, ERC-3009 |
| `escrow` | `VotingEscrow` |
| `forecast` | `ForecastRegistry`, `BrierMath` |
| `oracle` | `OracleAdapter` |
| `liquidity` | `LiquidityVault` |
| `revenue` | `RevenueRouter`, `FeeDistributor`, `Treasury` |
| `rewards` | `SeasonRewards`, `EmissionSchedule` |
| `airdrop` | `MerkleAirdrop` |
| `gov` | `TenaxGovernor`, Timelock |
| `hook` | `LaunchFeeHook` |
| `deploy` | Deploy and launch scripts |
| `sim` | Economic simulation |
| `app` | Front-end |
| `deps` | Dependencies |

The scope is optional when a change does not belong to one area (e.g. `docs: fix typos in readme`).

**Subject rules:**
- Imperative mood: "add", not "added" or "adds".
- Lowercase, no trailing period, 72 characters max for the whole header.

**Body (optional):** explains why the change was made, not how. Wrap lines at 72 characters.

**Footer (optional):**
- `Closes #12` / `Refs #12` for issues.
- Breaking change: `!` after the type/scope and a `BREAKING CHANGE: <description>` footer.

**Examples:**

```
feat(escrow): add weekly slope changes to checkpoints
fix(revenue): round fee shares down in favor of the protocol
test(forecast): add invariant for aggregate probability bounds
docs: move development guidelines to contributing guide
chore(deps): bump openzeppelin-contracts to 5.x
feat(rewards)!: measure emission epochs in l1 blocks

BREAKING CHANGE: EmissionSchedule now reads L1Block.number()
instead of block.timestamp.
```

A template with this format is in [.gitmessage](.gitmessage). To use it: `git config commit.template .gitmessage`.

## Pull requests

- **Title:** same format as a commit (`feat(escrow): add increaseUnlockTime`), since it becomes the squash commit.
- **Description:** what changes, why, how it was tested and what was left out.
- One PR per topic. Phase PRs may be large, but never mix phases.

Checklist before requesting a merge:

- [ ] `forge fmt --check` shows no differences
- [ ] `forge build` with no warnings
- [ ] `forge test` passing (unit, fuzz, invariant)
- [ ] Slither and Aderyn with no new unannotated findings
- [ ] NatSpec on new public and external functions
- [ ] Documentation updated if behavior changed

## Versions and tags

[SemVer](https://semver.org/) with annotated tags on `main`:

- `v0.<phase>.<patch>` during development: `v0.1.0` when phase 1 is done, `v0.1.1` for a fix to it.
- `v1.0.0` at mainnet launch.

```
git tag -a v0.1.0 -m "phase 1: TenaxToken and ERC-3009"
git push origin v0.1.0
```

## Code conventions

**Solidity**
- Solidity `0.8.26` with a pinned pragma; `evm_version = "cancun"`.
- OpenZeppelin Contracts v5.x; reuse audited contracts whenever possible.
- Formatting with `forge fmt`; element ordering per the [Solidity Style Guide](https://docs.soliditylang.org/en/latest/style-guide.html).
- Custom errors instead of `require` with strings; events for every relevant state change; full NatSpec.
- Checks-Effects-Interactions; `SafeERC20`; `ReentrancyGuardTransient` wherever ETH is sent.
- ETH, WETH and TENAX have 18 decimals; fixed point with 1e18 scale, rounding in the protocol's favor.
- Internally the protocol uses WETH (`0x4200000000000000000000000000000000000006` on Base); native ETH only in the pool and in optional claims.
- No `tx.origin`; no DEX spot price as an oracle.
- No loops over participants; every loop is bounded.

**Tests**
- Layout: `test/unit`, `test/fuzz`, `test/invariant`, `test/fork`, `test/symbolic`.
- Test names: `test_<function>_<scenario>`, `testFuzz_<...>`, `invariant_<...>`, `test_RevertWhen_<condition>`.
- A phase is only done when its tests pass and core contracts have ≥ 95% coverage.

## Security and deployment

- Never commit private keys, mnemonics or `.env` files. Use `cast wallet` (keystore) or a hardware wallet.
- Mainnet deployments are done only by the maintainer, after the launch checklist (section 5 of the implementation plan).
- Vulnerabilities: do not open a public issue; contact the maintainer directly.
