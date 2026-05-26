---
name: fundamental-analysis
description: Analyse company fundamentals — valuation, growth, margins, balance-sheet health.
triggers: [fundamentals, valuation, pe, peg, margins, revenue, earnings, balance, sheet, growth]
tools: [get_market_data]
---

# Fundamental Analysis

Assess the business behind the ticker. Call `get_market_data` first for the
fundamentals block if you don't already have it.

## Method

1. **Valuation** — P/E and peers; is the multiple justified by growth?
2. **Growth** — revenue/earnings trajectory and durability.
3. **Profitability** — gross/operating margins and their direction.
4. **Balance sheet** — leverage, cash, obvious solvency risks.

## Output

- 3–5 concrete bullet findings citing the actual figures.
- One line: `Lean: bullish | neutral | bearish — <one-clause reason>`.

Flag explicitly when a needed figure is missing rather than guessing.
