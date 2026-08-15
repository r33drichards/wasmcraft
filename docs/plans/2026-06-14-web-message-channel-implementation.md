# web_message Host→JS Channel — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a `web_message(json)` export to the wasmcraft web engine so the Lua host can push arbitrary JSON into a running React page without remounting it.

**Architecture:** A new C export stores the JSON in a global, exposes it as `globalThis.__hostmsg`, calls a JS hook `globalThis.__wasmcraft_message` (installed by `main.jsx`, mirroring the existing `__wasmcraft_flush`), then re-styles and re-emits a frame — the exact tail `web_event` already uses. Plain-JS pages can register `__wasmcraft_message` directly (used by the test); React pages register via a new `globalThis.__registerHostMsg(setStateFn)` in `main.jsx`.

**Tech Stack:** C (QuickJS-ng embed, `zig cc -target wasm32-wasi`), Lua test harness (lua5.4 + Cobalt), esbuild/Node (React bundle).

**Design:** `docs/plans/2026-06-14-web-message-host-channel-design.md`

**Conventions (read before starting):**
- All commands run from the repo root **inside nix-shell** (provides `lua`, `zig`, Java for Cobalt): prefix with `nix-shell --run "…"`. The `.claude` rule "use nix" applies.
- `tools/test` greps each test's output for `ALL_PASS` (and absence of `FAILED`). The harness (`test/harness.lua`) prints `N/M assertions passed` then `ALL_PASS`/`FAILED`.
- Build artifacts (`wasm/web.wasm`, `web/site/app.js`) are **committed** — in-game installs ship with no toolchain. Every task that changes them re-commits them.

---

### Task 1: Failing engine test for `web_message`

A plain-JS page (no React — fast, `interp` mode) that installs `__wasmcraft_message` and copies `__hostmsg` into the DOM. Proves the C plumbing end to end.

**Files:**
- Create: `web/site/hostmsg.html`
- Create: `test/web_message_test.lua`

**Step 1: Create the test page**

`web/site/hostmsg.html`:
```html
<body>
  <div id="out">none</div>
  <script>
    // The host calls globalThis.__wasmcraft_message after setting __hostmsg.
    // (React pages get this hook from main.jsx; a plain page installs it itself.)
    globalThis.__wasmcraft_message = function () {
      var m;
      try { m = JSON.parse(globalThis.__hostmsg || "{}"); } catch (e) { m = {}; }
      document.getElementById("out").textContent = "msg:" + (m.text || "?");
    };
  </script>
</body>
```

**Step 2: Write the failing test**

`test/web_message_test.lua` (mirrors `test/web_event_test.lua`):
```lua
-- Test the host->JS data channel: render a plain-JS page, call web_message with
-- JSON, and assert the page read globalThis.__hostmsg and re-rendered. Exercises
-- the web_message export + __wasmcraft_message hook + re-layout. Requires the
-- WEB_JS build; skips otherwise.
package.path = "src/?.lua;test/?.lua;" .. package.path
local T = require("harness")
local wasm = require("wasm")
local wasi = require("wasi")
T.start("web_message")

local f = assert(io.open("wasm/web.wasm", "rb"), "wasm/web.wasm missing (run tools/build-fixtures)")
local bytes = f:read("*a"); f:close()

local out = {}
local host = wasi.make({
  write = function(s) out[#out + 1] = s end,
  writeerr = function() end,
  args = { "web.wasm" },
  root = "web/site",
})
local inst = wasm.instantiate(wasm.load(bytes), { wasi_snapshot_preview1 = host }, { mode = "interp" })
inst:call("_initialize")
local function wstr(s) local p = inst:call("web_malloc", #s + 1); inst.memory:storestr(p, s); inst.memory:set8(p + #s, 0); return p end
local function frame() local s = table.concat(out); out = {}; return s end

local pp = wstr("hostmsg.html"); inst:call("web_init", pp, 51); inst:call("web_free", pp)
local f0 = frame()

-- skip on a non-WEB_JS engine (the script never runs, so "none" stays but the
-- export may also be absent); detect JS by whether the initial DOM rendered.
if f0:find("none", 1, true) == nil then
  print("web_message: unexpected initial frame — aborting"); T.done(); return
end
T.ok(f0:find("none", 1, true) ~= nil, "initial state rendered (none)")

local function message(json)
  local p = wstr(json); inst:call("web_message", p); inst:call("web_free", p)
  return frame()
end

local f1 = message('{"text":"hello"}')
T.ok(f1:find("msg:hello", 1, true) ~= nil, "web_message delivers JSON -> msg:hello")
local f2 = message('{"text":"again"}')
T.ok(f2:find("msg:again", 1, true) ~= nil, "second web_message updates without remount -> msg:again")

T.done()
```

