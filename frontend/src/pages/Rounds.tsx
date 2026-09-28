import { AssetBadge, Card, Loading, PageHeader } from "../components.js";
import { RoundStatus, useCommitments, useProtocol, useRounds } from "../data.js";
import { useAccount } from "../hooks.js";
import { formatBps, formatFraction, formatTime } from "../lib/format.js";
import { skillOf } from "../lib/stats.js";

const COUNT = 10;

/** Absolute move between two prices as a 1e18 fraction. */
function move(ref: bigint, close: bigint): bigint {
  if (ref === 0n) return 0n;
  const diff = close > ref ? close - ref : ref - close;
  return (diff * 10n ** 18n) / ref;
}

export function Rounds() {
  const { address } = useAccount();
  const protocol = useProtocol();
  const rounds = useRounds(protocol.data?.round, COUNT);
  const mine = useCommitments(address, protocol.data?.round, COUNT);

  if (!protocol.data || !rounds.data) return <Loading />;
  if (!protocol.data.started) {
    return (
      <>
        <PageHeader title="Rounds" />
        <Card>
          <p className="muted">No rounds yet. Round 0 opens at {formatTime(protocol.data.genesis)}.</p>
        </Card>
      </>
    );
  }

  return (
    <>
      <PageHeader title="Rounds">
        The public record of each round: its threshold and base rate, the price move, the outcome and the crowd's
        reputation-weighted forecast.
      </PageHeader>
      {rounds.data.map(({ asset, rounds: list }) => (
        <Card
          key={asset.symbol}
          title={
            <span className="title-with-badge">
              <AssetBadge symbol={asset.symbol} />
              {asset.symbol}/USD
            </span>
          }
          aside={
            <div className="outcome-strip" aria-label="Recent outcomes, oldest first">
              <span className="label">Beyond / within</span>
              {list
                .slice()
                .reverse()
                .map(({ round, info }) => (
                  <span
                    key={round.toString()}
                    title={`Round ${round}`}
                    className={`dot ${
                      info.status === RoundStatus.Resolved
                        ? info.outcome
                          ? "beyond"
                          : "within"
                        : info.status === RoundStatus.Voided
                          ? "void"
                          : "pending"
                    }`}
                  />
                ))}
            </div>
          }
        >
          <div className="table-wrap">
            <table className="table">
              <thead>
                <tr>
                  <th>Round</th>
                  <th>Threshold</th>
                  <th>Base rate</th>
                  <th>Move</th>
                  <th>Outcome</th>
                  <th>Crowd</th>
                  <th>Forecasters</th>
                  {address && <th>You</th>}
                  {address && <th>Skill</th>}
                </tr>
              </thead>
              <tbody>
                {list.map(({ round, info }) => {
                  const status = info.status as RoundStatus;
                  const resolved = status === RoundStatus.Resolved;
                  const crowd = info.weightSum > 0n ? Number(info.weightedForecastSum / info.weightSum) : undefined;
                  const c = mine.data?.find((e) => e.asset.id === asset.id && e.round === round)?.commitment;
                  let you = "-";
                  let skill = "-";
                  if (c) {
                    if (c.revealed) {
                      you = formatBps(c.forecast, 1);
                      if (resolved) skill = skillOf(c.forecast, info.baseRateBps, info.outcome).toFixed(4);
                    } else {
                      you = "hidden";
                      if (resolved && Number(info.revealEnd) * 1000 <= Date.now()) {
                        you = "missed";
                        skill = skillOf(info.outcome ? 0 : 10_000, info.baseRateBps, info.outcome).toFixed(4);
                      }
                    }
                  }
                  return (
                    <tr key={round.toString()}>
                      <td>{round.toString()}</td>
                      <td>{status === RoundStatus.None ? "-" : formatFraction(info.threshold)}</td>
                      <td>{status === RoundStatus.None ? "-" : formatBps(info.baseRateBps, 1)}</td>
                      <td>{resolved ? formatFraction(move(info.refPrice, info.closePrice)) : "-"}</td>
                      <td>
                        {resolved ? (
                          <span className="badge">{info.outcome ? "Beyond" : "Within"}</span>
                        ) : status === RoundStatus.Voided ? (
                          <span className="badge">Voided</span>
                        ) : status === RoundStatus.Open ? (
                          <span className="muted">Pending</span>
                        ) : (
                          <span className="muted">No forecasts</span>
                        )}
                      </td>
                      <td>{crowd !== undefined ? formatBps(crowd, 1) : "-"}</td>
                      <td>
                        {info.reveals}/{info.commitments}
                      </td>
                      {address && <td className="num">{you}</td>}
                      {address && <td className="num">{skill}</td>}
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </Card>
      ))}
      <p className="muted small">
        Crowd is the reputation-weighted mean of revealed forecasts. Skill is the Brier score of the base rate minus
        yours: positive means you beat the base rate. A missed reveal scores as the worst forecast.
      </p>
    </>
  );
}
