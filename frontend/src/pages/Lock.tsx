import { votingEscrowAbi } from "@abi";
import { useState } from "react";
import { erc20Abi, formatUnits, parseEther } from "viem";
import { Card, ConnectPrompt, Loading, PageHeader, Stat, TxStatus } from "../components.js";
import { type Position, usePosition } from "../data.js";
import { useAccount, useNow, useTx } from "../hooks.js";
import { contracts, DAY, MAX_LOCK, MIN_VE, network, WEEK } from "../lib/config.js";
import { amountForVe, earlyExitPenalty, roundDownToWeek, veBalance } from "../lib/escrow.js";
import { formatDate, formatToken } from "../lib/format.js";

/** How long the suggested amount keeps 5,000 veTENAX: a whole test season with room to spare. */
const HORIZON = 60 * DAY;

const DURATIONS = [
  { label: "6 months", seconds: 26 * WEEK },
  { label: "1 year", seconds: 52 * WEEK },
  { label: "2 years", seconds: MAX_LOCK },
];

function parseAmount(text: string): bigint | null {
  try {
    const value = parseEther(text.trim() || "0");
    return value > 0n ? value : null;
  } catch {
    return null;
  }
}

/** Last time at which a lock still holds 5,000 veTENAX. */
function forecastingUntil(amount: bigint, end: number): number {
  const slope = amount / BigInt(MAX_LOCK);
  if (slope === 0n) return 0;
  return end - Number((MIN_VE + slope - 1n) / slope);
}

function DecayChart({ amount, end, now }: { amount: bigint; end: number; now: number }) {
  const width = 640;
  const height = 220;
  const pad = { l: 8, r: 8, t: 20, b: 28 };
  const start = veBalance(amount, end, now);
  if (start === 0n || end <= now) return null;
  const top = Math.max(Number(formatUnits(start, 18)), Number(formatUnits(MIN_VE, 18)) * 1.25);
  const min = Number(formatUnits(MIN_VE, 18));
  const x = (t: number) => pad.l + ((t - now) / (end - now)) * (width - pad.l - pad.r);
  const y = (value: number) => pad.t + (1 - value / top) * (height - pad.t - pad.b);
  const startY = y(Number(formatUnits(start, 18)));
  const baseY = y(0);
  const cutoff = forecastingUntil(amount, end);
  const showCutoff = cutoff > now && cutoff < end;
  return (
    <svg className="chart" viewBox={`0 0 ${width} ${height}`} role="img" aria-label="veTENAX over time">
      <path d={`M${x(now)} ${startY} L${x(end)} ${baseY} L${x(now)} ${baseY} Z`} className="chart-area" />
      <line x1={x(now)} y1={startY} x2={x(end)} y2={baseY} className="chart-line" />
      <line x1={pad.l} y1={y(min)} x2={width - pad.r} y2={y(min)} className="chart-threshold" />
      <text x={width - pad.r} y={y(min) - 6} textAnchor="end" className="chart-label">
        5,000 veTENAX to forecast
      </text>
      {showCutoff && (
        <>
          <line x1={x(cutoff)} y1={pad.t} x2={x(cutoff)} y2={baseY} className="chart-marker" />
          <circle cx={x(cutoff)} cy={y(min)} r={4} className="chart-dot" />
          <text x={x(cutoff) + 6} y={pad.t + 10} className="chart-label">
            forecast until {formatDate(cutoff)}
          </text>
        </>
      )}
      <circle cx={x(now)} cy={startY} r={5} className="chart-dot" />
      <text x={pad.l} y={height - 8} className="chart-label">
        Today
      </text>
      <text x={width - pad.r} y={height - 8} textAnchor="end" className="chart-label">
        Unlock {formatDate(end)}
      </text>
    </svg>
  );
}

/** A token amount rounded up to a whole token, as input text. */
const wholeUp = (value: bigint) =>
  formatUnits(value % 10n ** 18n === 0n ? value : value + 10n ** 18n - (value % 10n ** 18n), 18);

