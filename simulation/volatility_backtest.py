"""Backtest of the v1 forecasting question on historical BTC and ETH prices.

Replays the round rules from the whitepaper on daily closes:

- one round per asset per day, asking whether the absolute 24 h move exceeds X;
- X and the base rate b are exponential moving averages (factors beta and gamma),
  fixed when a round opens; a round opens before the previous one resolves,
  so the state used by round d includes outcomes up to round d - 2;
- a season (30 days, both assets) is eligible when n >= 20,
  z = sum(S) / sqrt(sum(S^2)) >= 1.64 and, in the proposed rules, the mean
  skill per round is at least a minimum floor.

Two skill definitions are compared:

- "expected": S = b(1 - b) - (p - o)^2, as first written in the whitepaper;
- "reference": S = (b - o)^2 - (p - o)^2, the Brier skill against the realized
  score of the base-rate forecast, under which always answering b scores zero
  (b is stored in basis points, like forecasts).

Forecasters only use information available before submission: returns up to
round d - 2, since the return of round d - 1 ends at the reference price time.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass, replace
from pathlib import Path

import numpy as np
import pandas as pd
from scipy.stats import norm

DATA_DIR = Path(__file__).parent / "data"
RESULTS_DIR = Path(__file__).parent / "results"
ASSETS = {"BTC": "BTCUSDT", "ETH": "ETHUSDT"}


@dataclass(frozen=True)
class Params:
    skill_mode: str = "reference"  # "expected" or "reference"
    beta: float = 1 / 30  # threshold EMA factor
    gamma: float = 1 / 365  # base rate EMA factor
    initial_base_rate: float | None = None  # None: historical event frequency before the start
    init_days: int = 365  # days before the start used to set the initial X and b, never scored
    warmup_rounds: int = 90  # rounds per asset discarded before scoring
    season_days: int = 30
    min_rounds: int = 20
    z_min: float = 1.64
    min_mean_skill: float = 0.003  # eligibility floor on sum(S) / n
    base_rate_bps: bool = True  # store b in basis points when a round opens
    weight_k: float = 50  # reputation weight factor, weights capped at 2
    ema_alpha: float = 1 / 32  # reputation EMA factor
    ewma_lambda: float = 0.94  # RiskMetrics variance decay
    refit_every: int = 30  # days between refits of the calibrated model
    min_train_rows: int = 365
    null_trials: int = 1000
    seed: int = 7


WHITEPAPER_V1 = Params(skill_mode="expected", beta=1 / 30, gamma=1 / 30, initial_base_rate=0.5, init_days=30,
                       min_mean_skill=0.0, base_rate_bps=False)
PROPOSED = Params()


# --- protocol replay -------------------------------------------------------


def load_returns(symbol: str) -> pd.Series:
    prices = pd.read_csv(DATA_DIR / f"{symbol}_1d.csv", parse_dates=["date"], index_col="date")
    return prices["close"].pct_change().dropna()


def initial_state(history: pd.Series, params: Params) -> tuple[float, float]:
    """Initial X and b as they would be computed at deployment from past prices."""
    threshold = history.abs().mean()
    if params.initial_base_rate is not None:
        return threshold, params.initial_base_rate
    # Replay the threshold over the history to measure how often it was exceeded.
    x, hits = history.iloc[:30].abs().mean(), []
    for ret in history.iloc[30:]:
        hits.append(abs(ret) > x)
        x += params.beta * (abs(ret) - x)
    return threshold if params.init_days <= 30 else x, float(np.mean(hits))


def replay_rounds(returns: pd.Series, params: Params) -> pd.DataFrame:
    """Apply the threshold and base rate rules round by round."""
    threshold, base_rate = initial_state(returns.iloc[: params.init_days], params)
    pending: tuple[float, int] | None = None
    rows = []

    for date, ret in returns.iloc[params.init_days :].items():
        used_threshold = threshold
        used_base_rate = round(base_rate * 10_000) / 10_000 if params.base_rate_bps else base_rate
        outcome = int(abs(ret) > used_threshold)
        rows.append((date, ret, used_threshold, used_base_rate, outcome))
        # The previous round resolves after this one opened.
        if pending is not None:
            abs_ret, prev_outcome = pending
            threshold += params.beta * (abs_ret - threshold)
            base_rate += params.gamma * (prev_outcome - base_rate)
        pending = (abs(ret), outcome)

    frame = pd.DataFrame(rows, columns=["date", "ret", "threshold", "base_rate", "outcome"])
    frame["round"] = np.arange(len(frame))
    return frame


def ewma_sigma(returns: pd.Series, decay: float, dates: pd.Series) -> np.ndarray:
    """EWMA volatility using returns known at submission time (up to round d - 2)."""
    variance = (returns**2).shift(2).ewm(alpha=1 - decay, adjust=False).mean()
    return np.sqrt(variance.reindex(dates).to_numpy())


def add_features(frame: pd.DataFrame, returns: pd.Series, params: Params) -> pd.DataFrame:
    """Slow and fast EWMA volatility, plus a weekend flag."""
    frame = frame.copy()
    frame["sigma"] = ewma_sigma(returns, params.ewma_lambda, frame["date"])
    frame["sigma_fast"] = ewma_sigma(returns, 0.80, frame["date"])
    frame["weekend"] = (frame["date"].dt.dayofweek >= 5).astype(float)
    return frame


# --- forecasters -----------------------------------------------------------


def forecast_normal(frame: pd.DataFrame) -> np.ndarray:
    """P(|r| > X) if returns were normal with the EWMA volatility."""
    return np.asarray(2 * norm.sf(frame["threshold"] / frame["sigma"]), dtype=float)


def fit_logistic(features: np.ndarray, target: np.ndarray, ridge: float = 1e-3) -> np.ndarray:
    weights = np.zeros(features.shape[1])
    for _ in range(100):
        prob = 1 / (1 + np.exp(-features @ weights))
        gradient = features.T @ (prob - target) + ridge * weights
        hessian = (features.T * (prob * (1 - prob))) @ features + ridge * np.eye(len(weights))
        step = np.linalg.solve(hessian, gradient)
        weights -= step
        if np.max(np.abs(step)) < 1e-10:
            break
    return weights


def logistic_features(frame: pd.DataFrame) -> np.ndarray:
    return np.column_stack(
        [
            np.ones(len(frame)),
            np.log(frame["threshold"] / frame["sigma"]),
            np.log(frame["threshold"] / frame["sigma_fast"]),
            frame["weekend"],
        ]
    )


def forecast_calibrated(rounds: pd.DataFrame, params: Params) -> np.ndarray:
    """Walk-forward logistic model on volatility ratios and a weekend flag.

    Refits every `refit_every` days on rounds already resolved (two days of lag)
    and falls back to the normal model until enough history exists.
    """
    features = logistic_features(rounds)
    forecast = forecast_normal(rounds).copy()
    dates = rounds["date"]
    refit_dates = pd.date_range(dates.min(), dates.max() + pd.Timedelta(days=1), freq=f"{params.refit_every}D")

    for start, end in zip(refit_dates[:-1], refit_dates[1:]):
        train = (dates <= start - pd.Timedelta(days=2)).to_numpy()
        target_rows = ((dates >= start) & (dates < end)).to_numpy()
        if train.sum() < params.min_train_rows or not target_rows.any():
            continue
        weights = fit_logistic(features[train], rounds["outcome"].to_numpy()[train])
        forecast[target_rows] = 1 / (1 + np.exp(-features[target_rows] @ weights))

    return forecast


# --- scoring ---------------------------------------------------------------


def skill(prob: np.ndarray, outcome: np.ndarray, base_rate: np.ndarray, mode: str) -> np.ndarray:
    prob = np.round(np.clip(prob, 0, 1) * 10_000) / 10_000  # forecasts are in basis points
    if mode == "expected":
        return base_rate * (1 - base_rate) - (prob - outcome) ** 2
    return (base_rate - outcome) ** 2 - (prob - outcome) ** 2


def season_stats(season: np.ndarray, scores: np.ndarray, params: Params) -> pd.DataFrame:
    n = np.bincount(season)
    total = np.bincount(season, weights=scores)
    total_sq = np.bincount(season, weights=scores**2)
    z = np.divide(total, np.sqrt(total_sq), out=np.zeros_like(total), where=total_sq > 0)
    eligible = (n >= params.min_rounds) & (z >= params.z_min) & (total >= params.min_mean_skill * n)
    frame = pd.DataFrame({"n": n, "sum_skill": total, "sum_sq": total_sq, "z": z, "eligible": eligible})
    return frame[frame["n"] > 0]


def pass_rate(season: np.ndarray, scores: np.ndarray, params: Params) -> float:
    return float(season_stats(season, scores, params)["eligible"].mean())


def rolling_pass_rate(season: np.ndarray, scores: np.ndarray, params: Params, window: int) -> float:
    stats = season_stats(season, scores, params)
    sums = stats["sum_skill"].rolling(window).sum()
    squares = stats["sum_sq"].rolling(window).sum()
    rounds = stats["n"].rolling(window).sum()
    eligible = ((sums / np.sqrt(squares)) >= params.z_min) & (sums >= params.min_mean_skill * rounds)
    return float(eligible[window - 1 :].mean())


def expected_sum_skill(season: np.ndarray, scores: np.ndarray, params: Params) -> float:
    """Average sum of skill per season counting only eligible seasons: a proxy for reward share."""
    stats = season_stats(season, scores, params)
    return float((stats["sum_skill"] * stats["eligible"]).mean())


# --- evaluation ------------------------------------------------------------


@dataclass
class Scored:
    frame: pd.DataFrame
    season: np.ndarray
    outcome: np.ndarray
    base_rate: np.ndarray

    def scores(self, prob: np.ndarray, params: Params) -> np.ndarray:
        return skill(prob, self.outcome, self.base_rate, params.skill_mode)


def build_rounds(params: Params) -> Scored:
    """Replay both assets, add forecasts and keep scored rounds in full seasons."""
    frames = []
    for asset, symbol in ASSETS.items():
        returns = load_returns(symbol)
        frame = add_features(replay_rounds(returns, params), returns, params)
        frame["asset"] = asset
        frames.append(frame)
    rounds = pd.concat(frames, ignore_index=True).sort_values(["date", "asset"], ignore_index=True)
    rounds["p_normal"] = forecast_normal(rounds)
    rounds["p_calibrated"] = forecast_calibrated(rounds, params)

    scored = rounds[rounds["round"] >= params.warmup_rounds].copy()
    scored["season"] = ((scored["date"] - scored["date"].min()).dt.days // params.season_days).astype(int)
    full = scored.groupby("season")["date"].nunique() == params.season_days
    scored = scored[scored["season"].isin(full[full].index)].reset_index(drop=True)
    scored["season"] = scored["season"] - scored["season"].min()
    return Scored(scored, scored["season"].to_numpy(), scored["outcome"].to_numpy().astype(float),
                  scored["base_rate"].to_numpy())


def null_pass_rate(data: Scored, make_forecast, params: Params, rng: np.random.Generator) -> float:
    rates = [pass_rate(data.season, data.scores(make_forecast(rng), params), params)
             for _ in range(params.null_trials)]
    return float(np.mean(rates))


def pct(value: float) -> str:
    return f"{100 * value:.1f}%"


def describe(params: Params) -> str:
    initial = "historical frequency" if params.initial_base_rate is None else f"{params.initial_base_rate}"
    return (f"skill = {params.skill_mode}, beta = 1/{round(1 / params.beta)}, "
            f"gamma = 1/{round(1 / params.gamma)}, initial b = {initial}, "
            f"minimum mean skill = {params.min_mean_skill}, b in basis points = {params.base_rate_bps}")


def rules_report(title: str, params: Params, rng: np.random.Generator) -> list[str]:
    data = build_rounds(params)
    reference_brier = np.mean((data.base_rate - data.outcome) ** 2)
    calibrated = data.scores(data.frame["p_calibrated"].to_numpy(), params)
    btc = (data.frame["asset"] == "BTC").to_numpy()
    long_run = np.full(len(data.outcome), 0.36)

    lines = [
        f"## {title}",
        "",
        f"Rules: {describe(params)}.",
        "",
        f"- Scored period: {data.frame['date'].min().date()} to {data.frame['date'].max().date()}, "
        f"{len(np.unique(data.season))} full seasons, {len(data.outcome):,} rounds.",
        f"- Event frequency: {pct(data.outcome.mean())}; mean base rate b: {pct(data.base_rate.mean())}.",
        "",
        "| Forecaster | Mean skill per round | Skill vs. base-rate Brier | Seasons eligible | 3-season windows eligible | Seasons eligible, BTC only |",
        "|---|---|---|---|---|---|",
    ]
    forecasters = [
        ("Always the base rate b", np.round(data.base_rate * 10_000) / 10_000),
        ("Always the long-run frequency (36%)", long_run),
        ("EWMA volatility, normal model", data.frame["p_normal"].to_numpy()),
        ("EWMA volatility, calibrated walk-forward", data.frame["p_calibrated"].to_numpy()),
    ]
    for name, prob in forecasters:
        scores = data.scores(prob, params)
        lines.append(f"| {name} | {scores.mean():+.4f} | {pct(scores.mean() / reference_brier)} | "
                     f"{pct(pass_rate(data.season, scores, params))} | "
                     f"{pct(rolling_pass_rate(data.season, scores, params, 3))} | "
                     f"{pct(pass_rate(data.season[btc], scores[btc], params))} |")

    lines += ["", "Calibrated model over longer windows:", "", "| Window | Windows eligible |", "|---|---|"]
    for window in (1, 2, 3):
        lines.append(f"| {window} season(s), ~{60 * window} rounds | "
                     f"{pct(rolling_pass_rate(data.season, calibrated, params, window))} |")

    uniform = null_pass_rate(data, lambda g: g.uniform(0, 1, len(data.outcome)), params, rng)
    noise_1 = null_pass_rate(data, lambda g: data.base_rate + g.normal(0, 0.01, len(data.outcome)), params, rng)
    noise_5 = null_pass_rate(data, lambda g: data.base_rate + g.normal(0, 0.05, len(data.outcome)), params, rng)
    lines += [
        "",
        f"Forecasters without information ({params.null_trials:,} Monte Carlo trials each):",
        "",
        "| Forecaster | Seasons eligible |",
        "|---|---|",
        f"| Uniform random probability | {pct(uniform)} |",
        f"| Base rate plus noise, sd 1 point | {pct(noise_1)} |",
        f"| Base rate plus noise, sd 5 points | {pct(noise_5)} |",
        "",
        "Expected reward weight (mean sum of skill per season, counting eligible seasons only):",
        "",
        "| Forecaster | Expected weight | Relative to calibrated |",
        "|---|---|---|",
    ]
    calibrated_weight = expected_sum_skill(data.season, calibrated, params)
    for name, prob in [("EWMA volatility, calibrated walk-forward", data.frame["p_calibrated"].to_numpy()),
                       ("Always the long-run frequency (36%)", long_run)]:
        weight = expected_sum_skill(data.season, data.scores(prob, params), params)
        lines.append(f"| {name} | {weight:.3f} | {pct(weight / calibrated_weight)} |")

    ema = pd.Series(calibrated).ewm(alpha=params.ema_alpha, adjust=False).mean().clip(lower=0)
    lines += ["", "Aggregation weight of the calibrated forecaster, w = min(1 + K * max(EMA, 0), 2):", "",
              "| K | Median | 90th percentile |", "|---|---|---|"]
    for k in (4, params.weight_k):
        weights = np.minimum(1 + k * ema, 2)
        lines.append(f"| {k:g} | {np.median(weights):.2f} | {np.percentile(weights, 90):.2f} |")
    lines.append("")
    return lines


def sensitivity_report(base: Params) -> list[str]:
    lines = [
        "## Sensitivity of the proposed skill definition to beta and gamma",
        "",
        "| beta | gamma | Event frequency | Calibrated: skill vs. base-rate Brier | Calibrated: seasons eligible | "
        "Long-run 36%: seasons eligible |",
        "|---|---|---|---|---|---|",
    ]
    for beta, gamma in [(1 / 30, 1 / 30), (1 / 30, 1 / 90), (1 / 30, 1 / 365), (1 / 90, 1 / 365), (1 / 365, 1 / 365)]:
        params = replace(base, beta=beta, gamma=gamma)
        data = build_rounds(params)
        reference_brier = np.mean((data.base_rate - data.outcome) ** 2)
        calibrated = data.scores(data.frame["p_calibrated"].to_numpy(), params)
        constant = data.scores(np.full(len(data.outcome), 0.36), params)
        lines.append(f"| 1/{round(1 / beta)} | 1/{round(1 / gamma)} | {pct(data.outcome.mean())} | "
                     f"{pct(calibrated.mean() / reference_brier)} | {pct(pass_rate(data.season, calibrated, params))} | "
                     f"{pct(pass_rate(data.season, constant, params))} |")
    lines.append("")
    return lines


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--output", default=str(RESULTS_DIR / "volatility_backtest.md"))
    args = parser.parse_args()
    rng = np.random.default_rng(PROPOSED.seed)

    lines = [
        "# Volatility question backtest",
        "",
        "Generated by `simulation/volatility_backtest.py`. Replays the v1 round rules on daily Binance "
        "closes for BTC/USDT and ETH/USDT (a proxy for the Chainlink USD feeds) and measures whether "
        "forecasting skill is measurable and whether forecasters without information can become eligible.",
        "",
    ]
    lines += rules_report("Rules as first written in the whitepaper", WHITEPAPER_V1, rng)
    lines += rules_report("Proposed rules", PROPOSED, rng)
    lines += sensitivity_report(PROPOSED)

    output = Path(args.output)
    output.parent.mkdir(exist_ok=True)
    output.write_text("\n".join(lines), encoding="utf-8")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
