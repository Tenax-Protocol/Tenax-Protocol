import { useQuery } from "@tanstack/react-query";
import { useState } from "react";
import { Avatar, Card, Loading, PageHeader } from "../components.js";
import { useAccount } from "../hooks.js";
import { explorerAddress } from "../lib/config.js";
import { shortAddress } from "../lib/format.js";
import { addStats, EMPTY_STATS, meanSkill, passesTests, type Stats, zScore } from "../lib/stats.js";

/** Seasons pooled for the significance test, as ForecastRegistry.ELIGIBILITY_WINDOW. */
const WINDOW = 3;

interface Snapshot {
  network: string;
  block: string;
  updatedAt: string;
  currentSeason: number;
  participants: {
    account: string;
    reputation: string;
    seasons: { season: number; rounds: number; skillSum: string; skillSquares: string; contribution: string }[];
  }[];
}

function toStats(s: Snapshot["participants"][number]["seasons"][number] | undefined): Stats {
  if (!s) return EMPTY_STATS;
  return { rounds: BigInt(s.rounds), skillSum: BigInt(s.skillSum), skillSquares: BigInt(s.skillSquares) };
}

export function Leaderboard() {
  const { address } = useAccount();
  const snapshot = useQuery({
    queryKey: ["snapshot"],
    refetchInterval: 5 * 60_000,
    queryFn: async (): Promise<Snapshot | null> => {
      const response = await fetch(`${import.meta.env.BASE_URL}data/base-sepolia.json`, { cache: "no-cache" });
      if (!response.ok) return null;
      return response.json();
    },
  });
  const [chosen, setChosen] = useState<number | undefined>(undefined);

  const header = (
    <PageHeader title="Leaderboard">
      Rewards go only to forecasters whose skill is significant: at least 20 scored rounds in the season, a mean skill
      of at least 0.003 and z of at least 1.64 over the last {WINDOW} seasons.
    </PageHeader>
  );
  if (snapshot.isLoading) return <Loading />;
  if (!snapshot.data) {
    return (
      <>
        {header}
        <Card>
          <p className="muted">The leaderboard has not been published yet. It refreshes every hour.</p>
        </Card>
      </>
    );
  }
  const data = snapshot.data;
  const season = chosen ?? data.currentSeason;

  const rows = data.participants
    .map((p) => {
      const inSeason = toStats(p.seasons[season]);
      let window = EMPTY_STATS;
      for (let s = Math.max(0, season + 1 - WINDOW); s <= season; s++) window = addStats(window, toStats(p.seasons[s]));
      return {
        account: p.account,
        reputation: Number(p.reputation) / 1e8,
        season: inSeason,
        window,
        z: zScore(window),
        eligible: passesTests(inSeason.rounds, window),
      };
    })
    .filter((r) => r.season.rounds > 0n)
    .sort((a, b) => Number(b.eligible) - Number(a.eligible) || b.z - a.z);

  return (
    <>
      {header}
      <Card
        title={`Season ${season}`}
        aside={
          <select value={season} onChange={(e) => setChosen(Number(e.target.value))} aria-label="Season">
            {Array.from({ length: data.currentSeason + 1 }, (_, s) => data.currentSeason - s).map((s) => (
              <option key={s} value={s}>
                Season {s}
                {s === data.currentSeason ? " (current)" : ""}
              </option>
            ))}
          </select>
        }
      >
        <p className="muted small">Updated {data.updatedAt.slice(0, 16).replace("T", " ")} UTC, every hour.</p>
        {rows.length === 0 ? (
          <p className="muted">No scored forecasts in this season yet.</p>
        ) : (
          <div className="table-wrap">
            <table className="table">
              <thead>
                <tr>
                  <th>#</th>
                  <th>Forecaster</th>
                  <th>Rounds</th>
                  <th>Mean skill</th>
                  <th>z ({WINDOW} seasons)</th>
                  <th>Reputation</th>
                  <th>Eligible</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((r, i) => (
                  <tr
                    key={r.account}
                    className={address && r.account.toLowerCase() === address.toLowerCase() ? "me" : ""}
                  >
                    <td>{i + 1}</td>
                    <td>
                      <a href={explorerAddress(r.account)} target="_blank" rel="noreferrer" className="account">
                        <Avatar address={r.account} />
                        <span className="mono">{shortAddress(r.account)}</span>
                      </a>
                    </td>
                    <td>{r.season.rounds.toString()}</td>
                    <td className="num">{meanSkill(r.window).toFixed(4)}</td>
                    <td>
                      <span className="zcell">
                        <span className="num">{r.z.toFixed(2)}</span>
                        <span className="zbar">
                          <span
                            style={{ width: `${Math.min(100, Math.max(0, (r.z / 3) * 100))}%` }}
                            className={r.z >= 1.64 ? "pass" : ""}
                          />
                          <i style={{ left: `${(1.64 / 3) * 100}%` }} />
                        </span>
                      </span>
                    </td>
                    <td className="num">{r.reputation.toFixed(4)}</td>
                    <td>
                      {r.eligible ? <span className="badge ok">Yes</span> : <span className="badge">Not yet</span>}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </Card>
    </>
  );
}
