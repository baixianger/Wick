# Why `wick.run_workflow` is not an MCP tool

**Decision date:** 2026-05-28
**Status:** Final for v1. Revisit only if a concrete user complaint shows up.

## The question

The Wicker workflow (4 analysts → bull/bear debate → trader → risk
manager → final rating + position size) is the marquee feature inside
the GUI. Should we mirror it as an MCP tool — say `wick.run_workflow
(ticker)` — so an external client like Claude Code could trigger the
same pipeline via JSON-RPC and get back a `Report`?

## Why we considered it

The shape lines up cleanly: tool args = ticker, tool result = Markdown
report. The infrastructure already exists (`TradingFloor.analyze(...)`).
Looks like a one-day add.

## Why we're NOT shipping it

**Claude Code (or any MCP-aware LLM) is itself an LLM.** The user is
already paying for it, it already has a context window, it can already
chain tool calls. Layering ANOTHER LLM (Wicker's TradingFloor
multi-agent stack) underneath is just paying twice for reasoning that
the host LLM does at least as well.

The right division of labor on the MCP surface:

- **Wick provides DATA** (snapshot, candles, holdings, watchlist,
  portfolio). Things only Wick has — the user's local holdings, our
  EastMoney + financial-decorator chain.
- **MCP client provides REASONING.** It has the LLM, it has the
  conversation history, it has follow-up turns. Wicker's analyst /
  debater / trader prompts can be invoked directly by the user there
  ("act as a bull researcher for 600519.SS, citing the data from
  `wick.snapshot`") with full editing/iteration the GUI workflow
  can't offer.

Concretely, what `wick.run_workflow` would have cost us:

1. **Cross-process LLM credentials.** The helper would need the user's
   API key. That means either shared Keychain group entitlements
   (another MAS provisioning lever to pull), or shipping an extra
   "send key to helper" handshake. Both attack-surface adds.
2. **Cost ambiguity.** The user sees a single tool call but gets
   charged for 8-12 internal LLM calls. Even with good labeling,
   that's a surprise vector.
3. **Latency.** Full Wicker is 30-60s of LLM time. MCP clients tend
   to spin a long progress bar — that interaction is fine in our
   GUI but bad as an embedded tool call from somebody else's chat.
4. **Lock-in.** A run_workflow tool implicitly says "Wicker's
   analyst prompts are the right ones." Claude Code users may
   want to write their own, with their own personas, on top of
   our data. The data-only surface lets them.

## What we tell users instead

The Wicker workflow stays a **GUI feature** (one click, beautiful
report, runs on the user's BYO LLM key as before). The MCP integration
is for users who'd rather drive their own analysis through their own
LLM. They aren't the same use case.

**But we don't leave them empty-handed.** The MCP server exposes
`wick.methodology` — the same markdown analyst playbooks Wicker's
internal desk follows (`fundamental-analysis`, `technical-analysis`,
`sentiment-analysis`, `bull-bear-debate`, `full-desk-analysis`,
`desk-analyst`). The calling agent reads the recipe, calls our data
tools at each stage, does its own LLM reasoning, and arrives at a
result. It's the inverse of `run_workflow`: we hand them the cookbook
instead of cooking for them.

Concretely the flow becomes:

```
agent → wick.methodology()                # read the master playbook
agent → wick.snapshot("600519.SS")        # pull the data
agent → wick.methodology("fundamental-analysis")  # read the fundamental analyst's lens
agent reasons with its own LLM            # produces the fundamental finding
… repeat per analyst, then debate, then trade decision, then risk review.
```

The data is ours, the methodology is ours, the reasoning is theirs.
That split holds the line on "we never see your data" and "you never
pay twice for inference."

In the Wick docs (and the App Store listing), we frame this as:

> Wick gives you two ways to analyse a position:
>
> 1. **Click "Analyze".** Wicker's six-agent pipeline produces a
>    full report — bullish thesis, bearish thesis, trader call,
>    risk manager review.
> 2. **Drive it from your own AI.** Plug the bundled MCP server
>    into Claude Code or Codex and write your own analysis,
>    using Wick's market data + your holdings as raw material.

Not "MCP version" vs "GUI version" of the same thing. They are two
different products for two different users.

## When to revisit

Only if:

- We see actual user requests asking for `run_workflow` via MCP. So
  far that's never been asked — it's a theoretical add I proposed
  and we declined.
- We add a v2 MCP shape that includes streaming progress events and
  long-running task IDs; the current MCP-stdio model isn't built
  for 30-60s tool calls and forcing one would feel awkward.

Until either, the answer is no.
