# WickServer

HTTP shell around `TradingFloor`'s `ReportService` — generates the shared,
non-personalized fixed-flow report for a (ticker, trading-day) once and serves
it to all users (single-flight + cache). Pure server-side Swift (Hummingbird).

## Run locally

```bash
export ANTHROPIC_API_KEY=sk-ant-…
export FRED_API_KEY=…              # optional: real macro backdrop (rates/CPI/curve)
export FINNHUB_API_KEY=…           # optional (fundamentals/news; not yet wired)
swift run WickServer               # listens on :8080
```

Keys are read from the environment only — never commit them. FRED is free
(commercial use OK with attribution).

```bash
curl -X POST "localhost:8080/report?ticker=NVDA"   # generate or cache-hit
curl "localhost:8080/report/NVDA/2026-05-24"        # cache-only read
```

## Deploy

`docker build -f WickServer/Dockerfile -t wickserver .` then run on any
Linux host. **Pick an EU region** (GDPR / MiFID-MAR posture). Apple offers no
server hosting — use Fly.io / Hetzner / Railway / a cloud VM.

## Status

Skeleton: routes → `ReportService` → `TradingFloor`, using
`StubMarketDataProvider`. Next: a Foundation-only `ServerMarketDataProvider`
(Yahoo + Finnhub), auth + rate-limit, Postgres-backed `ReportStore`, and the
"not investment advice" disclaimer on every report.
