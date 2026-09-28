import { feeDistributorAbi, seasonRewardsAbi } from "@abi";
import { useQuery } from "@tanstack/react-query";
import { Card, ConnectPrompt, Countdown, Loading, PageHeader, Stat, TxStatus } from "../components.js";
import { useSeasons } from "../data.js";
import { useAccount, useNow, useTx } from "../hooks.js";
import { publicClient } from "../lib/client.js";
import { contracts, network } from "../lib/config.js";
import { formatDate, formatEth, formatToken } from "../lib/format.js";

type Season = NonNullable<ReturnType<typeof useSeasons>["data"]>["seasons"][number];

function SeasonRow({ season, now }: { season: Season; now: number }) {
  const { address } = useAccount();
  const { run, state } = useTx();
  const registered = (season.registration?.contribution ?? 0n) > 0n;
  const claimed = season.registration?.claimed ?? false;
  const [tenax, eth] = season.claimable ?? [0n, 0n];
  const registrationOpen = now >= season.registrationStart && now < season.registrationEnd;

  const send = (functionName: "register" | "claim" | "claimAsEth", done: string) =>
    run(
      (wallet) =>
        wallet.writeContract({
          account: address!,
          chain: network.chain,
          address: contracts.seasonRewards,
          abi: seasonRewardsAbi,
          functionName,
          args: functionName === "register" ? [address!, season.season] : [season.season],
        } as never),
      done,
    );

  let status;
  if (now < season.registrationStart) {
    status = (
      <>
        Running. Registration opens in <Countdown to={season.registrationStart} />.{" "}
        {season.eligible ? "You currently pass the tests." : "You do not pass the tests yet."}
      </>
    );
  } else if (registrationOpen) {
    status = registered ? (
      <>
        Registered. The budget is fixed when registration closes, in <Countdown to={season.registrationEnd} />.
      </>
    ) : season.eligible ? (
      <button
        className="button primary small"
        disabled={state.status === "pending"}
        onClick={() => send("register", "Registered.")}
      >
        Register for rewards
      </button>
    ) : (
      <>Not eligible for this season.</>
    );
  } else if (!season.info.closed) {
    status = registered ? <>Registration ended. Waiting for a keeper to close the season.</> : <>Registration ended.</>;
  } else if (!registered) {
    status = <>Closed. {season.info.participants} forecaster(s) shared the rewards.</>;
  } else if (claimed) {
    status = <>Claimed.</>;
  } else {
    status = (
      <div className="actions">
        <span>
          {formatToken(tenax)} TENAX (locked 52 weeks) and {formatEth(eth)}
        </span>
        <button
          className="button primary small"
          disabled={state.status === "pending"}
          onClick={() => send("claimAsEth", "Rewards claimed.")}
        >
          Claim
        </button>
        <button
          className="button small"
          disabled={state.status === "pending"}
          onClick={() => send("claim", "Rewards claimed.")}
        >
          Claim ETH as WETH
        </button>
      </div>
    );
  }

  return (
    <tr>
      <td>{season.season.toString()}</td>
      <td>
        {formatDate(season.registrationStart)} to {formatDate(season.registrationEnd)}
      </td>
      <td>
        {status}
        <TxStatus state={state} />
      </td>
    </tr>
  );
}

function FeeShare() {
  const { address } = useAccount();
  const { run, state } = useTx();
  const claimable = useQuery({
    queryKey: ["fees", address],
    enabled: Boolean(address),
    refetchInterval: 60_000,
    queryFn: () =>
      publicClient.readContract({
        address: contracts.feeDistributor,
        abi: feeDistributorAbi,
        functionName: "claimable",
        args: [address!],
      }),
  });
  return (
    <Card title="Revenue share">
      <p className="muted">
        40% of the protocol's ETH revenue goes to veTENAX holders every week, in proportion to their veTENAX at the
        start of the week. A week can be claimed once it ends.
      </p>
      <div className="grid">
        <Stat label="Claimable" value={claimable.data !== undefined ? formatEth(claimable.data) : "..."} />
      </div>
      <button
        className="button primary"
        disabled={!claimable.data || state.status === "pending"}
        onClick={() =>
          run(
            (wallet) =>
              wallet.writeContract({
                account: address!,
                chain: network.chain,
                address: contracts.feeDistributor,
                abi: feeDistributorAbi,
                functionName: "claimAsEth",
              }),
            "Revenue claimed.",
          )
        }
      >
        Claim ETH
      </button>
      <TxStatus state={state} />
    </Card>
  );
}

export function Rewards() {
  const now = useNow();
  const { address } = useAccount();
  const seasons = useSeasons(address);
  if (!address) return <ConnectPrompt what="see your rewards" />;
  if (!seasons.data) return <Loading />;

  return (
    <>
      <PageHeader title="Rewards">
        Each season lasts 30 days. Once its rounds are scored, eligible forecasters have 7 days to register; then the
        season's TENAX emissions and ETH are split in proportion to each one's skill. TENAX rewards arrive in a 52-week
        lock.
      </PageHeader>
      <Card title="Seasons">
        <div className="table-wrap">
          <table className="table">
            <thead>
              <tr>
                <th>Season</th>
                <th>Registration</th>
                <th>Status</th>
              </tr>
            </thead>
            <tbody>
              {seasons.data.seasons.map((s) => (
                <SeasonRow key={s.season.toString()} season={s} now={now} />
              ))}
            </tbody>
          </table>
        </div>
      </Card>
      <FeeShare />
    </>
  );
}
