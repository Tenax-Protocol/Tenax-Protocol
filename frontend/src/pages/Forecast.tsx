import { forecastRegistryAbi } from "@abi";
import { type CSSProperties, useMemo, useState } from "react";
import type { Address, Hex } from "viem";
import { AssetBadge, Card, ConnectPrompt, Countdown, Loading, PageHeader, Stat, TxStatus } from "../components.js";
import { type Protocol, RoundStatus, useCommitments, usePosition, useProtocol } from "../data.js";
import { useAccount, useForecastKey, useNow, useTx } from "../hooks.js";
import { contracts, MIN_VE, network } from "../lib/config.js";
import { commitmentHash, deriveSalt, recoverForecast, toBps } from "../lib/forecast.js";
import { formatBps, formatDuration, formatFraction, formatTime, formatToken } from "../lib/format.js";
import { skillOf } from "../lib/stats.js";

type Asset = Protocol["assets"][number];
type Entry = NonNullable<ReturnType<typeof useCommitments>["data"]>[number];

/** Forecasts already recovered, by commitment hash, so refreshes do not search again. */
const recoveredCache = new Map<string, bigint | null>();

function recoverCached(ctx: ReturnType<typeof context>, hash: Hex, salt: Hex): bigint | null {
  const id = `${hash}:${salt}`;
  if (!recoveredCache.has(id)) recoveredCache.set(id, recoverForecast(ctx, hash, salt));
  return recoveredCache.get(id)!;
}

const tone = (skill: number) => (skill > 0 ? "up" : skill < 0 ? "down" : "");

const context = (account: Address, asset: bigint, round: bigint) => ({
  chainId: network.chain.id,
  registry: contracts.registry,
  asset,
  round,
  participant: account,
});

function CommitForm({
  asset,
  protocol,
  account,
  blocked,
}: {
  asset: Asset;
  protocol: Protocol;
  account: Address;
  /** Why the forecast cannot be sealed right now; the form stays usable as a preview. */
  blocked?: string;
}) {
  const opened = asset.current.status !== RoundStatus.None;
  const baseRate = opened ? asset.current.baseRateBps : toBps(asset.state.baseRate);
  const threshold = opened ? asset.current.threshold : asset.state.threshold;
  const [forecast, setForecast] = useState(baseRate);
  const { obtain } = useForecastKey(account);
  const { run, state } = useTx();

  const commit = () =>
    run(
      async (wallet) => {
        const key = await obtain();
        const salt = deriveSalt(key, asset.id, protocol.round);
        const hash = commitmentHash(context(account, asset.id, protocol.round), BigInt(forecast), salt);
        return wallet.writeContract({
          account,
          chain: network.chain,
          address: contracts.registry,
          abi: forecastRegistryAbi,
          functionName: "commit",
          args: [asset.id, protocol.round, hash],
        });
      },
      `Forecast committed. Come back after ${formatTime(protocol.schedule(protocol.round).resolveTime)} to reveal it.`,
    );

  const skillBeyond = skillOf(forecast, baseRate, true);
  const skillWithin = skillOf(forecast, baseRate, false);
  const signed = (v: number) => `${v > 0 ? "+" : v < 0 ? "−" : ""}${Math.abs(v).toFixed(4)}`;

  return (
    <section className="card">
      <div className="question-head">
        <AssetBadge symbol={asset.symbol} />
        <div>
          <div className="question-asset">{asset.symbol}/USD</div>
          <div className="muted small">Round {protocol.round.toString()}</div>
        </div>
        <span className={`status${blocked ? "" : " open"}`}>{blocked ? "Closed" : "Open"}</span>
      </div>
      <p className="question-text">
        Will {asset.name} move more than <strong>&plusmn;{formatFraction(threshold)}</strong> in the 24 hours after
        submissions close?
      </p>
      <div className="commit-readout">
        <span className="commit-value">{(forecast / 100).toFixed(1)}</span>
        <span className="commit-unit">% probability of a move beyond the threshold</span>
      </div>
      <div className="range" style={{ "--v": forecast / 10_000, "--b": baseRate / 10_000 } as CSSProperties}>
        <input
          type="range"
          min={0}
          max={10_000}
          step={10}
          value={forecast}
          onChange={(e) => setForecast(Number(e.target.value))}
          aria-label={`Probability that ${asset.symbol} moves beyond the threshold`}
        />
        <span className="range-base" title={`Base rate ${formatBps(baseRate, 1)}`} />
        <div className="range-scale">
          <span>Stays within</span>
          <button className="link small" onClick={() => setForecast(baseRate)}>
            Base rate {formatBps(baseRate, 1)}
          </button>
          <span>Moves beyond</span>
        </div>
      </div>
      <dl className="rows skill-preview">
        <div>
          <dt>Skill if it moves beyond</dt>
          <dd className={tone(skillBeyond)}>{signed(skillBeyond)}</dd>
        </div>
        <div>
          <dt>Skill if it stays within</dt>
          <dd className={tone(skillWithin)}>{signed(skillWithin)}</dd>
        </div>
      </dl>
      <button
        className="button primary large block"
        disabled={blocked !== undefined || state.status === "pending"}
        onClick={commit}
      >
        {blocked ?? `Commit ${formatBps(forecast, 1)}`}
      </button>
      <TxStatus state={state} />
    </section>
  );
}

