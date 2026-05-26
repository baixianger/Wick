# TradingFloor skills

The agent's **playbook**: analysis methodology as drop-in markdown, separate
from native **tools** (data/computation) and the **agent** (orchestration).

## Two modes, one substrate

Both run over the same skills + tools:

| | Fixed-flow mode | Interactive mode |
|---|---|---|
| Orchestration | Hard-coded pipeline (`TradingFloor.analyze`) | LLM (PiSwift chat agent) decides |
| Output | A `Report` with a rating | A conversation |
| Use | "Deep analysis" button → batch report | "Ask the desk" chat |
| Skills used | All, in fixed order (analysts → debate → trader → risk) | Whichever the user's question needs |
| Cost | Predictable | Variable |

The fixed flow is also exposed to the chat agent as the `full-desk-analysis`
skill, so an interactive user can trigger the rigorous work-up on demand.

## Layout

- `desk-analyst.md` — the chat agent's persona / system prompt.
- `fundamental-analysis.md`, `technical-analysis.md`, … — one per analyst role.
- `bull-bear-debate.md` — structured two-sided debate.
- `full-desk-analysis.md` — orchestrates the complete pipeline.

## Adding a skill

Drop a new `.md` with `name` + `description` frontmatter into the skills
directory. No code change needed — the agent discovers it and the user can
add their own. Skills that need computation call a **native tool** (e.g.
`get_market_data`) rather than embedding scripts, which keeps everything
iOS-sandbox-safe.
