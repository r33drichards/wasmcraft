# Design: `web_message` — a host→JS data channel for the web engine

Date: 2026-06-14
Repo: wasmcraft (substrate half of the crabcraft cardui feature)
Companion design: crabcraft `docs/plans/2026-06-14-cardui-react-gate-design.md`

## Problem

The web engine (`csrc/web/web.c`, QuickJS + custom react-reconciler) can render
React onto a CC monitor and accept taps, but it has **no way for the Lua host to
push data into the running page**. The three existing exports that touch the page
are `web_init(page, width)` (mount, re-runs the script — slow) and
`web_event(type, x, y)` (deliver a tap). Investigation of `web_event` shows two
hard limits that block using it as a data channel:

1. `dispatch()` calls the JS listener with **zero arguments**
   (`JS_Call(ctx, fn, JS_UNDEFINED, 0, NULL)`), so a handler cannot read any
   event payload — it only learns *that* a `(node, type)` listener fired.
2. The listener `type` is capped at **15 chars** (`Listener.type[16]` +
   `strncpy(..., 15)`), so data cannot be smuggled in the type string either.

JS has no `fetch`/`fopen`, so the host cannot drop a file for the page to read.

The crabcraft "cardui" feature needs the host to send the page rich, dynamic
data: the username/role on a successful card verify, the freshly-minted
`user_id` on enrollment, and human-readable error/status strings. None of that
fits through the current surface.

## Goal

Add a minimal, general host→JS channel that carries **arbitrary JSON** into the
running page without remounting React, and leaves every existing contract
(`web_init`, `web_event`, the draw protocol, `browser.lua`, `webrender.lua`,
existing pages) unchanged.

## Design

### New export: `web_message(const char *json)`

```c
// csrc/web/web.c
static char G_hostmsg[2048];                       // last host message (JSON)

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
      if (JS_IsException(r)) { /* log to stderr like dispatch() does */ }
      JS_FreeValue(G_ctx, r);
    }
    JS_FreeValue(G_ctx, f);
    JS_FreeValue(G_ctx, glob);
    drain_jobs();                                   // flush microtasks
  }
#endif
  full_restyle();
  emit_frame();                                     // same tail as web_event
}
```

Notes:
- Sets `globalThis.__hostmsg` to the JSON string, then calls the JS hook
  `globalThis.__wasmcraft_message` (installed by `main.jsx`, mirroring the
  existing `__wasmcraft_flush`). The hook reads `__hostmsg`, parses it, applies
  it (a React `setState`), and `flushSync`-commits.
- No DOM node / `hit_test` needed — this is a page-global signal, not a tap.
- Re-emits a frame so the host sees the updated UI immediately, exactly like
  `web_event` does.
- Buffer is fixed at 2 KB (status/identity JSON is tiny). If a future caller
  needs more, raise the buffer or malloc; out of scope here.
- Behind `#ifdef WEB_JS` for the data path; the HTML/CSS-only engine still
  exports the symbol (it just restyles/repaints) so the host can call it
  unconditionally.

### `main.jsx` hook

```js
// installed alongside the existing globalThis.__wasmcraft_flush
let onHostMsg = () => {};                 // registered by the app (CardApp)
globalThis.__registerHostMsg = (fn) => { onHostMsg = fn; };
globalThis.__wasmcraft_message = () =>
  reconciler.flushSync(() => {
    try { onHostMsg(JSON.parse(globalThis.__hostmsg || "{}")); }
    catch (e) { console.log("hostmsg parse error: " + e); }   // stderr only
  });
```

React core stays unmodified; this is the same `flushSync` discipline already
used for events. An app registers its handler with
`globalThis.__registerHostMsg(setStateFn)`.

### Host side (driver)

`browser.lua`'s `wstr` + `inst:call` is enough; the cardui program (crabcraft)
will wrap it:

```lua
local function web_message(inst, tbl)
  local p = wstr(inst, textutils.serializeJSON(tbl))
  inst:call("web_message", p); inst:call("web_free", p)
end
```

(`browser.lua` itself does not need this; only the cardui kiosk does. We add the
export to the engine and the hook to `main.jsx`; the kiosk lives in crabcraft.)

## What does NOT change

- `web_init`, `web_event`, `web_malloc`, `web_free` signatures and behavior.
- The line-based draw protocol and `webrender.lua`.
- `browser.lua` (still renders any page; gains nothing, loses nothing).
- All existing demo pages and the `Counter` React app.

## Build & release

1. Implement the export + `main.jsx` hook.
2. Rebuild the React bundle if `main.jsx` changed: `tools/build-web`.
3. Rebuild the engine: `tools/build-fixtures` (zig + quickjs-ng) → `wasm/web.wasm`.
4. Commit the rebuilt `wasm/web.wasm` and `web/site/app.js` (repo convention:
   build artifacts are committed so in-game installs need no toolchain).
5. Cut a wasmcraft release so crabcraft's cardui can `wget` the new `web.wasm`.

## Testing

- **New:** `test/web_message_test.lua` (Cobalt + lua5.4 via `tools/test`):
  drive `web_init` on a tiny page whose script registers
  `__registerHostMsg(m => setText(m.text))`, then call
  `web_message('{"text":"hello"}')` and assert the emitted frame contains
  "hello". A second message asserts the frame updates again (no remount).
- **Regression:** `tools/test` must stay green — `web_test`, `web_js_test`,
  `web_event_test`, `webrender_test` unchanged.
- React render itself stays out of the suite (too slow), verified manually with
  `tools/cc-screenshot` against the cardui page from crabcraft.

## Risks / open points

- **Buffer size**: 2 KB is ample for identity/status JSON; documented as the cap.
- **Re-entrancy**: `web_message` must not be called from inside a JS callback
  (it isn't — the host calls it between `os.pullEvent` turns).
- **`drain_jobs`/`flush_react` parity**: reuse the exact microtask-drain the
  event path uses so promise-based React work commits identically.
