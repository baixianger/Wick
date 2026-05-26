---
name: full-desk-analysis
description: Run the complete structured work-up — analysts, bull/bear debate, trade decision, risk review — and return a rated report.
triggers: [deep analysis, full report, full desk, complete workup, full analysis, should i buy, should i sell]
tools: [run_full_desk]
---

# Full Desk Analysis

The rigorous, end-to-end work-up. This is the **fixed-flow pipeline** surfaced
as a skill: when the user wants the full report rather than a quick take,
follow this exact order so the result is comprehensive and comparable across
tickers.

## Procedure

1. `get_market_data` for the ticker.
2. Run each analyst skill: `fundamental-analysis`, `technical-analysis`,
   `sentiment-analysis`, `news-analysis`. Collect each one's findings + lean.
3. Run `bull-bear-debate` for the configured number of rounds, feeding it the
   analysts' findings.
4. **Trade decision** — weigh everything and open with exactly one of:
   `STRONG SELL | SELL | HOLD | BUY | STRONG BUY`, then 2–4 sentences citing the
   strongest point on each side.
5. **Risk review** — sanity-check the decision for downside, sizing, and tail
   risk; confirm or propose a more conservative rating, and list 1–2 risks to
   monitor.

## Output

A structured report: the rating, a short rationale, and the full transcript of
every step (so the user can audit the reasoning).

> Implementation note: the host app can run this deterministically via
> `TradingFloor.analyze(ticker:)` instead of having the LLM orchestrate — same
> steps, predictable cost. The interactive agent uses this skill when the user
> asks for "the full analysis".
