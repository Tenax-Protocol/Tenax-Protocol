import { AssetBadge, Card, Countdown, Loading, Meter, Stat } from "../components.js";
import { type Protocol, RoundStatus, useCommitments, usePosition, useProtocol } from "../data.js";
import { useAccount, useNow } from "../hooks.js";
import { MIN_VE, network } from "../lib/config.js";
import { toBps } from "../lib/forecast.js";
import { formatBps, formatEth, formatFraction, formatTime, formatToken } from "../lib/format.js";

const WHITEPAPER = "https://github.com/Tenax-Protocol/Tenax-Protocol/blob/main/docs/WHITEPAPER.md";

type Phase = { kind: "before" | "open" | "closed"; label: string; to: number };

function phaseOf(p: Protocol, now: number): Phase {
  if (!p.started) return { kind: "before", label: "Round 0 opens in", to: p.genesis };
  const s = p.schedule(p.round);
  if (now < s.commitEnd) return { kind: "open", label: "Submissions close in", to: s.commitEnd };
  return { kind: "closed", label: "Next round opens in", to: p.schedule(p.round + 1n).open };
}

function RoundPanel({ protocol, phase }: { protocol: Protocol; phase: Phase }) {
  const round = protocol.started ? protocol.round : 0n;
  const s = protocol.schedule(round);
  return (
    <Card
      title={`Round ${round}`}
      aside={
        <span className={`status${phase.kind === "open" ? " open" : ""}`}>
          {phase.kind === "open"
            ? "Accepting forecasts"
            : phase.kind === "closed"
              ? "Submissions closed"
              : "Not started"}
        </span>
      }
    >
      <div className="label">{phase.label}</div>
      <div className="countdown">
        <Countdown to={phase.to} />
      </div>
      <dl className="rows" style={{ marginTop: "1rem" }}>
        <div>
          <dt>Submissions open</dt>
          <dd>{formatTime(s.open)}</dd>
        </div>
        <div>
          <dt>Submissions close</dt>
          <dd>{formatTime(s.commitEnd)}</dd>
        </div>
        <div>
          <dt>Outcome measured</dt>
          <dd>{formatTime(s.resolveTime)}</dd>
        </div>
        <div>
          <dt>Reveal deadline</dt>
          <dd>{formatTime(s.revealEnd)}</dd>
        </div>
      </dl>
    </Card>
  );
}

function QuestionCard({ asset, phase }: { asset: Protocol["assets"][number]; phase: Phase }) {
  const opened = asset.current.status !== RoundStatus.None;
  const threshold = opened ? asset.current.threshold : asset.state.threshold;
  const baseRate = opened ? asset.current.baseRateBps : toBps(asset.state.baseRate);
  return (
    <Card>
      <div className="question-head">
        <AssetBadge symbol={asset.symbol} />
        <div className="question-asset">{asset.symbol}/USD</div>
        <span className={`status${phase.kind === "open" ? " open" : ""}`}>
          {phase.kind === "open" ? "Open" : phase.kind === "closed" ? "Closed" : "Upcoming"}
        </span>
      </div>
      <p className="question-text">
        Will {asset.name} move more than <strong>&plusmn;{formatFraction(threshold)}</strong> over the 24-hour horizon?
      </p>
      <div className="meter-row">
        <span className="muted">Base rate</span>
        <span>{formatBps(baseRate, 1)}</span>
      </div>
      <Meter value={baseRate / 10_000} label="Base rate" />
      <div className="card-foot">
        <span className="muted small">
          {opened
            ? `${asset.current.commitments} forecast${asset.current.commitments === 1 ? "" : "s"} committed`
            : "Threshold and base rate are updated daily"}
        </span>
        {phase.kind === "open" && (
          <a className="button primary small" href="#/forecast">
            Forecast
          </a>
        )}
      </div>
    </Card>
  );
}

