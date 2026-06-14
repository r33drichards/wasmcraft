---
name: wasmcraft-browser
description: Render and build HTML/CSS/JavaScript/React pages for a ComputerCraft (CC:Tweaked) monitor using the wasmcraft web engine. Use when writing or running web pages or React apps for ComputerCraft, when editing the engine (csrc/web/), the renderer (dist/browser.lua, dist/webrender.lua), or the React app (web/app/), when bundling with tools/build-web, or when deploying the browser to a CC computer. Covers the draw protocol, the supported HTML/CSS/DOM subset, the reactor/event model, and the known gotchas.
---

# wasmcraft web engine (a browser for ComputerCraft)

A web page (HTML/CSS, JavaScript, or a React app) is rendered onto a CC:Tweaked
monitor by a C engine compiled to `wasm32-wasi` (with an embedded QuickJS),
executed by the pure-Lua wasmcraft interpreter, which emits a line-based **draw
protocol** that a Lua app paints to the screen.

```
page (index.html / app.css / app.js) ─► web.wasm (HTML+CSS parser + QuickJS)
   ─► draw protocol (stdout) ─► dist/browser.lua ─► CC monitor (or terminal / ASCII)
                ▲ events (monitor taps) ──────────────────────┘
```

Pipeline pieces:
- `wasm/web.wasm` — the engine (`csrc/web/web.c` + quickjs-ng). A **reactor**.
- `dist/wasmcraft.lua` — the pure-Lua wasm interpreter (the "engine bundle").
- `dist/browser.lua` + `dist/webrender.lua` — load `web.wasm`, render its frames
  to a monitor/terminal (ASCII off CC), and forward taps as events.

## Run a page locally (no Minecraft)

From the repo root (needs Java for `tools/cobalt`; everything else is committed):

```bash
tools/cobalt dist/browser.lua web/site/index.html        # HTML + CSS (ASCII out)
tools/cobalt dist/browser.lua web/site/js.html           # JavaScript (DOM via QuickJS)
tools/cobalt dist/browser.lua --jit web/site/react.html  # React (use --jit; ~60s)
tools/cobalt dist/browser.lua web/site/click.html        # plain-JS interactive
```

`browser.lua` flags: `--jit` / `--transpile` / `--auto` / `--interp` (execution
mode), `--scale N` (monitor text scale), `--engine M.wasm` (override engine path).
The page arg may be a file or a directory (uses `index.html`); the page's
directory is mounted so the engine can read linked `.css`/`.js`.

## Run the tests

```bash
tools/cobalt test/web_test.lua        # HTML/CSS layout golden
tools/cobalt test/web_js_test.lua     # JS DOM mutation
tools/cobalt test/web_event_test.lua  # reactor + click events
tools/cobalt test/webrender_test.lua  # the pure renderer (frame buffer/protocol)
```
(`tools/test` runs all `*_test.lua` on lua5.4 + Cobalt; the React render itself
is too slow to live in the suite, so it is verified manually.)

## Write a page

**HTML + CSS** — supported subset (the full list is in the header of
`csrc/web/web.c`; pinned by the tests):
- tags: `html head body div p span h1-3 a ul li br strong b em i code` +
  `style`, `script` (inline or `src`), `link rel=stylesheet`.
- CSS selectors `tag` / `.class` / `#id` / `*` (comma lists); properties
  `display(block|inline|none)`, `color`, `background[-color]`, `text-align`,
  `font-weight`, `margin[-top|-bottom]`, `padding[-left|right]`, `width`.
- colours: the 16 CC names + `#rgb`/`#rrggbb` mapped to the nearest of 16.
- block + inline flow; inline runs wrap and keep per-`<span>` colours.
- NOT supported: flex/grid/float, networking, full HTML5 error recovery.

**JavaScript** runs in QuickJS after parsing, against a DOM bound to the parsed
tree. Available DOM surface:
`document.getElementById/querySelector/createElement/createTextNode/body`;
`node.getAttribute/setAttribute/appendChild/insertBefore/removeChild`;
`node.textContent`/`nodeValue` (get/set); `node.style.color/backgroundColor/
background`; `node.addEventListener/removeEventListener`; `console.log`
(goes to **stderr**, never the draw protocol).

## Write a React app

Edit `web/app/Counter.jsx` (ordinary React: function components, hooks, JSX),
then bundle (needs Node — build time only):

```bash
tools/build-web                # esbuild: web/app -> web/site/app.js
tools/cobalt dist/browser.lua --jit web/site/react.html
```

`web/app/main.jsx` mounts the app with a **custom `react-reconciler` host
config** that maps React's host ops onto the engine's DOM — there is no
react-dom. Because the engine has no macrotask loop, `main.jsx` commits with
`reconciler.flushSync` and exposes `globalThis.__wasmcraft_flush` (the engine
calls it after events). React core is unmodified.

## Interactivity (events)

The engine is a reactor. After the first frame, `browser.lua` forwards each
`monitor_touch`/`mouse_click` as `web_event("click", x-1, y-1)`. The engine
hit-tests the cell to the deepest **block** element, fires its `onClick` /
`addEventListener("click", …)` handler, lets React commit (`flushSync`),
re-lays out, and repaints. `useState` counters update live.

