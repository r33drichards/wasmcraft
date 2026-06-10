# Cobalt and ComputerCraft

The engine's primary target is a computer inside Minecraft. That target
shapes the codebase more than WebAssembly does.

## The VM: Cobalt

CC:Tweaked embeds [Cobalt](https://github.com/SquidDev/Cobalt), a Java
reimplementation of **Lua 5.1** with `bit32` added. Three consequences:

**The whole codebase is written in the 5.1 subset.** No integer division
operator, no bitwise operators, no `goto`, no integers at all — even when
running on Lua 5.4 locally, the code restricts itself to what Cobalt parses.
The one exception, `bit_native.lua` (a faster bit library using 5.3
operators), is embedded in the bundle as a *string* and `load()`-ed only on
VMs that can parse it; Cobalt uses its native `bit32` instead via the
`bit.lua` shim.

**Lua 5.1 bytecode is a usable compilation target.** This is the unlock for
the jit: Cobalt's loader accepts standard 5.1 chunks, so wasm functions can
become native Lua functions. It's also why the jit doesn't travel — 5.4 and
LuaJIT changed their bytecode formats.

**Local green isn't green.** `tools/cobalt` runs any script on the real
standalone jar (via a small Java harness, `CobaltRunner.java`), and
`tools/test` runs every test on both VMs. `test/probe_cobalt.lua` documents
the observed differences. A change only counts when both columns pass.

## The watchdog: yielding or dying

CC:Tweaked time-slices all computers cooperatively and **kills** any program
that runs too long without yielding ("too long without yielding"). A wasm
engine is exactly such a program, so cooperation is built in at both levels:

- **Interpreter:** `wasm.set_yield(fn, every)` invokes a hook every N
  instructions. The bundle auto-installs
  `os.queueEvent("wasmcraft_yield"); os.pullEvent("wasmcraft_yield")` at
  200 000 instructions when it detects CC — queueing and pulling a private
  event resets the watchdog and resumes in the same tick.
- **Jit:** compiled code can't count instructions cheaply, so the compiler
  injects a tick at **loop back-edges** (`compiler.yield_in_loops`). It is
  auto-enabled only under CC (detected by `os.queueEvent` existing);
  standalone Cobalt leaves it off for full speed.

This leaks into library design too: the Picat session pump must distinguish
its own "waiting for stdin" yields from watchdog yields and forward the
latter to CC's scheduler.

## Distribution: one file over HTTP

CC computers have no `package.path` and no package manager; what they do
have is an `http` API and a global `fs`. So:

- `tools/amalgamate` flattens all of `src/` into `dist/wasmcraft.lua` with a
  miniature `require` shim — one file to install.
- The deployable programs (`sqlsh`, `wcsql`, `picatd`, …) each begin with a
  tiny bootstrap that downloads what's missing from a paste store and finds
  files across the CC/standalone layouts.
- Caches need invalidation: `wasmcraft.version` is bumped on publish, and
  long-lived programs like `picatd` check it and re-download stale copies
  ("self-healing").

The exception is `picat.wasm` (5.3 MB): too big to fetch casually, so it
ships on a floppy disk that mounts at `/disk/` — and the `picatd`/`pic`
split exists precisely so only **one** computer on a network needs that
floppy.

## Why this is worth it

Because the payoff is absurd in the best way: real SQLite transactions and
a real constraint solver running on an in-game computer, written in nothing
but Lua, surviving chunk unloads, served over in-game wireless. The
constraints (5.1, doubles, watchdog, whole-file I/O) are what make the
engineering interesting.
