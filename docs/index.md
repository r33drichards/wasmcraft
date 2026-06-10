# wasmcraft

A WebAssembly engine written in pure Lua, built to run inside
[CC:Tweaked](https://tweaked.cc/) (the ComputerCraft mod for Minecraft) and on
standalone Lua 5.4 / [Cobalt](https://github.com/SquidDev/Cobalt). It executes
real wasi-libc binaries — including SQLite and the Picat constraint solver —
on a Lua VM whose only number type is a double.

```
.wasm bytes ──► decoder ──► interp   (portable, runs anywhere)
                      └───► compiler ──► Lua 5.1 bytecode  (Cobalt only, ~7-13x)
```

## Where to start

The documentation follows the [Diátaxis](https://diataxis.fr/) structure:

<div class="grid cards" markdown>

- **[Tutorials](tutorials/getting-started.md)** — learning-oriented.
  Run your first wasm module, then put a SQL shell on an in-game computer.

- **[How-to guides](how-to/run-a-wasm-module.md)** — task-oriented recipes.
  Embed the engine, persist a SQLite database, serve Picat over rednet,
  run the test suite.

- **[Reference](reference/lua-api.md)** — the dry facts.
  Every public Lua API, the WASI host surface, the CLI tools.

- **[Explanation](explanation/architecture.md)** — why it is the way it is.
  The two execution modes, the Lua 5.1 constraint, persistence through
  CC's filesystem.

</div>

## What it can do

- Decode and execute core WebAssembly: i32/i64/f32/f64 arithmetic and
  conversions, structured control, `br_table`, direct and indirect calls,
  globals, linear memory and bulk-memory ops — with i64 emulated as
  high/low 32-bit pairs on top of doubles.
- Boot unmodified **WASI preview1 command modules** (wasi-libc `_start`)
  and **reactor modules** (`_initialize` + exports).
- Persist real files through WASI — SQLite writes an ordinary `.db` file to
  the host (or to a ComputerCraft computer's disk).
- Compile wasm functions to **Lua 5.1 bytecode** that Cobalt loads natively,
  for a ~7–13× speedup over the interpreter in-game.
- Cooperate with CC:Tweaked's *"too long without yielding"* watchdog by
  injecting yields at loop back-edges and instruction-count ticks.