export function Overview() {
  const now = useNow();
  const { address } = useAccount();
  const protocol = useProtocol();
  const position = usePosition(address);
  const commitments = useCommitments(address, protocol.data?.round);

  if (!protocol.data) return <Loading />;
  const p = protocol.data;
  const phase = phaseOf(p, now);
  const toReveal = (commitments.data ?? []).filter((c) => {
    const s = p.schedule(c.round);
    return !c.commitment.revealed && now >= s.resolveTime && now < s.revealEnd;
  }).length;

  return (
    <>
      <section className="intro">
        <div>
          <h1>Crypto volatility forecasts, scored on chain</h1>
          <p className="lead">
            Each day, Tenax asks whether BTC and ETH will move beyond an adaptive threshold over the next 24 hours.
            Participants lock TENAX, commit a probability, reveal it after the outcome and are scored with the Brier
            score. Rewards go only to forecasters whose skill is statistically significant.
          </p>
          <div className="actions">
            <a className="button primary large" href="#/forecast">
              Submit a forecast
            </a>
            <a className="button large" href={WHITEPAPER} target="_blank" rel="noreferrer">
              Read the whitepaper
            </a>
          </div>
        </div>
        <RoundPanel protocol={p} phase={phase} />
      </section>

      <section className="section">
        <h2>Today's questions</h2>
        <div className="two">
          {p.assets.map((a) => (
            <QuestionCard key={a.symbol} asset={a} phase={phase} />
          ))}
        </div>
      </section>

      {address && position.data && (
        <section className="section">
          <h2>Your position</h2>
          <div className="grid">
            <Stat label="ETH" value={formatEth(position.data.eth)} />
            <Stat label="TENAX" value={formatToken(position.data.tenax)} />
            <Stat
              label="veTENAX"
              value={formatToken(position.data.ve)}
              hint={position.data.ve >= MIN_VE ? "Eligible to forecast" : <a href="#/lock">5,000 required</a>}
            />
            <Stat
              label="Forecasts to reveal"
              value={toReveal}
              hint={toReveal > 0 ? <a href="#/forecast">Reveal now</a> : "None pending"}
            />
          </div>
        </section>
      )}

      <section className="section">
        <h2>How it works</h2>
        <ol className="steps">
          <li>
            <strong>Lock</strong>
            <span>Lock TENAX for up to two years. At least 5,000 veTENAX are required to forecast.</span>
          </li>
          <li>
            <strong>Commit</strong>
            <span>
              Between 00:00 and 00:{String(Math.round(p.submissionWindow / 60)).padStart(2, "0")} UTC, submit a
              probability for each asset. It stays hidden until you reveal it.
            </span>
          </li>
          <li>
            <strong>Reveal</strong>
            <span>
              After the outcome, reveal within {Math.round(p.revealWindow / 3600)} hours. Unrevealed forecasts score as
              the worst possible answer.
            </span>
          </li>
          <li>
            <strong>Earn</strong>
            <span>Each 30-day season, significant skill is paid in locked TENAX and in ETH from pool fees.</span>
          </li>
        </ol>
      </section>

      <section className="section two">
        <Card title="Protocol parameters">
          <dl className="rows">
            <div>
              <dt>TENAX supply</dt>
              <dd>100,000,000, fixed</dd>
            </div>
            <div>
              <dt>Revenue split</dt>
              <dd>40% forecasters, 40% veTENAX, 20% treasury</dd>
            </div>
            <div>
              <dt>Pool fee</dt>
              <dd>{formatBps(p.launchFee / 100, 2)}</dd>
            </div>
            <div>
              <dt>Reward eligibility</dt>
              <dd>20 rounds, mean skill 0.003, z &ge; 1.64</dd>
            </div>
            <div>
              <dt>Reward lock</dt>
              <dd>52 weeks</dd>
            </div>
            <div>
              <dt>Maximum lock</dt>
              <dd>104 weeks</dd>
            </div>
          </dl>
        </Card>
        <Card title="Getting started on the testnet">
          <ol className="checklist">
            <li>
              Get {network.chain.name} ETH from the{" "}
              <a href="https://console.optimism.io/faucet" target="_blank" rel="noreferrer">
                Superchain faucet
              </a>{" "}
              or the{" "}
              <a href="https://portal.cdp.coinbase.com/products/faucet" target="_blank" rel="noreferrer">
                Coinbase faucet
              </a>
              .
            </li>
            <li>
              <a href="#/buy">Buy TENAX</a> in the protocol's pool.
            </li>
            <li>
              <a href="#/lock">Lock TENAX</a> for at least 5,000 veTENAX.
            </li>
            <li>
              <a href="#/forecast">Forecast</a> daily in the submission window.
            </li>
            <li>
              Reveal each forecast, then <a href="#/rewards">register and claim</a> at the end of the season.
            </li>
          </ol>
        </Card>
      </section>
    </>
  );
}
