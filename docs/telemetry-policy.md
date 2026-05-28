# Telemetry, crash reporting, and analytics

**Decision date:** 2026-05-28
**Status:** Adopted; subject to revisit if user-base reaches a scale where
debugging without it becomes painful.

## The position

**Wick does not ship third-party telemetry, crash reporting, or analytics
SDKs**, and we deliberately don't add one as part of the v1 product. No
Sentry, no Crashlytics, no PostHog, no Mixpanel, no Amplitude, no
TelemetryDeck, no first-party "phone home" pings.

This is a *product* decision, not a *technical* one — every SDK below is
high-quality and easy to integrate. The decision applies even if we
later find a privacy-respecting vendor we like.

## Why

Wick's business model ([[wick-business-model]]) is BYO-everything: the
user supplies their LLM key, their data-provider key, owns their
holdings file. The product promise is "we sell software; we never see
your data". Bundling a vendor SDK — even an opt-in one — would:

1. **Break the wire-level claim.** macOS Network privacy report would
   show wick.app connecting to `o.ingest.sentry.io` (or wherever).
   That's the exact thing the BYO model promises won't happen.
2. **Create a regulatory surface.** Once we collect ANYTHING about
   the user, we're inside scope for GDPR / CCPA disclosures, DPA
   negotiations with the vendor, sub-processor lists in the privacy
   policy, etc. That's a meaningful tax on a tiny team.
3. **Distort feedback.** Telemetry rewards what's easy to measure
   (clicks, sessions) over what matters (does the analysis help
   you?). A small-N product gets better signal from talking to
   real users than from a dashboard.
4. **Get rejected by the same users we want.** Sophisticated finance
   types who pick a desktop-native app over a web tool are exactly
   the demographic that runs Little Snitch and notices outbound
   connections. They will close the app.

## What we do instead

**Crashes:**
- macOS's built-in crash reporter writes `.ips` files to
  `~/Library/Logs/DiagnosticReports/`. Users can attach those to a
  GitHub issue or email if they choose to.
- For dev builds, Xcode catches crashes during debug sessions; that
  covers internal-team dogfooding.

**Bugs:**
- A "Report an issue…" menu entry that opens
  `https://github.com/<repo>/issues/new` with a pre-filled template.
  No automated payload — the user types what they saw. Lower volume,
  higher signal.
- The MCP helper logs to stderr (visible to the user's MCP client),
  not to any file; if the MCP client itself logs that, that's its
  choice, not ours.

**Performance:**
- Trust system Instruments / sampler. We don't need always-on
  performance telemetry until we're worried about p99 latencies at a
  scale that doesn't exist yet.

**Feature adoption:**
- Direct outreach. While the user base is small, "did people use the
  MCP integration?" is answered by asking, not by counting events.

## When to revisit

Concrete triggers that would make this position cost more than it
saves:

- Wick has >10k active users — at that scale, "ask people" stops
  scaling, and we'd be flying blind on which features get used.
- We start charging — subscription apps have stronger reasons to
  measure retention / activation funnels.
- A bug in production that we can't reproduce in dev burns >2
  engineering days. At that point, crash-context telemetry pays
  for itself.

When any of those hits, the revisit should:

1. Pick a vendor that supports **on-device aggregation** (events
   batch + scrub locally, send anonymous aggregates only) — e.g.
   TelemetryDeck or similar. NOT Sentry/Mixpanel/Amplitude raw
   event streams.
2. Make it **opt-in** with a Settings toggle that defaults to OFF.
3. Add an entitlement-level documentation entry so MAS reviewers
   know what `network.client` connects to.

## What we won't do, even if "everyone does"

- Sub-millisecond user-interaction timing.
- IP-geolocation of users.
- Cross-session user IDs that survive reinstall.
- Funnel analytics (signup → first chart → first analysis → first
  pay) — that's growth-stage work, not v1 work.
- Heatmaps. Web tools live for this; native macOS UI doesn't fit it.

## Reviewer-facing note

If asked by App Store reviewers whether the app collects user data,
the answer is **No**, with the BYO-architecture story to back it up.
The privacy nutrition label gets the cleanest possible variant:
"Data Not Collected" across every category.