function NewLock({ position, now }: { position: Position; now: number }) {
  const [duration, setDuration] = useState(MAX_LOCK);
  const end = roundDownToWeek(now + duration);
  const suggested = amountForVe(MIN_VE, end, now + HORIZON);
  const [text, setText] = useState(() => wholeUp(suggested));
  const amount = parseAmount(text);
  const { run, state } = useTx();
  const needsApproval = amount !== null && position.allowance < amount;
  const tooMuch = amount !== null && amount > position.tenax;

  const choose = (seconds: number) => {
    setDuration(seconds);
    const newEnd = roundDownToWeek(now + seconds);
    setText(wholeUp(amountForVe(MIN_VE, newEnd, now + HORIZON)));
  };

  return (
    <>
      <PageHeader title="Lock TENAX">
        veTENAX is required to forecast and earns a share of protocol revenue. It decays linearly until the unlock date,
        so the amount locked should keep it above 5,000 for as long as you intend to forecast.
      </PageHeader>
      <div className="split">
        <section className="card">
          <div className="field">
            <span>Lock duration</span>
            <div className="segmented" role="radiogroup" aria-label="Lock duration">
              {DURATIONS.map((d) => (
                <button
                  key={d.seconds}
                  role="radio"
                  aria-checked={duration === d.seconds}
                  className={duration === d.seconds ? "active" : ""}
                  onClick={() => choose(d.seconds)}
                >
                  {d.label}
                </button>
              ))}
            </div>
          </div>
          <div className="field">
            <span>
              TENAX to lock <span className="muted">(balance {formatToken(position.tenax)})</span>
            </span>
            <div className="input-token">
              <input
                inputMode="decimal"
                value={text}
                onChange={(e) => setText(e.target.value)}
                aria-label="TENAX to lock"
              />
              <button className="preset" onClick={() => setText(wholeUp(suggested))}>
                Suggested
              </button>
            </div>
            <span className="muted small">
              {formatToken(suggested)} TENAX keeps 5,000 veTENAX for 60 days with this duration.
            </span>
          </div>
          <ol className="stepper">
            <li className={needsApproval ? "current" : "done"}>Approve TENAX</li>
            <li className={needsApproval ? "" : "current"}>Create the lock</li>
          </ol>
          {needsApproval ? (
            <button
              className="button primary large block"
              disabled={state.status === "pending" || tooMuch}
              onClick={() =>
                run(
                  (wallet) =>
                    wallet.writeContract({
                      account: wallet.account!,
                      chain: network.chain,
                      address: contracts.token,
                      abi: erc20Abi,
                      functionName: "approve",
                      args: [contracts.escrow, amount!],
                    }),
                  "Approved. Now create the lock.",
                )
              }
            >
              {tooMuch ? "Not enough TENAX" : "Approve TENAX"}
            </button>
          ) : (
            <button
              className="button primary large block"
              disabled={amount === null || tooMuch || state.status === "pending"}
              onClick={() =>
                run(
                  (wallet) =>
                    wallet.writeContract({
                      account: wallet.account!,
                      chain: network.chain,
                      address: contracts.escrow,
                      abi: votingEscrowAbi,
                      functionName: "createLock",
                      args: [amount!, BigInt(end)],
                    }),
                  "Lock created. You can forecast now.",
                )
              }
            >
              {tooMuch ? "Not enough TENAX" : "Create lock"}
            </button>
          )}
          {tooMuch && (
            <p className="muted small">
              <a href="#/buy">Buy TENAX</a> first.
            </p>
          )}
          <TxStatus state={state} />
        </section>
        <section className="card preview">
          <div className="label">veTENAX at creation</div>
          <div className="big-number">
            {amount !== null ? formatToken(veBalance(amount, end, now), 0) : "0"}
            <span>veTENAX</span>
          </div>
          {amount !== null && <DecayChart amount={amount} end={end} now={now} />}
          <div className="grid tight">
            <Stat label="Unlocks on" value={formatDate(end)} />
            <Stat
              label="Forecast until"
              value={
                amount !== null && forecastingUntil(amount, end) > now ? formatDate(forecastingUntil(amount, end)) : "-"
              }
            />
          </div>
        </section>
      </div>
    </>
  );
}

