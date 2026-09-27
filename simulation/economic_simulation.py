"""Economic simulation of the Tenax launch and its first 36 months.

Models the protocol-owned Uniswap v4 position as a single-sided concentrated
liquidity range from the launch price up to the maximum price, and simulates
daily trading under three demand scenarios with Monte Carlo noise:

- buys pay the 0.3% fee in ETH (revenue), sells pay it in TENAX (burned);
- ETH revenue is split 40 / 40 / 20 between forecasters, veTENAX holders and
  the treasury; the treasury keeps a 90-day keeper reserve and buys back and
  burns TENAX with the surplus, at most 1% price impact per day;
- emissions follow the L1-block epoch schedule and unlock 52 weeks after each
  season; the treasury reserve releases 1/60 per season, pays a season top-up
  that shrinks as forecaster ETH approaches T_ETH, and burns the rest;
- airdrop and creator vesting unlock on their schedules, and a fixed share of
  every unlock is sold.

Demand is an assumption, not a forecast: daily volume is a fraction of the
launch FDV (with a decaying launch spike), and each day has a random buy/sell
imbalance whose mean pulls the price toward the scenario's target multiple of
the launch price, so that unlocks and burns show up as deviations from it. Results scale with the launch FDV, so ETH amounts are reported for
a reference FDV and can be rescaled.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass, replace
from pathlib import Path

import numpy as np
import pandas as pd

DATA_DIR = Path(__file__).parent / "data"
RESULTS_DIR = Path(__file__).parent / "results"


@dataclass(frozen=True)
class Scenario:
    name: str
    turnover: float  # base daily volume as a fraction of launch FDV
    target: float  # price multiple of the launch price that demand pulls toward
    pull: float = 0.1  # strength of the pull toward the target
    noise: float = 0.25  # daily imbalance standard deviation


SCENARIOS = [
    Scenario("Low", turnover=0.005, target=1.0),
    Scenario("Medium", turnover=0.02, target=3.0),
    Scenario("High", turnover=0.05, target=10.0),
]


@dataclass(frozen=True)
class Config:
    fdv_eth: float = 100.0  # launch FDV in ETH
    min_ve: float = 5_000  # veTENAX required to forecast
    days: int = 1080
    runs: int = 300
    seed: int = 11
    total_supply: float = 100e6
    pool_tokens: float = 20e6
    fee: float = 0.003
    forecaster_share: float = 0.4
    holder_share: float = 0.4
    treasury_share: float = 0.2
    season_days: int = 30
    epoch_days: float = 2_628_000 * 12.2 / 86_400  # L1 blocks at ~12.2 s including missed slots
    emission_bucket: float = 35e6
    lock_days: int = 364
    reserve_total: float = 20e6
    reserve_seasons: int = 60
    t_eth: float | None = None  # forecaster ETH per season at which the top-up reaches zero
    keeper_eth_per_day: float = 0.0003
    keeper_reserve_days: int = 90
    buyback_max_impact: float = 0.01
    unlock_sell_fraction: float = 0.5
    unlock_sell_days: int = 30
    airdrop_total: float = 10e6
    airdrop_claim_rate: float = 0.8
    airdrop_choices: tuple = ((182, 0.5, 0.4), (364, 0.75, 0.3), (728, 1.0, 0.3))  # (lock days, fraction, share)
    creator_total: float = 15e6
    creator_start_day: int = 365
    creator_days: int = 730
    creator_sell_fraction: float = 0.25
    hype_multiple: float = 3.0
    hype_days: float = 30.0
    volume_price_elasticity: float = 0.5


def epoch_emissions(bucket: float) -> list[float]:
    factors = [1.0, 0.5, 0.6, 0.7, 0.8] + [0.85] * 60
    emissions, current = [], 0.0
    total_factor = 1 + 0.5 + 0.3 + 0.21 + 0.168 / 0.15
    first = bucket / total_factor
    for i, factor in enumerate(factors):
        current = first if i == 0 else current * factor
        emissions.append(current)
    return emissions


def daily_emissions(config: Config) -> np.ndarray:
    per_epoch = epoch_emissions(config.emission_bucket)
    days = np.arange(config.days)
    epoch = np.floor(days / config.epoch_days).astype(int)
    return np.array([per_epoch[e] / config.epoch_days for e in epoch])


# --- pool math (price p in ETH per TENAX, s = sqrt(p)) -----------------------


def liquidity(config: Config, p0: float) -> float:
    """Liquidity of a TENAX-only range from p0 up to the maximum price."""
    return config.pool_tokens * np.sqrt(p0)


def buy(s, s_floor, liq, eth_in, fee):
    """Swap ETH for TENAX. Returns new sqrt price, tokens out, fee in ETH."""
    net = eth_in * (1 - fee)
    s_new = s + net / liq
    tokens_out = liq * (1 / s - 1 / s_new)
    return s_new, tokens_out, eth_in * fee


def sell(s, s_floor, liq, tokens_in, fee):
    """Swap TENAX for ETH; the pool has no liquidity below the launch price."""
    net = tokens_in * (1 - fee)
    max_net = liq * (1 / s_floor - 1 / s)
    executed = np.minimum(net, max_net)
    s_new = 1 / (1 / s + executed / liq)
    eth_out = liq * (s - s_new)
    fee_tokens = executed * fee / (1 - fee)
    unsold = tokens_in - executed - fee_tokens
    return s_new, eth_out, fee_tokens, unsold


# --- simulation ------------------------------------------------------------


def simulate(config: Config, scenario: Scenario) -> dict[str, np.ndarray]:
    rng = np.random.default_rng(config.seed)
    runs, days = config.runs, config.days
    p0 = config.fdv_eth / config.total_supply
    s_floor = np.sqrt(p0)
    liq = liquidity(config, p0)
    s = np.full(runs, s_floor)

    emissions = daily_emissions(config)
    allowance = config.reserve_total / config.reserve_seasons
    horizon = days + config.lock_days + 800
    unlock_sells = np.zeros((runs, horizon))

    # Airdrop: claimed at launch into locks, a share sold after each unlock.
    airdrop_delivered = 0.0
    for lock_days, fraction, share in config.airdrop_choices:
        amount = config.airdrop_total * config.airdrop_claim_rate * share * fraction
        airdrop_delivered += amount
        per_day = amount * config.unlock_sell_fraction / config.unlock_sell_days
        unlock_sells[:, lock_days : lock_days + config.unlock_sell_days] += per_day
    airdrop_burned = config.airdrop_total - airdrop_delivered

    creator_daily_sell = np.zeros(horizon)
    creator_daily_sell[config.creator_start_day : config.creator_start_day + config.creator_days] = (
        config.creator_total / config.creator_days * config.creator_sell_fraction
    )

    treasury_eth = np.zeros(runs)
    season_forecaster_eth = np.zeros(runs)
    season_emission = 0.0
    burned = {k: np.zeros(runs) for k in ("sell_fees", "buybacks", "reserve")}
    revenue = np.zeros(runs)
    holders_eth = np.zeros(runs)
    topup_total = np.zeros(runs)
    unsold_total = np.zeros(runs)
    history = {k: np.zeros((runs, days)) for k in ("price", "pool_eth", "revenue", "burned")}
    season_eth = []

    for day in range(days):
        price = s**2
        hype = 1 + config.hype_multiple * np.exp(-day / config.hype_days)
        volume = config.fdv_eth * scenario.turnover * hype * (price / p0) ** config.volume_price_elasticity
        mean_imbalance = np.clip(scenario.pull * np.log(scenario.target * p0 / price), -0.3, 0.3)
        imbalance = np.clip(rng.normal(mean_imbalance, scenario.noise), -0.9, 0.9)
        buy_eth = volume * (1 + imbalance) / 2
        sell_eth_equiv = volume * (1 - imbalance) / 2

        # Organic buys, then organic and unlock sells.
        s, _, fee_eth = buy(s, s_floor, liq, buy_eth, config.fee)
        day_revenue = fee_eth
        sell_tokens = sell_eth_equiv / s**2 + unlock_sells[:, day] + creator_daily_sell[day]
        s, _, fee_tokens, unsold = sell(s, s_floor, liq, sell_tokens, config.fee)
        burned["sell_fees"] += fee_tokens
        unsold_total += unsold

        # Treasury: keeper costs, then buyback and burn with the surplus.
        treasury_eth += config.treasury_share * day_revenue
        treasury_eth -= np.minimum(treasury_eth, config.keeper_eth_per_day)
        surplus = np.maximum(treasury_eth - config.keeper_eth_per_day * config.keeper_reserve_days, 0)
        max_buyback = liq * s * (np.sqrt(1 + config.buyback_max_impact) - 1) / (1 - config.fee)
        buyback_eth = np.minimum(surplus, max_buyback)
        s, bought, buyback_fee = buy(s, s_floor, liq, buyback_eth, config.fee)
        treasury_eth -= buyback_eth
        burned["buybacks"] += bought
        day_revenue = day_revenue + buyback_fee

        revenue += day_revenue
        holders_eth += config.holder_share * day_revenue
        season_forecaster_eth += config.forecaster_share * day_revenue
        season_emission += emissions[day]

        # Season close: top-up from the reserve, burn the unused allowance, lock rewards.
        if (day + 1) % config.season_days == 0:
            if config.t_eth is None:
                topup = np.full(runs, allowance)
            else:
                topup = allowance * np.maximum(0, 1 - season_forecaster_eth / config.t_eth)
            burned["reserve"] += allowance - topup
            topup_total += topup
            locked = season_emission + topup
            start = day + 1 + config.lock_days
            per_day = locked * config.unlock_sell_fraction / config.unlock_sell_days
            unlock_sells[:, start : start + config.unlock_sell_days] += per_day[:, None]
            season_eth.append(season_forecaster_eth.copy())
            season_forecaster_eth = np.zeros(runs)
            season_emission = 0.0

        history["price"][:, day] = s**2
        history["pool_eth"][:, day] = liq * (s - s_floor)
        history["revenue"][:, day] = revenue
        history["burned"][:, day] = burned["sell_fees"] + burned["buybacks"] + burned["reserve"] + airdrop_burned

    emitted = emissions.sum()
    return {
        **history,
        "p0": p0,
        "season_eth": np.array(season_eth).T,  # runs x seasons
        "burned_sell": burned["sell_fees"],
        "burned_buyback": burned["buybacks"],
        "burned_reserve": burned["reserve"],
        "burned_airdrop": airdrop_burned,
        "topup": topup_total,
        "holders_eth": holders_eth,
        "emitted": emitted,
        "unsold": unsold_total,
    }


# --- report ----------------------------------------------------------------


def eth_usd() -> float:
    prices = pd.read_csv(DATA_DIR / "ETHUSDT_1d.csv")
    return float(prices["close"].iloc[-1])


def fmt_m(value: float) -> str:
    return f"{value / 1e6:.2f}M"


def q(values: np.ndarray, fmt=lambda v: f"{v:.2f}") -> str:
    p10, p50, p90 = np.percentile(values, [10, 50, 90])
    return f"{fmt(p50)} ({fmt(p10)} to {fmt(p90)})"


def launch_table(config: Config, usd: float) -> list[str]:
    lines = [
        "## Launch price",
        "",
        f"Depth of the single-sided position at launch, for several launch FDVs (ETH at ${usd:,.0f}). "
        "With the range running to the maximum price, depth near the launch price does not depend on the "
        "upper bound, so the launch price is the only range decision.",
        "",
        f"| Launch FDV | Launch price | `minVe` cost ({config.min_ve:,.0f} TENAX locked 2 years / "
        f"{2 * config.min_ve:,.0f} locked 1 year) | Impact of a $500 buy | "
        "Impact of a $5,000 buy | ETH to double the price | Season 1 emissions at launch price |",
        "|---|---|---|---|---|---|---|",
    ]
    season_one = epoch_emissions(config.emission_bucket)[0] / config.epoch_days * config.season_days
    for fdv in (10, 25, 50, 100, 250, 500):
        p0 = fdv / config.total_supply
        depth = config.pool_tokens * p0  # L * sqrt(p0)

        def impact(usd_amount: float) -> float:
            net = usd_amount / usd * (1 - config.fee)
            return (1 + net / depth) ** 2 - 1

        double = depth * (np.sqrt(2) - 1) / (1 - config.fee)
        lines.append(
            f"| {fdv} ETH (${fdv * usd:,.0f}) | {p0:.2e} ETH | "
            f"${config.min_ve * p0 * usd:,.2f} / ${2 * config.min_ve * p0 * usd:,.2f} | "
            f"{impact(500):.1%} | {impact(5000):.1%} | {double:.1f} ETH (${double * usd:,.0f}) | "
            f"${season_one * p0 * usd:,.0f} |"
        )
    lines.append("")
    return lines


def scenario_table(config: Config, results: dict[str, dict], usd: float) -> list[str]:
    checkpoints = [(30, "Month 1"), (180, "Month 6"), (360, "Month 12"), (720, "Month 24"), (config.days - 1, "Month 36")]
    lines = [
        f"## Scenarios (launch FDV {config.fdv_eth:g} ETH, T_ETH = {config.t_eth:.2f} ETH)",
        "",
        "Median across runs, with the 10th and 90th percentiles in parentheses.",
        "",
        "| Scenario | Base daily volume | Demand target |",
        "|---|---|---|",
    ]
    for scenario in SCENARIOS:
        lines.append(f"| {scenario.name} | {scenario.turnover:.1%} of launch FDV | {scenario.target:g}x the launch price |")

    lines += ["", "### Price relative to launch", "", "| Scenario | " + " | ".join(n for _, n in checkpoints) + " |",
              "|---|" + "---|" * len(checkpoints)]
    for scenario in SCENARIOS:
        r = results[scenario.name]
        cells = [q(r["price"][:, d] / r["p0"], lambda v: f"{v:.2f}x") for d, _ in checkpoints]
        lines.append(f"| {scenario.name} | " + " | ".join(cells) + " |")

    lines += ["", "### Cumulative ETH revenue (all fees)", "", "| Scenario | " + " | ".join(n for _, n in checkpoints) + " |",
              "|---|" + "---|" * len(checkpoints)]
    for scenario in SCENARIOS:
        r = results[scenario.name]
        cells = [q(r["revenue"][:, d], lambda v: f"{v:.2f}") for d, _ in checkpoints]
        lines.append(f"| {scenario.name} | " + " | ".join(cells) + " |")

    lines += ["", "### Forecaster ETH per season", "", "| Scenario | Season 3 | Season 6 | Season 12 | Season 24 | Season 36 |",
              "|---|---|---|---|---|---|"]
    for scenario in SCENARIOS:
        se = results[scenario.name]["season_eth"]
        cells = [q(se[:, i - 1], lambda v: f"{v:.3f}") for i in (3, 6, 12, 24, 36)]
        lines.append(f"| {scenario.name} | " + " | ".join(cells) + " |")

    lines += ["", "### Supply after 36 months", "",
              "| Scenario | Burned: sell fees | Burned: buybacks | Burned: unused reserve | Burned: airdrop leftovers | "
              "Reserve used as top-up | Total supply | Unsold at the floor |",
              "|---|---|---|---|---|---|---|---|"]
    for scenario in SCENARIOS:
        r = results[scenario.name]
        burned_total = r["burned_sell"] + r["burned_buyback"] + r["burned_reserve"] + r["burned_airdrop"]
        lines.append(
            f"| {scenario.name} | {q(r['burned_sell'], fmt_m)} | {q(r['burned_buyback'], fmt_m)} | "
            f"{q(r['burned_reserve'], fmt_m)} | {fmt_m(r['burned_airdrop'])} | {q(r['topup'], fmt_m)} | "
            f"{q(config.total_supply - burned_total, fmt_m)} | {q(r['unsold'], fmt_m)} |"
        )
    lines += ["", f"Emitted to forecasters over the period: {fmt_m(results[SCENARIOS[0].name]['emitted'])}. "
              "\"Unsold at the floor\" counts tokens that could not be sold because the pool has no liquidity "
              "below the launch price.", ""]
    return lines


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--fdv", type=float, default=100.0, help="reference launch FDV in ETH")
    parser.add_argument("--output", default=str(RESULTS_DIR / "economic_simulation.md"))
    args = parser.parse_args()
    usd = eth_usd()
    base = Config(fdv_eth=args.fdv)

    # Calibrate T_ETH: median forecaster ETH per season in months 10 to 12 of the medium scenario.
    calibration = simulate(base, next(s for s in SCENARIOS if s.name == "Medium"))
    t_eth = float(np.median(calibration["season_eth"][:, 9:12]))
    config = replace(base, t_eth=t_eth)
    results = {scenario.name: simulate(config, scenario) for scenario in SCENARIOS}

    lines = [
        "# Economic simulation",
        "",
        "Generated by `simulation/economic_simulation.py`. Demand is an assumption, not a forecast: the scenarios "
        "bound plausible outcomes and test the mechanics. ETH amounts scale linearly with the launch FDV.",
        "",
    ]
    lines += launch_table(config, usd)
    lines += [
        "## Revenue target T_ETH",
        "",
        f"T_ETH is set to the median forecaster ETH per season in months 10 to 12 of the medium scenario: "
        f"**{t_eth:.3f} ETH per season** at a {config.fdv_eth:g} ETH launch FDV "
        f"(${t_eth * usd:,.0f}), or {t_eth / config.fdv_eth:.4%} of the launch FDV. "
        "Below it, the reserve tops up season rewards; at or above it, the whole allowance is burned.",
        "",
    ]
    lines += scenario_table(config, results, usd)

    output = Path(args.output)
    output.parent.mkdir(exist_ok=True)
    output.write_text("\n".join(lines), encoding="utf-8")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
