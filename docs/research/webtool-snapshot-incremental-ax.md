# WebTool `snapshot` — token-efficient incremental AX/DOM snapshots over WebKit

Status: design research (no implementation). Author-facing doc for Wicker's
browser-operation tools. Edits here only — see "Integration" for the live files
this plugs into (do not edit those from this doc's work).

## 1. Problem

`web.snapshot` gives the LLM a view of the current page so it can decide what to
`click`/`type`. A naive snapshot serialises the *whole* accessibility/DOM tree on
every call. On a real page (news site, broker dashboard, search results) that is
2k–20k tokens per call, and the agent calls snapshot after *every* action. The
cost is dominated by re-sending nodes the model already saw.

Goal: send a **full compact tree once**, then on each subsequent snapshot send
only **what changed** (added / removed / mutated nodes) as **NDJSON delta lines**,
with **stable element references** so `click(ref:N)` / `type(ref:N, …)` resolve
deterministically across snapshots and so deltas can key on node identity.

This design is built on two prior-art sources studied directly:

- **uni-browser** (`/Users/baixianger/personal/uni-browser`, Rust) — primary
  reference for the **stable-ref / UidMap** machinery and the compact YAML node
  shape. (It does *full* snapshots; the NDJSON delta layer below is Wick's
  addition on top of its identity model.)
- **browser-use** (`browser-use/browser-use`, Python) — reference for the
  **`[n]` interactive-index** scheme, the **`*`-prefix "new element"** signal,
  the attribute whitelist, bbox-containment pruning, and text caps.

---

## 2. What uni-browser actually does (extracted)

uni-browser's RFC 0008 + RFC 0011 ship an AX-tree snapshot with cross-snapshot
stable handles. The mechanism, with file paths:

### 2.1 Identity: per-session `UidMap`
`crates/shared-codec/src/snapshot.rs`. A session owns one map keyed on a string
**identity key** (`"{frame_id}:{backendDOMNodeId}"`) → `UidEntry { uid: "e1", … }`.
The lifecycle is a mark/sweep:

```rust
pub fn begin_snapshot(&mut self)  // clear every entry's seen flag
pub fn lookup_or_create(&mut self, identity_key, backend_node_id, target_id) -> &UidEntry
pub fn prune_unseen(&mut self)    // retain(|e| e.seen_in_current_snapshot)
```

`lookup_or_create` allocates `format!("e{}", self.next_uid)` the first time it
sees an identity key and **returns the same uid forever after** (test
`serialize_across_two_snapshots_keeps_stable_uid` asserts `e1` is stable across
two snapshots). `entry_by_uid` is the reverse lookup the click path uses.
**This is the "stable ref" foundation** — `eN` survives re-renders as long as the
backend DOM node lives, because the identity key is the engine's backend node id,
not a positional index.

### 2.2 Node shape + compact emit
`AccessibilityNode` (same file) is the engine-neutral flat node:
`node_id, parent_id, child_ids, role, name, backend_dom_node_id, ignored,
child_frame_id`. The serializer walks pre-order and emits one indented YAML line
per node:

```
- RootWebArea "Login"
  - button "Sign in" [uid=e1]
  - link "Help" [uid=e2]
```

(`emit_yaml_line`: `<indent>- <role> "<name>" [uid=eN]`.) Nodes with `ignored=true`
are skipped unless `verbose` — this is the prune step. `child_frame_id` splices
same-origin iframe subtrees inline (or a `[cross-origin frame]` placeholder).

### 2.3 browser-use-style enrichment (RFC 0011)
`crates/shared-codec/src/dom_serializer.rs` adds the v2 line format
`[N] role "name" attr=val text="…" [uid=eN]` where `[N]` is a **1-based
interactive index** assigned only to clickable nodes, plus:
- a **clickability OR-heuristic** `is_clickable` (native tag → ARIA role →
  click listener → inline handler → `cursor:pointer` → form-control wrapper);
- an **attribute whitelist** `DEFAULT_INCLUDE_ATTRIBUTES` (`role / aria-* /
  value / placeholder / type / name / id / alt / title / href / src / …`;
  `class` deliberately excluded for token economy — `crates/contracts/src/snapshot.rs`);
- **bbox containment pruning** (`drop_contained_descendants`, drop a node whose
  box is ≥threshold inside an ancestor's box) and paint-order occlusion drop;
- per-node text cap (`text_cap_per_node`, default 200 chars).

### 2.4 The gap this doc fills
uni-browser **re-emits the whole tree every snapshot**. Its stable `eN` uids make
the tree *diffable*, but it never ships a diff on the wire. Wick adds an
**NDJSON baseline+delta layer keyed on those same stable refs.** browser-use is
closer to incremental: it marks newly-appeared nodes with a `*` prefix
(`is_new`, set by comparing each node's `parent_branch_hash` / `compute_stable_hash`
against the previous step's cache) — but it still re-sends the full serialised
tree each step; the `*` is a *highlight*, not a *delta*. Wick takes the identity
model from uni-browser and the "what's new" intent from browser-use and makes the
wire payload itself incremental.

---

## 3. Obtaining the tree on WebKit (the constraint that drives everything)

uni-browser and browser-use both read the AX tree out-of-process via CDP/Juggler
(`Accessibility.getFullAXTree`, `DOMSnapshot.captureSnapshot`). **Wick has no such
channel.** Wicker drives an embedded `WebPage`; the only inspection primitive is
`WebPage.callJavaScript(...)` — we inject JS into the page and get a
JSON-serialisable value back to Swift. There is no platform AX API reachable from
that JS context, and no CDP.

Options considered:

| Option | How | Verdict |
|---|---|---|
| **A. JS DOM/ARIA walk** | Inject JS that walks `document`, computes role + accessible name + interactable + value + bbox per element, returns compact JSON. | **Recommended.** Only option that works purely through `callJavaScript`. Full control over pruning/format, so we control token cost directly. |
| B. `document.body.innerText` / outerHTML | Cheap. | Rejected: no roles, no stable refs, no interactable flag — the model can't reliably target elements, and HTML is token-heavy (browser-use's whole rewrite existed to escape raw HTML). |
| C. Real accessibility tree | Would need a native AX bridge from Swift side, not from inside the page. | Out of scope: `callJavaScript` runs *in the page*, can't reach `NSAccessibility`/`AXUIElement`. Possible future native path, not MVP. |

**Decision: Option A — a page-side JS walker.** It must compute, per element, a
*pragmatic* ARIA role + accessible name rather than the full WAI-ARIA AccName
algorithm. Cover the cases the LLM actually acts on (mirroring uni-browser's
Phase-2b resolver and browser-use's whitelist):

- **role**: explicit `role=` attribute first; else implicit role from tag
  (`a[href]`→link, `button`→button, `input[type]`→textbox/checkbox/radio/…,
  `select`→combobox, `textarea`→textbox, `summary`→button, headings→heading, …).
- **name**: `aria-label` → `aria-labelledby` target text → associated `<label>` /
  `for=` → `alt` (img) → `placeholder`/`value` (inputs) → trimmed `textContent`
  (capped). First non-empty wins.
- **interactable**: native interactive tag, OR interactive ARIA role, OR
  `onclick`/inline handler present, OR computed `cursor:pointer`, OR
  `tabindex>=0`, OR contenteditable. (browser-use's OR-heuristic.)
- **value**: form controls (`input.value`, `select` selected option text,
  checkbox/radio `checked`).
- **state**: `disabled`, `checked`, `expanded` (`aria-expanded`), `selected`,
  `readonly` — only when present.
- **bbox** (optional): `getBoundingClientRect()` — used for viewport filtering and
  to give `click` a coordinate fallback; can be omitted from the LLM payload.

Everything returned must be JSON-serialisable (the `callJavaScript` boundary). We
return **NDJSON as a single string** from JS (newline-joined), or an array of
line-objects Swift joins — either works; the on-wire-to-LLM artifact is NDJSON.

---

## 4. Compact node representation

Minimal per-node fields the LLM needs to *act*, modelled on uni-browser's
`SnapshotElement` + browser-use's `[n]` line. Per node we keep:

| field | meaning | notes |
|---|---|---|
| `ref` | stable id, e.g. `7` (rendered `ref:7`) | survives re-renders (§5). The *only* handle `click`/`type` accept. |
| `role` | pragmatic ARIA role | `button`, `link`, `textbox`, `checkbox`, `combobox`, `heading`, `option`, … |
| `name` | accessible name | capped (e.g. 120 chars), quoted+escaped |
| `value` | current value / checked | only for form controls; omitted otherwise |
| `state` | compact flags | only emitted when set: `disabled`, `checked`, `expanded`, `selected` |
| `i` | interactive index (`[n]`) | 1-based, assigned only to interactable nodes, per snapshot |
| `d` | depth | indentation in the human-readable tree |

**Pruning (do this in JS, before serialising — it's where tokens are saved):**
1. Drop `display:none` / `visibility:hidden` / `aria-hidden` / `hidden` /
   zero-area / fully-offscreen-and-not-near-viewport elements.
2. Drop decorative/structural nodes that carry no name and aren't interactable
   (bare `div`/`span` wrappers) — collapse their children up, like uni-browser's
   `ignored` skip and browser-use's "remove invisible nodes without children or
   interactivity".
3. **bbox-containment collapse**: if an interactable's box is ≥99% inside an
   interactable ancestor's box, drop the inner wrapper (uni-browser's
   `drop_contained_descendants`) — avoids `div>button>span` triple-emit.
4. **Collapse text**: merge adjacent text into the parent's `name`/`text`, cap
   per node (e.g. 200 chars), and cap children of huge lists (e.g. first N
   `<option>`/`<li>` then `… +k more`).
5. **Attribute whitelist** only (no `class`, no `style`, no data-* except our own
   ref attr) — uni-browser's `DEFAULT_INCLUDE_ATTRIBUTES`.

Two synchronized renderings come out of the same node set:
- **Tree (human/LLM readable)** — indented, browser-use v2 line shape:
  ```
  [1] textbox "Search" value="" ref:3
  [2] button "Search" ref:4
      heading "Results" ref:5
  [3] link "First result" ref:6
  ```
  Non-interactable nodes get no `[n]`. Interactable nodes get `[n]` + `ref:N`.
- **NDJSON (machine/delta)** — one JSON object per node (§6), keyed by `ref`.

For the *baseline* snapshot we can send the indented tree (most readable for the
model). For *deltas* we send NDJSON ops. Both carry `ref`, so the model uses the
same handle either way. (If we want one format throughout, send NDJSON for both;
the tree is a nicety, not load-bearing.)

---

## 5. Stable element refs

The ref must (a) let `click`/`type` find the exact node later, and (b) let the
diff engine decide "same node" vs "new node" across snapshots. Two
implementations, both page-side because that's all `callJavaScript` reaches:

### 5.1 Recommended: page-side ref registry singleton (`window.__wick`)
A JS singleton injected once per document holds a `WeakMap<Element, number>` and a
reverse `Map<number, WeakRef<Element>>`, plus a monotonically increasing counter.
The walker calls `__wick.refFor(el)` which returns the existing ref or mints a new
one. This is the direct analogue of uni-browser's `UidMap.lookup_or_create`, but
keyed on the **live element object** instead of a backend node id (which we don't
have on WebKit). Properties:
- Same element → same ref for the page's lifetime (WeakMap identity).
- `click(ref)` resolves `__wick.elementFor(ref)` → live element → dispatch a real
  click / focus+input. No CSS selector needed.
- The `WeakRef`/`WeakMap` lets GC'd (removed) elements drop out naturally; a ref
  that no longer resolves is reported `removed` in the delta.

**Surviving re-renders.** Identity is the JS element object. This survives:
- attribute/text/style mutations on the same element (it's the same object);
- the element being moved in the DOM.
It does **not** survive a framework replacing the node with a fresh element
(React reconciliation, `innerHTML=` rebuild). For that case we add a **fallback
re-association** in the walker: when an element has no ref yet, before minting a
new one, check a small **signature** = `(role, name, nearest-stable-ancestor-path,
nth-of-type)` against the previous snapshot's signatures (this is exactly
uni-browser Phase-2b's `(role, name, nth)` resolver and browser-use's
`parent_branch_hash`/`compute_stable_hash`). A match re-binds the *old* ref to the
*new* element, so `ref:7` stays `ref:7` through a re-render of the same logical
control. Only genuinely-new controls get fresh refs.

### 5.2 Alternative: `data-wick-ref` attribute
Stamp `el.setAttribute('data-wick-ref', n)` so `click` can use
`document.querySelector('[data-wick-ref="7"]')`. Simpler resolution, selector
survives some re-renders if the framework preserves attributes. Downsides: mutates
the page (can perturb the site / its own observers, and CSS `[data-*]` selectors),
and frameworks that diff on attributes may strip it. **Use the WeakMap registry as
the source of truth; optionally also stamp the attribute as a secondary
selector-based fallback for `click`.**

### 5.3 Why not positional `[n]` as the durable handle
browser-use's `[n]` interactive index is **per-snapshot** and not stable (its own
docs: uids stable, `interactive_index` not). We keep `[n]` only as a readable
in-tree label and make **`ref:N` the durable, click-able handle** — matching
uni-browser's split (`uid` stable, interactive index ephemeral).

---

## 6. Baseline + delta NDJSON scheme

### 6.1 First call (baseline)
`web.snapshot` with no prior state returns the **full compact tree** — either the
indented tree (readable) or full NDJSON, prefixed by a header line:

```
{"v":1,"op":"base","url":"https://…","title":"…","count":42}
{"ref":1,"role":"RootWebArea","name":"Example","d":0}
{"ref":3,"role":"textbox","name":"Search","i":1,"d":2,"value":""}
{"ref":4,"role":"button","name":"Search","i":2,"d":2}
…
```

Swift caches the baseline node set (keyed by ref) in the session as the "last
sent" state.

### 6.2 Subsequent calls (delta)
The page-side diff engine compares the **current** walk to the **previous** walk
(both held in `window.__wick`, or the previous set is passed in from Swift) and
emits only changes as NDJSON ops keyed by `ref`:

| op | line shape | meaning |
|---|---|---|
| `+` add | `{"op":"+","ref":9,"role":"link","name":"New item","i":7,"d":3,"after":6}` | node appeared; `after`/`parent` place it for the model |
| `-` remove | `{"op":"-","ref":4}` | node gone (WeakRef dead or pruned) |
| `~` change | `{"op":"~","ref":3,"value":"AAPL"}` | same node, only listed fields changed (here `value`) |

A delta response is framed by a header so the model knows it's incremental:

```
{"v":1,"op":"delta","base":7,"changes":3}
{"op":"~","ref":3,"value":"AAPL"}
{"op":"+","ref":9,"role":"option","name":"Apple Inc","i":7,"d":4,"parent":3}
{"op":"-","ref":12}
```

Rules:
- `~` carries **only the fields that changed** (plus `ref`), not the whole node.
  Field-level diff: compare `role/name/value/state/i/d` per ref.
- New interactable → `+` with its `[n]` index and a `parent`/`after` anchor.
- `-` when a ref present last time is absent now (and, for safety, its WeakRef no
  longer resolves) — mirrors uni-browser's `prune_unseen`.
- Index churn: `[n]` indices renumber every snapshot; to avoid a storm of `~`
  lines from pure renumbering, treat `i` changes as **silent** unless the node is
  otherwise in the delta — the durable handle is `ref`, and the model is told `[n]`
  is volatile. (Optional: omit `i` from delta `~` comparisons entirely.)
- The engine still runs uni-browser's mark/sweep each walk (`begin → refFor →
  prune`) so identity bookkeeping matches the delta.

### 6.3 Token win (quantified, order-of-magnitude)
Assume a 600-node page, ~40 interactable, compact NDJSON ≈ 18–25 tokens/line.
- **Full dump every call**: ~150–200 nodes after pruning × ~20 tok ≈ **3–4k
  tokens/snapshot**. After 8 actions ≈ **24–32k tokens** just for snapshots.
- **Baseline + deltas**: baseline ~3–4k once; a typical post-action delta touches
  3–15 nodes ≈ **60–400 tokens**. 8 actions ≈ 4k + 7×~250 ≈ **~5.7k tokens**.

→ roughly an **80–90% reduction** on a multi-step task — consistent with
browser-use's reported ~85% raw-HTML→serialised reduction *and* compounding again
because we stop resending the unchanged baseline. The win grows with task length
and with page size (a big static dashboard where the agent toggles one widget is
the best case: ~98%).

---

## 7. Token budgeting

- **`maxNodes` cap** (e.g. 400 after pruning). On overflow, keep all interactable
  nodes + their ancestors, drop the most non-interactable text-only leaves first;
  emit a trailing `{"op":"note","truncated":N}` line so the model knows there's
  more.
- **`viewportOnly` option** (default on for big pages): only walk elements whose
  bbox intersects (or is within ~1 viewport of) the visible region. Off-screen
  controls reachable only by scroll get a `scroll` hint. This is browser-use's
  viewport-expansion idea.
- **Text caps**: per-node name/text cap (120/200 chars), list child cap (`first N
  + "… +k more"`).
- **Attribute whitelist** (no `class`/`style`) — already in §4.
- **`verbose` flag** (default off): when off, prune `ignored`/decorative nodes;
  when on, include them for debugging (uni-browser's `verbose`).
- **Delta size guard**: if a delta would exceed e.g. 60% of a fresh baseline
  (huge page transition / navigation), send a fresh `base` instead — cheaper and
  less confusing than a giant diff. Always send `base` after `web.navigate`.

---

## 8. Integration with the existing Wicker plan

Today `Wick/Browser/WebTools.swift` exposes selector-based `web.snapshot` (empty
args), `web.click({selector})`, `web.type({selector,text,enter})`, over a
`WebToolDriver` that owns a `callJavaScript` closure into the agent `WebPage`
(managed by `BrowserSessionManager`). This design slots in without changing that
architecture — only the JS payload and the tool arg schemas evolve. (Those files
are owned by another in-flight change; this doc does not edit them.)

### 8.1 Where the page-side helper lives and how it persists
The ref registry + diff engine is a single JS module (`__wick`) injected **once
per document**:
- Inject on navigation/commit (e.g. a `WKUserScript` at document-end, or the
  first `callJavaScript` after `web.navigate` bootstraps `window.__wick` if
  absent). It must be **idempotent** (`window.__wick ||= makeRegistry()`) because
  `callJavaScript` evaluations are independent and SPA navigations don't reload.
- `__wick` holds: the `WeakMap`/`WeakRef` ref registry, the previous walk's node
  map (for diffing), the `next_ref` counter, and the walk+diff functions.
- Each `web.snapshot` call invokes `__wick.snapshot({mode, viewportOnly, …})`
  which: bumps a generation, walks+prunes, mark/sweeps refs, diffs against the
  prior generation, and returns either a `base` or a `delta` NDJSON string.
- Persistence across `callJavaScript` calls = it's a `window` global; it lives as
  long as the document. On real navigation the global is gone → next snapshot
  re-bootstraps and returns a fresh `base` (correct: it's a new page).

### 8.2 Tool surface
- **`web.snapshot`** — args gain optional `{ full?: bool, viewportOnly?: bool,
  verbose?: bool }`. Returns the NDJSON (base or delta). The Swift side may keep a
  shadow copy of the last node set for safety, but the page-side `__wick` is the
  source of truth for diffing; Swift just relays the string and remembers
  "baseline already sent for this document generation?".
- **`web.click`** — accepts **either** `{ ref: N }` **or** the existing
  `{ selector }` (keep selector for hand-driven/legacy use, exactly like
  uni-browser's `ClickTarget = .selector | .ref`). Ref path:
  `__wick.click(ref)` → `elementFor(ref)` → `scrollIntoViewIfNeeded` →
  dispatch pointer/click events; if the WeakRef is dead, attempt the
  `(role,name,nth)` re-association (§5.1) once, else return a `RefStale` error so
  the agent re-snapshots.
- **`web.type`** — same: `{ ref: N, text, enter? }` or `{ selector, … }`.
  `__wick.type(ref, …)` focuses the element, sets value via the proper input
  events, optionally dispatches Enter.
- **Stale-ref safety** (uni-browser Risk 3): on `click(ref)`/`type(ref)`, verify
  the resolved element's current `(role,name)` still matches what the snapshot
  recorded for that ref; if it diverges, return `RefStale` rather than acting on a
  different control. A successful action implies identity match.

### 8.3 Flow
```
agent: web.snapshot            → base NDJSON (refs minted)         [~3–4k tok once]
agent: web.type ref:3 "AAPL"   → __wick.type(3,…)
agent: web.snapshot            → delta: ~ref:3 value, +option rows  [~150 tok]
agent: web.click ref:9         → __wick.click(9)
agent: web.snapshot            → delta: page changed, few lines     [~200 tok]
…
```

---

## 9. Summary of borrowed mechanics

- From **uni-browser**: the `UidMap` mark/sweep identity model
  (`begin_snapshot`/`lookup_or_create`/`prune_unseen`, stable `eN`), the
  `role "name" [uid]` compact line, `ignored`/verbose pruning, bbox-containment
  collapse, the attribute whitelist, the `(role,name,nth)` stale-ref resolver, and
  the `.selector | .ref` action target union. Re-keyed from `backendNodeId` to a
  page-side `WeakMap<Element>` because WebKit gives us no backend ids.
- From **browser-use**: the `[n]` interactive-index line, the `*`/`is_new` intent
  (made into real `+` delta ops), `DEFAULT_INCLUDE_ATTRIBUTES`, text/option caps,
  viewport expansion.
- **Wick's own contribution**: turning uni-browser's *stable-but-full* snapshots
  into a **baseline + NDJSON `+`/`-`/`~` delta** wire format keyed on stable refs,
  produced entirely inside the page via a persistent `window.__wick` singleton
  driven through `WebPage.callJavaScript`.