function ExistingLock({ position, now }: { position: Position; now: number }) {
  const { amount, granted, end } = position.lock;
  const voluntary = amount - granted;
  const expired = end <= now;
  const [text, setText] = useState("");
  const extra = parseAmount(text);
  const [confirmExit, setConfirmExit] = useState(false);
  const { run, state } = useTx();
  const maxEnd = roundDownToWeek(now + MAX_LOCK);
  const penalty = earlyExitPenalty(voluntary, end - now);

  const write = (
    functionName: "increaseAmount" | "increaseUnlockTime" | "withdraw" | "withdrawEarly",
    args: bigint[],
    done: string,
  ) =>
    run(
      (wallet) =>
        wallet.writeContract({
          account: wallet.account!,
          chain: network.chain,
          address: contracts.escrow,
          abi: votingEscrowAbi,
          functionName,
          args,
        } as never),
      done,
    );

  return (
    <>
      <PageHeader title="Your lock">Extend the lock or add TENAX to increase your veTENAX.</PageHeader>
      <div className="split">
        <section className="card preview">
          <div className="label">Current balance</div>
          <div className="big-number">
            {formatToken(position.ve, 0)}
            <span>veTENAX</span>
          </div>
          <div className="grid tight">
            <Stat
              label="Locked"
              value={`${formatToken(amount, 0)} TENAX`}
              hint={`${formatToken(voluntary, 0)} yours, ${formatToken(granted, 0)} from rewards`}
            />
            <Stat label="Unlocks on" value={formatDate(end)} />
          </div>
        </section>
        <section className="card preview">
          <div className="label">Eligible to forecast until</div>
          <div className="big-number">
            {forecastingUntil(amount, end) > now ? formatDate(forecastingUntil(amount, end)) : "Paused"}
            <span>
              {forecastingUntil(amount, end) > now
                ? "last day above 5,000 veTENAX"
                : "below 5,000 veTENAX: extend or add TENAX"}
            </span>
          </div>
          {!expired && <DecayChart amount={amount} end={end} now={now} />}
        </section>
      </div>

      {expired ? (
        <Card title="Withdraw">
          <p>Your lock has expired. Withdraw it to get your TENAX back.</p>
          <button className="button primary" onClick={() => write("withdraw", [], "Withdrawn.")}>
            Withdraw {formatToken(amount)} TENAX
          </button>
        </Card>
      ) : (
        <div className="split">
          <Card title="Keep forecasting">
            <p className="muted">
              Extending to the maximum restores your veTENAX; adding TENAX raises it. Both keep the same single lock.
            </p>
            <div className="actions">
              <button
                className="button"
                disabled={maxEnd <= end || state.status === "pending"}
                onClick={() => write("increaseUnlockTime", [BigInt(maxEnd)], "Lock extended.")}
              >
                {maxEnd <= end ? "Already at the maximum" : `Extend to ${formatDate(maxEnd)}`}
              </button>
            </div>
            <label className="field">
              <span>Add TENAX</span>
              <input inputMode="decimal" placeholder="0.0" value={text} onChange={(e) => setText(e.target.value)} />
            </label>
            {extra !== null && position.allowance < extra ? (
              <button
                className="button"
                disabled={extra > position.tenax}
                onClick={() =>
                  run(
                    (wallet) =>
                      wallet.writeContract({
                        account: wallet.account!,
                        chain: network.chain,
                        address: contracts.token,
                        abi: erc20Abi,
                        functionName: "approve",
                        args: [contracts.escrow, extra],
                      }),
                    "Approved. Now add it to the lock.",
                  )
                }
              >
                Approve TENAX
              </button>
            ) : (
              <button
                className="button"
                disabled={extra === null || extra > position.tenax || state.status === "pending"}
                onClick={() => write("increaseAmount", [extra!], "TENAX added to the lock.")}
              >
                Add to lock
              </button>
            )}
          </Card>

          <Card title="Exit early">
            {voluntary === 0n ? (
              <p className="muted">
                Only TENAX you locked yourself can exit early. Rewards stay locked until they unlock.
              </p>
            ) : (
              <>
                <p>
                  You can withdraw the {formatToken(voluntary)} TENAX you locked yourself now, burning a penalty of{" "}
                  <strong>{formatToken(penalty)} TENAX</strong> (
                  {((Number(penalty) / Number(voluntary)) * 100).toFixed(1)}%). You would receive{" "}
                  {formatToken(voluntary - penalty)} TENAX
                  {granted > 0n ? ", and the rewards part stays locked until the same date" : ""}.
                </p>
                <label className="check">
                  <input type="checkbox" checked={confirmExit} onChange={(e) => setConfirmExit(e.target.checked)} />I
                  understand the penalty is burned and cannot be recovered.
                </label>
                <button
                  className="button danger"
                  disabled={!confirmExit || state.status === "pending"}
                  onClick={() => write("withdrawEarly", [], "Exited early.")}
                >
                  Exit early
                </button>
              </>
            )}
          </Card>
        </div>
      )}
      <TxStatus state={state} />
    </>
  );
}

export function Lock() {
  const now = useNow();
  const { address } = useAccount();
  const position = usePosition(address);
  if (!address) return <ConnectPrompt what="lock TENAX" />;
  if (!position.data) return <Loading />;
  return position.data.lock.amount === 0n ? (
    <NewLock position={position.data} now={now} />
  ) : (
    <ExistingLock position={position.data} now={now} />
  );
}