function RevealRow({ entry, account, now }: { entry: Entry; account: Address; now: number }) {
  const { obtain, key } = useForecastKey(account);
  const { run, state } = useTx();
  const [recovered, setRecovered] = useState<bigint | null | undefined>(undefined);
  const ctx = context(account, entry.asset.id, entry.round);
  const revealOpen = now >= Number(entry.info.resolveTime) && now < Number(entry.info.revealEnd);
  const status = entry.info.status as RoundStatus;

  // With the key already in this browser the committed forecast is shown before revealing.
  const shown = useMemo(() => {
    if (entry.commitment.revealed) return BigInt(entry.commitment.forecast);
    if (recovered !== undefined) return recovered;
    if (!key) return undefined;
    return recoverCached(ctx, entry.commitment.hash, deriveSalt(key, entry.asset.id, entry.round));
  }, [entry.commitment.hash, entry.commitment.revealed, entry.commitment.forecast, recovered, key]);

  const reveal = () =>
    run(async (wallet) => {
      const key = await obtain();
      const forecast = recoverCached(ctx, entry.commitment.hash, deriveSalt(key, entry.asset.id, entry.round));
      setRecovered(forecast);
      if (forecast === null) {
        throw new Error(
          "This wallet's forecast key does not open the commitment. Commit and reveal from the same wallet.",
        );
      }
      return wallet.writeContract({
        account,
        chain: network.chain,
        address: contracts.registry,
        abi: forecastRegistryAbi,
        functionName: "reveal",
        args: [entry.asset.id, entry.round, forecast, deriveSalt(key, entry.asset.id, entry.round)],
      });
    }, "Forecast revealed.");

  let action;
  if (entry.commitment.revealed) action = <span className="badge ok">Revealed</span>;
  else if (status === RoundStatus.Voided) action = <span className="badge">Round voided</span>;
  else if (revealOpen)
    action = (
      <button className="button primary small" disabled={state.status === "pending"} onClick={reveal}>
        Reveal
      </button>
    );
  else if (now < Number(entry.info.resolveTime))
    action = (
      <span className="muted">
        Reveal in <Countdown to={Number(entry.info.resolveTime)} />
      </span>
    );
  else action = <span className="badge bad">Missed</span>;

  return (
    <tr>
      <td>{entry.asset.symbol}</td>
      <td>{entry.round.toString()}</td>
      <td className="num">{shown === undefined ? "hidden" : shown === null ? "unknown" : formatBps(shown, 1)}</td>
      <td>
        {action}
        <TxStatus state={state} />
      </td>
    </tr>
  );
}

export function Forecast() {
  const now = useNow();
  const { address } = useAccount();
  const protocol = useProtocol();
  const position = usePosition(address);
  const commitments = useCommitments(address, protocol.data?.round);

  if (!address) return <ConnectPrompt what="forecast" />;
  if (!protocol.data || !position.data || !commitments.data) return <Loading />;
  const p = protocol.data;
  const schedule = p.schedule(p.round);
  const open = p.started && now < schedule.commitEnd;
  const committed = new Set(commitments.data.filter((c) => c.round === p.round).map((c) => c.asset.id));
  const enoughVe = position.data.ve >= MIN_VE;

  const nextOpen = p.started ? p.schedule(p.round + 1n).open : p.genesis;

  return (
    <>
      <PageHeader title="Forecast">
        Commit a probability for each asset during the submission window and reveal it after the outcome. Commitments
        use a key derived from a wallet signature, so a forecast can be revealed from any device.
      </PageHeader>

      <div className="grid">
        <Stat
          label="Your veTENAX"
          value={formatToken(position.data.ve)}
          hint={enoughVe ? "Enough to forecast" : <a href="#/lock">5,000 needed: lock TENAX</a>}
        />
        <Stat
          label={open ? "Submissions close in" : p.started ? "Next round opens in" : "Round 0 opens in"}
          value={<Countdown to={open ? schedule.commitEnd : nextOpen} />}
          hint={open ? `Round ${p.round}` : formatTime(nextOpen)}
        />
        <Stat
          label="Reveal window"
          value={`${Math.round(p.revealWindow / 3600)} hours`}
          hint="After each round resolves"
        />
      </div>

      {open && committed.size === p.assets.length ? (
        <Card className="sealed">
          <p>
            <strong>All sealed.</strong> You have committed to every question of round {p.round.toString()}. Come back
            after {formatTime(schedule.resolveTime)} to reveal.
          </p>
        </Card>
      ) : (
        <div className="commit-grid">
          {p.assets
            .filter((a) => !(open && committed.has(a.id)))
            .map((a) => (
              <CommitForm
                key={a.symbol}
                asset={a}
                protocol={p}
                account={address}
                blocked={
                  !open
                    ? `Opens in ${formatDuration(nextOpen - now)}`
                    : !enoughVe
                      ? "Lock 5,000 veTENAX to forecast"
                      : undefined
                }
              />
            ))}
        </div>
      )}
      {!open && (
        <p className="notice">
          Submissions are closed. The next round opens at 00:00 UTC and stays open for{" "}
          {Math.round(p.submissionWindow / 60)} minutes; the form below shows how each answer would be scored.
        </p>
      )}
      {open && !enoughVe && (
        <p className="notice">
          You need at least 5,000 veTENAX to forecast. <a href="#/lock">Lock TENAX</a> first.
        </p>
      )}

      <Card title="Your recent forecasts">
        {commitments.data.length === 0 ? (
          <p className="muted">No forecasts in the last rounds.</p>
        ) : (
          <div className="table-wrap">
            <table className="table">
              <thead>
                <tr>
                  <th>Asset</th>
                  <th>Round</th>
                  <th>Forecast</th>
                  <th>Status</th>
                </tr>
              </thead>
              <tbody>
                {commitments.data
                  .slice()
                  .sort((a, b) => Number(b.round - a.round) || Number(a.asset.id - b.asset.id))
                  .map((c) => (
                    <RevealRow key={`${c.asset.id}-${c.round}`} entry={c} account={address} now={now} />
                  ))}
              </tbody>
            </table>
          </div>
        )}
      </Card>
    </>
  );
}
