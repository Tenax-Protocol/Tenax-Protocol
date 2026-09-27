# Simulation

Phase 0 models used to validate and calibrate the protocol design before any contract is written.

## Setup

```
python -m venv .venv
.venv/Scripts/activate      # Windows; use `source .venv/bin/activate` elsewhere
pip install -r requirements.txt
```

## Volatility question backtest

Replays the v1 forecasting rules on historical BTC and ETH prices and measures whether forecasting skill is measurable and whether forecasters without information can become eligible for rewards.

```
python fetch_prices.py          # downloads daily closes into data/ (not versioned)
python volatility_backtest.py   # writes results/volatility_backtest.md
```

Prices come from the Binance public API (BTC/USDT and ETH/USDT), used as a proxy for the Chainlink USD feeds the protocol reads on Base. Forecasters only use information available before submission, and the calibrated model is fitted walk-forward, so no result depends on future data.

Latest results: [results/volatility_backtest.md](results/volatility_backtest.md).
