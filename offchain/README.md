# Off-chain

Keeper bot and season tools for Tenax Protocol, in TypeScript with [viem](https://viem.sh). They read contract addresses from `deployments/<network>.json`, written by `contracts/script/Deploy.s.sol`.

## Setup

Requires Node 20 or later.

```
npm ci
npm run abi        # after `forge build` in ../contracts: refresh the ABIs in src/abi
npm run typecheck
npm test
```

## Keeper

`npm run keeper -- --network base-sepolia` runs one pass over every keeper task and exits; add `--loop 600` to keep running. Every task goes through `Treasury.execute`, which pays for it, and every call is simulated first, so a task that is not due is only logged. A pass:

- resolves every round past its resolve time, with the Chainlink rounds active at its two checkpoints as hints, and voids rounds whose prices cannot be proven by the end of their reveal window;
- finalizes rounds past their reveal window;
- registers participants during a season's registration period and closes the season after it;
- collects pool fees, runs the buyback and distributes revenue when their daily intervals allow.

Environment: `RPC_URL` and `KEEPER_PRIVATE_KEY`. On GitHub, the `keeper` workflow runs a pass every 10 minutes once the repository variable `KEEPER_ENABLED` is `true` and the secrets `BASE_SEPOLIA_RPC_URL` and `KEEPER_PRIVATE_KEY` are set. Use a key that only ever holds testnet funds.

## Airdrop

`npm run airdrop -- --network base-sepolia --seasons 0` builds the airdrop from the test season and writes `airdrop/<network>.json` with the Merkle root and every recipient's proof. Participants must pass the season reward tests (at least 20 scored rounds, mean skill of at least 0.003 and z of at least 1.64) over the whole test season. The 10,000,000 TENAX are split half in equal parts and half in proportion to each one's skill. Participants with unsettled commitments are listed as a warning, since their stats are not final until settled. Needs `RPC_URL`.

`npm run fixture` regenerates `contracts/test/fixtures/airdrop-tree.json`, a fixed tree that a Solidity test claims against `MerkleAirdrop` to prove the encoding matches.

## Rehearsal

`npm run rehearsal` plays a full test season on a local fork of Base Sepolia, against the real Uniswap v4 deployment there, in a few minutes:

1. deploys the protocol with the deployment script, with mock price feeds the rehearsal controls;
2. has six participants buy TENAX in the pool and lock it: two skilled forecasters, two that always answer the base rate and two random ones;
3. plays the 30 daily rounds of season 0 on both assets, with the real keeper resolving, finalizing, collecting fees and buying back;
4. moves through the registration period, lets the keeper register and close the season, and has participants claim;
5. builds the airdrop tree from the season;

and checks that every round resolved with the expected outcome, that only the skilled forecasters were registered, claimed rewards and received the airdrop, and that the airdrop stays within its budget. Needs Foundry (`anvil`, `forge`) and access to a Base Sepolia RPC (`SEPOLIA_RPC_URL`, the public endpoint by default).