**Step 3: Run the test to verify it FAILS**

Run: `nix-shell --run "tools/cobalt test/web_message_test.lua"`
Expected: FAIL — `inst:call("web_message", …)` errors because the export does not exist yet (e.g. "no such export 'web_message'" / nil function), so `FAILED` prints.

**Step 4: Commit the failing test**

```bash
git add web/site/hostmsg.html test/web_message_test.lua
git commit -m "test: failing web_message host->JS channel test + page"
```

---

### Task 2: Implement the `web_message` export

**Files:**
- Modify: `csrc/web/web.c` (insert after `web_event`, currently ending line 1027)
- Rebuild: `wasm/web.wasm`

**Step 1: Add the export**

In `csrc/web/web.c`, immediately after the closing `}` of `web_event` (line 1027) and before the `int main(...)` comment block (line 1029), insert:

```c
// deliver a host message: stash JSON in globalThis.__hostmsg, call the JS hook
// globalThis.__wasmcraft_message (React installs it via main.jsx; plain pages
// may install it directly), then re-style + re-emit — the web_event tail. This
// is the host->JS data channel: event handlers get 0 args and 15-char types, so
// rich data (identity, ids, status) rides here instead. See docs/plans/
// 2026-06-14-web-message-host-channel-design.md.
static char G_hostmsg[2048];
EXPORT("web_message") void web_message(const char *json) {
  size_t n = json ? strlen(json) : 0;
  if (n >= sizeof G_hostmsg) n = sizeof G_hostmsg - 1;
  memcpy(G_hostmsg, json ? json : "", n);
  G_hostmsg[n] = 0;
#ifdef WEB_JS
  if (G_ctx) {
    JSValue glob = JS_GetGlobalObject(G_ctx);
    JS_SetPropertyStr(G_ctx, glob, "__hostmsg", JS_NewString(G_ctx, G_hostmsg));
    JSValue f = JS_GetPropertyStr(G_ctx, glob, "__wasmcraft_message");
    if (JS_IsFunction(G_ctx, f)) {
      JSValue r = JS_Call(G_ctx, f, JS_UNDEFINED, 0, NULL);
      if (JS_IsException(r)) {
        JSValue e = JS_GetException(G_ctx); const char *s = JS_ToCString(G_ctx, e);
        fprintf(stderr, "web_message handler error: %s\n", s ? s : "?");
        if (s) JS_FreeCString(G_ctx, s); JS_FreeValue(G_ctx, e);
      }
      JS_FreeValue(G_ctx, r);
    }
    JS_FreeValue(G_ctx, f);
    JS_FreeValue(G_ctx, glob);
    drain_jobs();
  }
#endif
  full_restyle();
  emit_frame();
}
```

Notes:
- `G_ctx`, `drain_jobs`, `JS_*` are only referenced inside `#ifdef WEB_JS`, so the non-JS engine build still compiles (the export exists and just restyles/repaints).
- `full_restyle()` (line 446) and `emit_frame()` (line 963) are outside the JS ifdef and always available — matching `web_event`'s tail.

**Step 2: Rebuild the engine**

Run: `nix-shell --run "tools/build-fixtures"`
Expected: fetches quickjs-ng if needed, compiles `wasm/web.wasm` (the `zig cc … -DWEB_JS …` line), no errors. `wasm/web.wasm` mtime updates.

**Step 3: Run the test to verify it PASSES**

Run: `nix-shell --run "tools/cobalt test/web_message_test.lua"`
Expected: `3/3 assertions passed` then `ALL_PASS`.

Also run on lua5.4: `nix-shell --run "lua test/web_message_test.lua"` → `ALL_PASS`.

**Step 4: Run the full web suite — no regressions**

Run: `nix-shell --run "tools/test web"`
Expected: `web_test`, `web_js_test`, `web_event_test`, `webrender_test`, `web_message_test` all `ok` on both lua54 and cobalt; `== all green ==`.

