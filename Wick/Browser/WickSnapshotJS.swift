import Foundation

/// The page-side `window.__wick` singleton — the JS engine behind the
/// token-efficient incremental AX/DOM snapshot (TODO #42, spec
/// `docs/research/webtool-snapshot-incremental-ax.md` §4–§8).
///
/// **What it is.** A single, idempotently-injected JavaScript module that lives
/// as a `window` global inside the agent's `WebPage`. It owns:
/// - a `WeakMap<Element, ref>` + reverse `Map<ref, WeakRef<Element>>` ref
///   registry (the stable-handle foundation, §5.1 — analogue of uni-browser's
///   `UidMap.lookup_or_create`, keyed on the live element object since WebKit
///   gives us no backend node id);
/// - the previous walk's node map (for diffing) keyed by ref;
/// - a `next_ref` counter and a `generation` counter;
/// - walk + prune + diff functions, plus ref-addressed `click`/`type`.
///
/// **Why a Swift string and not a `.js` resource.** `WebPage.callJavaScript`
/// takes a source string; bundling a resource would add a build-phase + a
/// runtime read for no benefit. Holding it as a Swift `static let` keeps the
/// injection a pure string the manager concatenates, and keeps the macOS-26 /
/// WebKit surface entirely app-side (the `TradingFloor` package stays
/// WebKit-free).
///
/// **Idempotent injection.** `bootstrap` is `window.__wick ||= makeRegistry()` —
/// safe to prepend to every `callJavaScript` because evaluations are
/// independent. It survives SPA navigations (no reload → the global persists)
/// and is gone after a real navigation (new document → next snapshot
/// re-bootstraps and returns a fresh `base`, which is correct: it's a new page).
enum WickSnapshotJS {

