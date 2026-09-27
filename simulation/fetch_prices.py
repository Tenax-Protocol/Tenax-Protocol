"""Download daily closes from the Binance public API for the phase 0 simulations.

Binance USDT pairs are used as a proxy for the Chainlink USD feeds the protocol
reads on Base. Only fully closed daily candles are kept.
"""

from __future__ import annotations

import argparse
import csv
import json
import time
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

BASE_URL = "https://api.binance.com/api/v3/klines"
DATA_DIR = Path(__file__).parent / "data"
DAY_MS = 86_400_000
PAGE_LIMIT = 1000


def fetch_daily_closes(symbol: str, start: datetime) -> list[tuple[str, float]]:
    """Return (ISO date, close) pairs for every closed daily candle since `start`."""
    today = datetime.now(timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0)
    today_ms = int(today.timestamp() * 1000)
    cursor = int(start.timestamp() * 1000)
    rows: list[tuple[str, float]] = []

    while cursor < today_ms:
        url = f"{BASE_URL}?symbol={symbol}&interval=1d&startTime={cursor}&limit={PAGE_LIMIT}"
        with urllib.request.urlopen(url, timeout=30) as response:
            klines = json.load(response)
        if not klines:
            break
        for kline in klines:
            open_time_ms = kline[0]
            if open_time_ms >= today_ms:
                continue  # today's candle is still open
            day = datetime.fromtimestamp(open_time_ms / 1000, tz=timezone.utc).date().isoformat()
            rows.append((day, float(kline[4])))
        cursor = klines[-1][0] + DAY_MS
        time.sleep(0.2)  # stay well below the public rate limit

    return rows


def save_csv(symbol: str, rows: list[tuple[str, float]]) -> Path:
    DATA_DIR.mkdir(exist_ok=True)
    path = DATA_DIR / f"{symbol}_1d.csv"
    with path.open("w", newline="", encoding="utf-8") as file:
        writer = csv.writer(file)
        writer.writerow(["date", "close"])
        writer.writerows(rows)
    return path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--symbols", nargs="+", default=["BTCUSDT", "ETHUSDT"])
    parser.add_argument("--start", default="2018-01-01", help="first day, YYYY-MM-DD (UTC)")
    args = parser.parse_args()

    start = datetime.fromisoformat(args.start).replace(tzinfo=timezone.utc)
    for symbol in args.symbols:
        rows = fetch_daily_closes(symbol, start)
        path = save_csv(symbol, rows)
        print(f"{symbol}: {len(rows)} days, {rows[0][0]} to {rows[-1][0]} -> {path}")


if __name__ == "__main__":
    main()