```jsx
const [n, setN] = useState(0);
<button onClick={() => setN(n + 1)}>[ + increment ]</button>
```
Tap targets must be block-level (a `<button>` is). Quit with `Q` / `Ctrl+T`.

## Reactor / draw-protocol contract (for driving the engine directly)

Exports: `_initialize`, then `web_init(pagePtr, width)` (render frame 1),
`web_event(typePtr, x, y)` (deliver event, re-render), `web_malloc`/`web_free`
(marshal C strings). stdout carries the draw protocol; stderr carries
`console.log`. Drive it like `dist/browser.lua` does:

```lua
inst:call("_initialize")
local function wstr(s) local p=inst:call("web_malloc",#s+1)
  inst.memory:storestr(p,s); inst.memory:set8(p+#s,0); return p end
local pp=wstr("index.html"); inst:call("web_init", pp, 51); inst:call("web_free", pp)
```

Draw protocol (one frame, line-based; palette = blit indices 0..15,
0=white..15=black):
```
SIZE cols rows          CLEAR bg          RECT x y w h bg
T x y fg bg <text>      FRAME END
```

## Build the engine

`tools/build-fixtures` compiles `wasm/web.wasm` with
`zig cc -target wasm32-wasi -mexec-model=reactor -DWEB_JS …` (it fetches
quickjs-ng like it fetches SQLite). Equivalent clang invocation (needs a WASI
sysroot + the quickjs sources at `$QJS`):

```bash
clang --target=wasm32-wasi --sysroot=$SYSROOT -mexec-model=reactor -O2 \
  -DWEB_JS -DCONFIG_VERSION='"ng"' \
  -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_PROCESS_CLOCKS -D_WASI_EMULATED_MMAN \
  -Icsrc/web -I$QJS -o wasm/web.wasm \
  csrc/web/web.c $QJS/{quickjs,libregexp,libunicode,cutils,xsum}.c \
  -lwasi-emulated-signal -lwasi-emulated-process-clocks -lwasi-emulated-mman
```
JS is optional behind `-DWEB_JS`; without it you get the HTML/CSS-only engine.

## Deploy to a real CC computer (wget)

Files needed on the computer's root: `wasmcraft` (= `dist/wasmcraft.lua`),
`browser.lua`, `webrender.lua`. The big files (`web.wasm`, the page, `app.js`)
can live on a disk drive to save space; point `--engine` at them:

```
wget <raw>/dist/wasmcraft.lua wasmcraft
wget <raw>/dist/browser.lua   browser.lua
wget <raw>/dist/webrender.lua webrender.lua
wget <raw>/wasm/web.wasm      /disk/web.wasm
wget <raw>/web/site/react.html /disk/react.html
wget <raw>/web/site/app.js     /disk/app.js
browser --transpile --engine /disk/web.wasm /disk/react.html
```
`<raw>` = `https://raw.githubusercontent.com/<owner>/wasmcraft/refs/heads/<branch>`.

## Gotchas

- **In-game React is slow.** CC:Tweaked ≥1.109 refuses Lua bytecode, so use
  `--transpile` (not `--jit`) in-game; React's first render is tens of seconds
  and each tap re-renders (seconds). Desktop `--jit` is fast. Plain-JS
  `addEventListener` pages react far quicker — prefer them for snappy UIs.
- `console.log` must stay on **stderr**; never feed engine stderr into the draw
  parser or it corrupts frames (`browser.lua` keeps them separate).
- The `<script>` buffer grows dynamically (React bundles are ~200 KB); a fixed
  buffer would silently drop large bundles.
- Hit-testing is by **block-element rectangle**; inline click targets are
  approximate — make buttons block-level.
- Commit `wasm/web.wasm` and `web/site/app.js` (build artifacts) so the demo and
  in-game install work without a zig/Node toolchain, like the other wasm
  binaries in this repo.

## Verify on a real CC screen

`tools/cc-screenshot [page]` renders a page on a headless CraftOS-PC computer
and captures the screen as text + a colour HTML screenshot (built from the live
blit buffer). `MODE=--auto`/`--interp` and `TIMEOUT=<secs>` env vars handle
JS/React-heavy pages. See the script header for the one-time CraftOS-PC build.

## Key files

- `csrc/web/web.c` — the engine (HTML/CSS parse, layout, QuickJS DOM, reactor).
- `csrc/web/draw.h` — the draw-protocol emitter.
- `dist/browser.lua` — host driver + event loop. `dist/webrender.lua` — pure
  renderer (frame buffer + protocol parser; no CC deps; unit-tested).
- `web/app/{Counter,main}.jsx` — the React app + custom reconciler.
- `web/site/{index,js,react,click}.html` — demo pages. `tools/build-web` —
  React bundler. `tools/build-fixtures` — engine build. `tools/cc-screenshot` —
  real-CC capture.
- Docs: `docs/how-to/render-web-pages.md`.
