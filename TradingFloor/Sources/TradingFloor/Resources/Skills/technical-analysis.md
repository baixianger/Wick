---
name: technical-analysis
description: Analyse price action and technical indicators (trend, momentum, RSI/MACD, levels).
triggers: [chart, technical, rsi, macd, momentum, trend, support, resistance, sma, ema]
tools: [get_market_data]
---

# Technical Analysis

Assess the chart, not the company. Call `get_market_data` first if you don't
already have the snapshot.

## Method

1. **Trend** — direction on the relevant timeframe; position vs 50/200-day SMA.
2. **Momentum** — RSI (overbought >70 / oversold <30), MACD crossovers.
3. **Levels** — nearest support/resistance, distance to 52-week high/low.
4. **Volume** — does it confirm the move?

## Output

- 3–5 concrete bullet findings citing the actual readings.
- One line: `Lean: bullish | neutral | bearish — <one-clause reason>`.

Do **not** give a final buy/sell call here — that is the trader's job in the
full-desk flow. In a quick chat, stop at the lean.
