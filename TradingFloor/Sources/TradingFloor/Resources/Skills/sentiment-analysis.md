---
name: sentiment-analysis
description: Gauge short-term market mood for a ticker from social and news chatter.
triggers: [sentiment, social, mood, twitter, x, reddit, stocktwits, news, headlines]
tools: [get_social_sentiment, get_market_data]
---

# Sentiment Analysis

Read the crowd, not the chart. Call `get_social_sentiment` for the ticker; it
aggregates whatever sources the host has configured.

## Sources & rules

- **Default source is a licensed aggregator** (e.g. Finnhub) — always safe to use.
- **X and Reddit are optional, the user's own credentials only.** They appear
  here *only* in interactive mode and *only* if the user has supplied keys; the
  fixed/batch flow never uses them. If they're absent, that's expected — work
  with what's returned.
- Never fabricate posts or sentiment. If a source returns nothing, say so.
- Treat raw posts as ephemeral context for this read; do not present them as
  redistributable content.

## Method

1. Note the **net read** (bullish/bearish skew) and how strong it is.
2. Distinguish **signal vs noise** — is chatter tied to a real catalyst
   (earnings, product, macro) or just momentum?
3. Flag **divergence** — sentiment hot while fundamentals/technicals are weak
   (or vice versa) is itself a signal.

## Output

- 2–4 bullets on the mood and what's driving it.
- One line: `Lean: bullish | neutral | bearish — <one-clause reason>`.
