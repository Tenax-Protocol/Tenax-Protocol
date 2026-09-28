# Front-end

The Tenax Protocol dApp: a static site in Vite, React and TypeScript, with [wagmi](https://wagmi.sh) and [viem](https://viem.sh). It has no server; everything is read from the chain through a public RPC, except the leaderboard, which comes from a snapshot file. It targets the Base Sepolia test deployment and reads its addresses from `deployments/base-sepolia.json` and its ABIs from `offchain/src/abi`.

Published at https://tenax-protocol.github.io/Tenax-Protocol/.

## Pages

- **Overview:** the current round, each asset's threshold and base rate, your position and how to take part.
- **Forecast:** commit a probability for each asset while submissions are open, and reveal past forecasts once their round resolves.
- **Buy:** swap ETH for TENAX in the protocol's Uniswap v4 pool, through the Universal Router.
- **Lock:** create a lock (with a suggested amount that keeps 5,000 veTENAX for 60 days), add to it, extend it, withdraw it or exit early with the penalty shown first.
- **Rounds:** the latest rounds of each asset, with outcome, crowd forecast and your skill.
- **Leaderboard:** skill and significance per season, from the snapshot.
- **Rewards:** season registration and claims, and the weekly revenue share.

## Forecast salts

A forecast is committed as a hash that includes a secret salt. The dApp derives every salt from one signature of a fixed message, the forecast key, and the round, so there is nothing to back up: signing again on any device gives the same salts. At reveal time the forecast itself is recovered by trying every value from 0 to 10,000 against the commitment stored on chain. The key is also kept in the browser, for wallets whose signatures are not deterministic.

## Development

Requires Node 20.19 or later.

```
npm ci
npm run dev        # http://localhost:5173
npm run typecheck
npm test
npm run build      # static site in dist/
```

The leaderboard reads `public/data/base-sepolia.json`; generate it locally with `npm run snapshot` in `../offchain` (it needs `RPC_URL`).

`npx tsx scripts/fork-check.ts` checks the transaction encoding (quote, buy, lock, commitment hash, commit, forecast recovery and reveal) against an Anvil fork of Base Sepolia; it needs Foundry and the test deployment.

## Publishing

The `frontend` workflow builds the site and publishes it to GitHub Pages on every change to `main` and every hour, refreshing the leaderboard snapshot first. It needs Settings > Pages > Source set to GitHub Actions. The secret `BASE_SEPOLIA_RPC_URL` is optional; the public endpoint is used without it.
