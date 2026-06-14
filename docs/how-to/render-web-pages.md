# Render web pages (HTML/CSS/JS/React) on a monitor

wasmcraft ships a small **web engine** — a C program compiled to
`wasm32-wasi` (`csrc/web/web.c`) that parses HTML and CSS, runs JavaScript
through an embedded [QuickJS](https://github.com/quickjs-ng/quickjs), lays the
document out into a character grid, and emits a line-based **draw protocol**.
A Lua app, `dist/browser.lua`, runs that engine through the interpreter and
paints the result onto a CC:Tweaked monitor (falling back to the terminal, or
to ASCII off CC).

```
index.html / style.css / app.js ─▶ web.wasm (HTML+CSS+QuickJS) ─▶ draw protocol ─▶ browser.lua ─▶ monitor
```

The engine grows in four stages but always speaks the same protocol, so the
renderer never changes:

| Stage | Capability |
|-------|------------|
| HTML + CSS | tags, a CSS subset (selectors `tag`/`.class`/`#id`, colours, `display`, `text-align`, `font-weight`, margins/padding, `width`), block + inline flow, styled word runs |
| JavaScript | `<script>` (inline or `src`) run in QuickJS against a DOM bound to the parsed tree — `getElementById`/`querySelector`/`createElement`/`createTextNode`, `appendChild`/`insertBefore`/`removeChild`, `textContent`/`nodeValue`, `setAttribute`, `style.*`, `console.log` |
| React | a real React app, bundled with a custom `react-reconciler` host config that targets the engine's DOM (no react-dom) |

## Render a static page

Put an `index.html` (and any linked `.css`) in a directory, then:

```
browser /path/to/site          # on a CC computer, with a monitor attached
tools/cobalt dist/browser.lua web/site/index.html   # from the repo (ASCII)
```

`browser` mounts the page's directory over WASI so the engine can `fopen`
`index.html` and the files it links. The page is laid out to the device width.

Flags: `--scale N` (monitor text scale), `--jit`/`--transpile`/`--auto`
(execution mode — `--jit` is much faster for JavaScript-heavy pages, and the
engine falls back automatically where bytecode is refused).

## Run JavaScript

```html
<div id="app">…</div>
<script>
  const el = document.getElementById('app');
  el.textContent = 'Hello from JavaScript! ' + [1,2,3].map(x => x*x).join(', ');
  el.style.color = 'lime';
</script>
```

The engine runs the script after parsing, then re-styles and lays out the
mutated DOM — exactly as a browser would. `console.log` goes to stderr, so it
never disturbs the page on the monitor.

## Run a React app

React is bundled at **build time** (the only step that needs Node); the bundle
runs in-game through QuickJS. Write ordinary React:

```jsx
// web/app/Counter.jsx
import React, { useState } from "react";
export function Counter() {
  const [n] = useState(3);
  return <h1 style={{ color: "lime" }}>Count is {n}</h1>;
}
```

`web/app/main.jsx` mounts it with a custom `react-reconciler` host config that
maps React's host operations onto the engine's DOM. Bundle and serve it:

```
tools/build-web                 # esbuild: web/app -> web/site/app.js
```

```html
<!-- web/site/react.html -->
<div id="root"></div>
<script src="app.js"></script>
```

```
browser --jit /path/to/site/react.html
```

React runs unmodified — function components, hooks, and JSX all work. Because
the engine has no macrotask event loop, `main.jsx` commits synchronously with
`reconciler.flushSync`; the engine provides microtask-based `setTimeout`
shims for React's scheduler.

### Interactivity

The engine is a **reactor**: after the first frame it stays alive, and
`browser.lua` forwards each monitor/terminal tap as a DOM `click` event
(`monitor_touch`/`mouse_click` → `web_event`). The engine hit-tests the tapped
cell to the element under it, fires its `onClick`/`addEventListener` handler,
lets React commit (`reconciler.flushSync`), re-lays out, and repaints — so a
`useState` counter updates live on the monitor:

```jsx
const [n, setN] = useState(0);
return <button onClick={() => setN(n + 1)}>[ + increment ]</button>;
```

Tap the button on the monitor to increment; press `Q` (or `Ctrl+T`) on the
computer to quit. Hit-testing is by block-element rectangle, so make tap targets
block-level (a `<button>` is). Plain-JS `addEventListener("click", …)` works the
same way.

!!! note "Performance"
    Running React through QuickJS through the pure-Lua interpreter is a
    one-time cost of tens of seconds (use `--jit`). It suits dashboards and
    static UIs rather than high-frequency redraws.

## See it on a real ComputerCraft screen

`tools/cc-screenshot` renders a page on a headless CraftOS-PC computer (the
real CC Lua VM) and captures the screen as text plus a faithful colour
screenshot (HTML built from the live blit buffer). See the script header for
the one-time CraftOS-PC build.

## What it is not

A deliberately small subset: no flexbox/grid/float, no network, no full HTML5
error recovery. The supported tags and properties are listed in the source
header of `csrc/web/web.c` and pinned by `test/web_test.lua` /
`test/web_js_test.lua`.