**Step 5: Commit**

```bash
git add csrc/web/web.c wasm/web.wasm
git commit -m "feat(web): web_message(json) host->JS data channel"
```

---

### Task 3: `main.jsx` hook for React pages

So a React app can receive host messages and `setState`.

**Files:**
- Modify: `web/app/main.jsx` (after the `globalThis.__wasmcraft_flush` definition near the end)
- Rebuild: `web/site/app.js`

**Step 1: Add the hook**

At the end of `web/app/main.jsx`, after the existing `globalThis.__wasmcraft_flush = …` line, add:

```js
// Host->React data channel (paired with the engine's web_message export). An app
// registers a handler; web_message sets globalThis.__hostmsg then calls this,
// and we deliver the parsed JSON inside a synchronous flushSync commit.
let __onHostMsg = () => {};
globalThis.__registerHostMsg = (fn) => { __onHostMsg = fn; };
globalThis.__wasmcraft_message = () =>
  reconciler.flushSync(() => {
    try { __onHostMsg(JSON.parse(globalThis.__hostmsg || "{}")); }
    catch (e) { console.log("hostmsg parse error: " + e); }   // stderr only
  });
```

**Step 2: Rebuild the React bundle**

Run: `nix-shell --run "tools/build-web"` (needs Node/npm; installs esbuild into `.web-build` once)
Expected: writes `web/site/app.js`.

**Step 3: Verify the hook is in the bundle**

Run: `grep -c "__wasmcraft_message\|__registerHostMsg" web/site/app.js`
Expected: `>= 1` (both symbols present; esbuild keeps the global assignments).

**Step 4: Manual React smoke (optional but recommended)**

Run: `nix-shell --run "tools/cobalt dist/browser.lua --transpile web/site/react.html"`
Expected: the existing Counter still renders (the hook addition is inert for Counter). Confirms the bundle didn't break.

**Step 5: Commit**

```bash
git add web/app/main.jsx web/site/app.js
git commit -m "feat(web): main.jsx __registerHostMsg/__wasmcraft_message hook"
```

---

### Task 4: Document the channel in the browser skill

**Files:**
- Modify: `.claude/skills/wasmcraft-browser/SKILL.md`

**Step 1:** In the "Reactor / draw-protocol contract" section, add `web_message` to the exports list:
> `web_message(jsonPtr)` (host→JS: set `globalThis.__hostmsg`, call `globalThis.__wasmcraft_message`, re-render) …

**Step 2:** Add a short subsection after "Interactivity (events)":
```markdown
## Host → page data (web_message)

`web_event` handlers get **0 args** and a **15-char** type, so they can't carry
data. To push rich data into a running page, the host calls the `web_message`
export with a JSON string; the engine sets `globalThis.__hostmsg` and calls
`globalThis.__wasmcraft_message`. Plain JS installs that hook directly; React
apps register via `globalThis.__registerHostMsg((msg) => setState(msg))` (wired
in `web/app/main.jsx`). No remount — same restyle/repaint tail as an event.
```

**Step 3: Commit**

```bash
git add .claude/skills/wasmcraft-browser/SKILL.md
git commit -m "docs: document web_message host->page channel in browser skill"
```

---

### Task 5: Release the new engine

So crabcraft's cardui can `wget` the new `web.wasm`.

**Step 1:** Confirm the rebuilt binaries are committed (Tasks 2 & 3) and the suite is green:
Run: `nix-shell --run "tools/test"`
Expected: `== all green ==`.

**Step 2:** Push the branch and open a PR:
```bash
git push -u origin feature/web-message-channel
gh pr create -R r33drichards/wasmcraft --fill
```

**Step 3:** After merge, cut a release (the engine asset crabcraft depends on). Confirm the release workflow / tag scheme with the maintainer (this repo's release mechanism is not yet verified in this plan — **check `gh release list -R r33drichards/wasmcraft` and any `.github/workflows` before tagging**). Verify `web.wasm` is downloadable from `releases/latest/download/web.wasm`.

---

## Done when

- `web_message` ships in `wasm/web.wasm`, `tools/test` is green including `web_message_test`.
- `main.jsx` exposes `__registerHostMsg` and the rebuilt `app.js` is committed.
- The browser skill documents the channel.
- A wasmcraft release serves the new `web.wasm`, unblocking the crabcraft cardui plan.