    /// The registry module. Defines `window.__wick` exactly once. Everything the
    /// snapshot/click/type entry points need is a method on this object so the
    /// Swift side only ever calls `__wick.snapshot(...)` / `.click(...)` /
    /// `.type(...)` after prepending `bootstrap`.
    ///
    /// Field legend on a compact node (§4):
    ///   `ref`   stable id (rendered `ref:N`) — the only durable handle
    ///   `role`  pragmatic ARIA role
    ///   `name`  accessible name (capped, escaped)
    ///   `value` form-control value / checked (omitted otherwise)
    ///   `state` compact flags, only when set (disabled/checked/expanded/selected)
    ///   `i`     1-based interactive index (`[n]`), interactable nodes only, per walk
    ///   `d`     depth (indentation in the readable tree)
    static let bootstrap = #"""
    window.__wick ||= (function () {
      "use strict";

      // ---- config (token budgeting, §7) -------------------------------------
      const NAME_CAP = 120;          // accessible-name char cap
      const MAX_NODES = 400;         // hard cap after pruning (§7)
      const VIEWPORT_PAD = 1.0;      // viewport-expansion factor (~1 screen)

      // ---- ref registry (§5.1) ----------------------------------------------
      // WeakMap<Element,int> forward + Map<int,WeakRef<Element>> reverse, both
      // keyed on the LIVE element object (survives attr/text/style mutation and
      // DOM moves; a framework node-swap is recovered via re-association below).
      const fwd = new WeakMap();        // element -> ref
      const rev = new Map();            // ref -> WeakRef<element>
      let nextRef = 1;
      let generation = 0;

      // Previous walk's node map (ref -> compact node) for field-level diffing,
      // and a signature index (sig -> ref) for re-association across node-swaps.
      let prevNodes = new Map();        // ref -> node (last emitted)
      let prevSigByKey = new Map();     // signature key -> ref (previous walk)
      let baselineSent = false;         // has a `base` gone out this generation?

      function elementFor(ref) {
        const w = rev.get(ref);
        if (!w) return null;
        const el = w.deref();
        if (!el || !el.isConnected) return null;
        return el;
      }

      // Stable-ish signature for re-association when an element object is fresh
      // (React reconciliation / innerHTML rebuild) but the logical control is the
      // same: (role, name, nth-of-role-among-siblings). uni-browser Phase-2b.
      function signature(el, role, name) {
        let nth = 0, sib = el;
        while ((sib = sib.previousElementSibling)) {
          if (sib.tagName === el.tagName) nth++;
        }
        let parentKey = "";
        const p = el.parentElement;
        if (p) parentKey = (p.tagName || "") + "/" + (p.id || "");
        return role + "|" + name + "|" + parentKey + "|" + nth;
      }

      // refFor: existing ref for this element object, else try to re-bind a
      // previous ref by signature (node-swap recovery), else mint a fresh ref.
      function refFor(el, role, name) {
        let ref = fwd.get(el);
        if (ref !== undefined) { rev.set(ref, new WeakRef(el)); return ref; }
        const sig = signature(el, role, name);
        const reused = prevSigByKey.get(sig);
        if (reused !== undefined && elementFor(reused) === null) {
          // The old element backing `reused` is dead → rebind that ref to this
          // fresh element so ref:N stays ref:N across the re-render.
          fwd.set(el, reused);
          rev.set(reused, new WeakRef(el));
          return reused;
        }
        ref = nextRef++;
        fwd.set(el, ref);
        rev.set(ref, new WeakRef(el));
        return ref;
      }

      // ---- role / name / interactable resolution (§3 pragmatic) -------------
      const INTERACTIVE_ROLES = new Set([
        "button","link","textbox","checkbox","radio","combobox","listbox",
        "menuitem","menuitemcheckbox","menuitemradio","option","switch","tab",
        "searchbox","slider","spinbutton"
      ]);

      function roleOf(el) {
        const explicit = el.getAttribute && el.getAttribute("role");
        if (explicit) return explicit.trim().split(/\s+/)[0];
        const tag = el.tagName.toLowerCase();
        switch (tag) {
          case "a": return el.hasAttribute("href") ? "link" : "generic";
          case "button": return "button";
          case "summary": return "button";
          case "select": return "combobox";
          case "textarea": return "textbox";
          case "option": return "option";
          case "h1": case "h2": case "h3": case "h4": case "h5": case "h6":
            return "heading";
          case "nav": return "navigation";
          case "main": return "main";
          case "header": return "banner";
          case "footer": return "contentinfo";
          case "input": {
            const t = (el.getAttribute("type") || "text").toLowerCase();
            if (t === "checkbox") return "checkbox";
            if (t === "radio") return "radio";
            if (t === "button" || t === "submit" || t === "reset") return "button";
            if (t === "search") return "searchbox";
            if (t === "range") return "slider";
            if (t === "number") return "spinbutton";
            if (t === "hidden") return "hidden";
            return "textbox";
          }
          default: return "generic";
        }
      }

      function textFromLabelledby(el) {
        const ids = (el.getAttribute("aria-labelledby") || "").trim();
        if (!ids) return "";
        return ids.split(/\s+/).map(function (id) {
          const t = document.getElementById(id);
          return t ? (t.innerText || t.textContent || "") : "";
        }).join(" ").trim();
      }

      function associatedLabel(el) {
        if (el.id) {
          const lab = document.querySelector('label[for="' + CSS.escape(el.id) + '"]');
          if (lab) return (lab.innerText || lab.textContent || "").trim();
        }
        let p = el.closest ? el.closest("label") : null;
        if (p) return (p.innerText || p.textContent || "").trim();
        return "";
      }

      function nameOf(el, role) {
        let n = (el.getAttribute && el.getAttribute("aria-label")) || "";
        if (!n) n = textFromLabelledby(el);
        const tag = el.tagName.toLowerCase();
        if (!n && (tag === "input" || tag === "textarea" || tag === "select")) {
          n = associatedLabel(el);
        }
        if (!n && tag === "img") n = el.getAttribute("alt") || "";
        if (!n && (tag === "input" || tag === "textarea")) {
          n = el.getAttribute("placeholder") || "";
        }
        if (!n) {
          // textContent only for leaf-ish / heading / link / button nodes — avoid
          // pulling whole-subtree text into a container's name.
          if (role === "heading" || role === "link" || role === "button" ||
              role === "option" || role === "menuitem" || role === "tab" ||
              el.children.length === 0) {
            n = el.innerText || el.textContent || "";
          }
        }
        n = (n || "").replace(/\s+/g, " ").trim();
        if (n.length > NAME_CAP) n = n.slice(0, NAME_CAP) + "…";
        return n;
      }

      function isInteractable(el, role) {
        const tag = el.tagName.toLowerCase();
        if (tag === "a" && el.hasAttribute("href")) return true;
        if (tag === "button" || tag === "select" || tag === "textarea") return true;
        if (tag === "input") {
          const t = (el.getAttribute("type") || "text").toLowerCase();
          return t !== "hidden";
        }
        if (tag === "summary") return true;
        if (INTERACTIVE_ROLES.has(role)) return true;
        if (el.hasAttribute && el.hasAttribute("onclick")) return true;
        const ti = el.getAttribute && el.getAttribute("tabindex");
        if (ti !== null && ti !== undefined && parseInt(ti, 10) >= 0) return true;
        if (el.isContentEditable) return true;
        try {
          if (getComputedStyle(el).cursor === "pointer" && el.children.length === 0) {
            return true;
          }
        } catch (e) {}
        return false;
      }

      function valueOf(el, role) {
        const tag = el.tagName.toLowerCase();
        if (tag === "input") {
          const t = (el.getAttribute("type") || "text").toLowerCase();
          if (t === "checkbox" || t === "radio") return el.checked ? "checked" : "";
          let v = el.value || "";
          if (v.length > NAME_CAP) v = v.slice(0, NAME_CAP) + "…";
          return v;
        }
        if (tag === "textarea") {
          let v = el.value || "";
          if (v.length > NAME_CAP) v = v.slice(0, NAME_CAP) + "…";
          return v;
        }
        if (tag === "select") {
          const o = el.options && el.options[el.selectedIndex];
          return o ? (o.textContent || "").trim() : "";
        }
        return undefined;
      }

      function stateOf(el) {
        const s = [];
        if (el.disabled || el.getAttribute("aria-disabled") === "true") s.push("disabled");
        if (el.checked || el.getAttribute("aria-checked") === "true") s.push("checked");
        if (el.getAttribute("aria-expanded") === "true") s.push("expanded");
        if (el.getAttribute("aria-selected") === "true" || el.selected) s.push("selected");
        if (el.readOnly || el.getAttribute("aria-readonly") === "true") s.push("readonly");
        return s.length ? s.join(",") : undefined;
      }

      // ---- visibility / pruning (§4) ----------------------------------------
      function isVisible(el) {
        if (el.getAttribute && el.getAttribute("aria-hidden") === "true") return false;
        if (el.hasAttribute && el.hasAttribute("hidden")) return false;
        let st;
        try { st = getComputedStyle(el); } catch (e) { return false; }
        if (st.display === "none" || st.visibility === "hidden" || parseFloat(st.opacity) === 0) {
          return false;
        }
        const r = el.getBoundingClientRect();
        if (r.width <= 0 || r.height <= 0) return false;
        return true;
      }

      function inViewport(rect) {
        const vh = window.innerHeight || document.documentElement.clientHeight;
        const vw = window.innerWidth || document.documentElement.clientWidth;
        const padY = vh * VIEWPORT_PAD, padX = vw * VIEWPORT_PAD;
        return rect.bottom >= -padY && rect.top <= vh + padY &&
               rect.right >= -padX && rect.left <= vw + padX;
      }

      // bbox-containment: inner box ≥99% inside outer (drop nested wrappers, §4.3)
      function contained(inner, outer) {
        const ix = Math.max(0, Math.min(inner.right, outer.right) - Math.max(inner.left, outer.left));
        const iy = Math.max(0, Math.min(inner.bottom, outer.bottom) - Math.max(inner.top, outer.top));
        const area = inner.width * inner.height;
        if (area <= 0) return false;
        return (ix * iy) / area >= 0.99;
      }

      // ---- the walk ---------------------------------------------------------
      // Pre-order DFS. Emits a flat array of compact nodes carrying depth `d`,
      // interactive index `i`, and a stable `ref`. Containers with no name and no
      // interactivity are skipped (children collapse up), per §4.2.
      function walk(opts) {
        const viewportOnly = !!opts.viewportOnly;
        const verbose = !!opts.verbose;
        const out = [];
        let interactiveIdx = 0;
        let truncated = 0;
        const interactableStack = []; // [{rect, ref}] for containment collapse

        function visit(el, depth) {
          if (out.length >= MAX_NODES) { truncated++; return; }
          if (!(el instanceof Element)) return;
          const tag = el.tagName.toLowerCase();
          if (tag === "script" || tag === "style" || tag === "noscript" ||
              tag === "template" || tag === "svg" || tag === "head") return;
          if (!isVisible(el)) return;

          const rect = el.getBoundingClientRect();
          if (viewportOnly && !inViewport(rect)) {
            // still descend? off-screen subtrees are skipped wholesale for tokens
            return;
          }

          const role = roleOf(el);
          if (role === "hidden") return;
          const name = nameOf(el, role);
          const interact = isInteractable(el, role);

          // Decide whether THIS element earns a line.
          const meaningful = interact || (name && role !== "generic") ||
                             role === "heading";
          let emittedRef = null;
          let childDepth = depth;

          if (meaningful || verbose) {
            // bbox-containment collapse: if an interactable sits ≥99% inside an
            // interactable ancestor already emitted, drop this wrapper.
            if (interact && interactableStack.length) {
              const top = interactableStack[interactableStack.length - 1];
              if (contained(rect, top.rect) && !name) {
                // skip emitting, but keep descending
              } else {
                emittedRef = emitNode(el, role, name, interact, rect, depth, out);
              }
            } else {
              emittedRef = emitNode(el, role, name, interact, rect, depth, out);
            }
            if (emittedRef !== null) childDepth = depth + 1;
          }

          const pushed = (emittedRef !== null && interact);
          if (pushed) interactableStack.push({ rect: rect, ref: emittedRef });
          for (let c = el.firstElementChild; c; c = c.nextElementSibling) {
            visit(c, childDepth);
          }
          if (pushed) interactableStack.pop();
        }

        function emitNode(el, role, name, interact, rect, depth, sink) {
          const ref = refFor(el, role, name);
          const node = { ref: ref, role: role, name: name, d: depth };
          if (interact) node.i = ++interactiveIdx;
          const v = valueOf(el, role);
          if (v !== undefined && v !== "") node.value = v;
          const st = stateOf(el);
          if (st) node.state = st;
          sink.push(node);
          return ref;
        }

        const root = document.body || document.documentElement;
        if (root) {
          for (let c = root.firstElementChild; c; c = c.nextElementSibling) {
            visit(c, 0);
          }
        }
        return { nodes: out, truncated: truncated };
      }

      // ---- serialisation (§6) -----------------------------------------------
      function esc(s) { return JSON.stringify(s === undefined ? "" : s); }

      function nodeKey(n) {
        // The fields a delta compares (NOT `i` — index churn is silent, §6.2).
        return n.role + "|" + n.name + "|" + (n.value || "") + "|" + (n.state || "") + "|" + n.d;
      }

      function baseLine(n) {
        // Full node as one NDJSON object.
        let o = '{"ref":' + n.ref + ',"role":' + esc(n.role) + ',"name":' + esc(n.name) + ',"d":' + n.d;
        if (n.i !== undefined) o += ',"i":' + n.i;
        if (n.value !== undefined) o += ',"value":' + esc(n.value);
        if (n.state !== undefined) o += ',"state":' + esc(n.state);
        return o + "}";
      }

      // Build the previous-walk indices and current-walk indices, diff by ref.
      function diff(curr) {
        const lines = [];
        const currByRef = new Map();
        for (const n of curr) currByRef.set(n.ref, n);

        // additions + mutations
        let i = 0;
        const order = curr; // emit order = walk order, so `after` is the prior emitted ref
        for (let idx = 0; idx < order.length; idx++) {
          const n = order[idx];
          const old = prevNodes.get(n.ref);
          if (!old) {
            // `+` add — anchor with the previous emitted ref (after) for placement
            let line = '{"op":"+","ref":' + n.ref + ',"role":' + esc(n.role) +
                       ',"name":' + esc(n.name) + ',"d":' + n.d;
            if (n.i !== undefined) line += ',"i":' + n.i;
            if (n.value !== undefined) line += ',"value":' + esc(n.value);
            if (n.state !== undefined) line += ',"state":' + esc(n.state);
            if (idx > 0) line += ',"after":' + order[idx - 1].ref;
            lines.push(line + "}");
          } else if (nodeKey(old) !== nodeKey(n)) {
            // `~` change — only the fields that differ (plus ref). `i`/index
            // churn is intentionally NOT a trigger on its own (see nodeKey).
            let line = '{"op":"~","ref":' + n.ref;
            if (old.role !== n.role) line += ',"role":' + esc(n.role);
            if (old.name !== n.name) line += ',"name":' + esc(n.name);
            if ((old.value || "") !== (n.value || "")) line += ',"value":' + esc(n.value || "");
            if ((old.state || "") !== (n.state || "")) line += ',"state":' + esc(n.state || "");
            if (old.d !== n.d) line += ',"d":' + n.d;
            lines.push(line + "}");
          }
        }
        // removals: refs present last walk, absent now
        for (const ref of prevNodes.keys()) {
          if (!currByRef.has(ref)) lines.push('{"op":"-","ref":' + ref + "}");
        }
        return lines;
      }

      // Commit the current walk as the new "previous" state.
      function commit(curr) {
        prevNodes = new Map();
        prevSigByKey = new Map();
        for (const n of curr) {
          prevNodes.set(n.ref, n);
          const el = elementFor(n.ref);
          if (el) prevSigByKey.set(signature(el, n.role, n.name), n.ref);
        }
      }

      // ---- public entry points ----------------------------------------------
      function snapshot(opts) {
        opts = opts || {};
        const w = walk(opts);
        const curr = w.nodes;
        const header = { url: location.href, title: document.title || "", count: curr.length };

        const forceBase = !!opts.full || !baselineSent;
        let lines;
        let isBase;

        if (forceBase) {
          isBase = true;
          const head = '{"v":1,"op":"base","url":' + esc(header.url) +
                       ',"title":' + esc(header.title) + ',"count":' + curr.length +
                       ',"gen":' + generation + "}";
          lines = [head];
          for (const n of curr) lines.push(baseLine(n));
        } else {
          const d = diff(curr);
          // Delta-size guard (§7): if the diff is ≥60% of a fresh baseline, send
          // a fresh base instead — cheaper and less confusing than a huge diff.
          if (d.length >= Math.max(8, Math.floor(curr.length * 0.6))) {
            isBase = true;
            const head = '{"v":1,"op":"base","url":' + esc(header.url) +
                         ',"title":' + esc(header.title) + ',"count":' + curr.length +
                         ',"gen":' + generation + ',"reason":"delta-too-large"}';
            lines = [head];
            for (const n of curr) lines.push(baseLine(n));
          } else {
            isBase = false;
            const head = '{"v":1,"op":"delta","gen":' + generation +
                         ',"changes":' + d.length + ',"count":' + curr.length + "}";
            lines = [head].concat(d);
          }
        }
        if (w.truncated > 0) lines.push('{"op":"note","truncated":' + w.truncated + "}");

        commit(curr);
        baselineSent = true;
        if (isBase) generation++;  // a fresh base opens a new generation window
        return lines.join("\n");
      }

      // Verify the live element behind `ref` still presents the (role,name) the
      // last walk recorded — stale-ref safety (§8.2). Returns the element or null.
      function verified(ref) {
        let el = elementFor(ref);
        const rec = prevNodes.get(ref);
        if (!el) {
          // one re-association attempt by recorded signature (§5.1)
          if (rec) {
            const want = signature(null, rec.role, rec.name); // can't compute nth w/o el
            // fall back to (role,name) scan among current candidates
            const cands = document.querySelectorAll("*");
            for (const c of cands) {
              if (!(c instanceof Element)) continue;
              const r = roleOf(c);
              if (r !== rec.role) continue;
              if (nameOf(c, r) === rec.name) {
                fwd.set(c, ref); rev.set(ref, new WeakRef(c));
                el = c; break;
              }
            }
          }
          if (!el) return null;
        }
        if (rec) {
          const curRole = roleOf(el);
          const curName = nameOf(el, curRole);
          if (curRole !== rec.role || curName !== rec.name) return "DIVERGED";
        }
        return el;
      }

      function click(ref) {
        const v = verified(ref);
        if (v === null) return "RefStale: ref:" + ref + " no longer resolves — re-snapshot.";
        if (v === "DIVERGED") return "RefStale: ref:" + ref + " now points at a different control — re-snapshot.";
        try {
          v.scrollIntoView({ block: "center", inline: "center" });
        } catch (e) {}
        try {
          const r = v.getBoundingClientRect();
          const cx = r.left + r.width / 2, cy = r.top + r.height / 2;
          const opt = { bubbles: true, cancelable: true, clientX: cx, clientY: cy, view: window };
          v.dispatchEvent(new MouseEvent("pointerdown", opt));
          v.dispatchEvent(new MouseEvent("mousedown", opt));
          v.dispatchEvent(new MouseEvent("mouseup", opt));
          v.dispatchEvent(new MouseEvent("click", opt));
          if (typeof v.click === "function") v.click();
          return "CLICKED ref:" + ref;
        } catch (e) {
          return "JSERR: " + ((e && e.message) ? e.message : String(e));
        }
      }

      function type(ref, text, enter) {
        const v = verified(ref);
        if (v === null) return "RefStale: ref:" + ref + " no longer resolves — re-snapshot.";
        if (v === "DIVERGED") return "RefStale: ref:" + ref + " now points at a different control — re-snapshot.";
        try {
          try { v.scrollIntoView({ block: "center" }); } catch (e) {}
          v.focus();
          if (v.isContentEditable) {
            v.textContent = text;
            v.dispatchEvent(new InputEvent("input", { bubbles: true, data: text }));
          } else {
            const proto = Object.getPrototypeOf(v);
            const desc = Object.getOwnPropertyDescriptor(proto, "value");
            if (desc && desc.set) { desc.set.call(v, text); } else { v.value = text; }
            v.dispatchEvent(new Event("input", { bubbles: true }));
            v.dispatchEvent(new Event("change", { bubbles: true }));
          }
          if (enter) {
            const k = { key: "Enter", code: "Enter", keyCode: 13, which: 13, bubbles: true, cancelable: true };
            v.dispatchEvent(new KeyboardEvent("keydown", k));
            v.dispatchEvent(new KeyboardEvent("keypress", k));
            v.dispatchEvent(new KeyboardEvent("keyup", k));
          }
          return "TYPED ref:" + ref + (enter ? " (Enter)" : "");
        } catch (e) {
          return "JSERR: " + ((e && e.message) ? e.message : String(e));
        }
      }

      return { snapshot: snapshot, click: click, type: type,
               elementFor: elementFor, _version: 1 };
    })();
    """#
}
