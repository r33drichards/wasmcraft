# wasmcraft

A WebAssembly engine written in pure Lua. It decodes `.wasm` binary modules
and executes them — on standalone Lua 5.3/5.4, on
[Cobalt](https://github.com/SquidDev/Cobalt), and inside
[CC:Tweaked](https://tweaked.cc/) (the ComputerCraft mod for Minecraft),
where Cobalt is the VM and wasmcraft can JIT to its native bytecode.

```
.wasm bytes ──► decoder ──► interp   (portable, runs anywhere)
                      └───► compiler ──► Lua 5.1 bytecode  (Cobalt only, ~7-13x)
```

## The engine

- Decodes and executes core WebAssembly: i32/i64/f32/f64 arithmetic and
  conversions, structured control, `br_table`, direct and indirect calls,
  globals, linear memory and bulk-memory ops — with i64 emulated as
  high/low 32-bit pairs on top of doubles.
- Boots unmodified **WASI preview1 command modules** (wasi-libc `_start`)
  and **reactor modules** (`_initialize` + exports), with a real filesystem
  behind WASI so programs persist ordinary files.
- Compiles wasm functions to **Lua 5.1 bytecode** that Cobalt loads
  natively — per-function, lazily, with automatic interpreter fallback.
- Cooperates with CC:Tweaked's *"too long without yielding"* watchdog via
  instruction-count hooks (interpreter) and loop back-edge ticks (jit).
- Is differentially tested against wasmtime, on both Lua 5.4 and the real
  Cobalt VM.

## Built on wasmcraft

Because the engine runs real wasi-libc binaries, real software follows.
These ship in `dist/` as applications **on top of** the engine — ordinary
clients of its public API, separate from wasmcraft itself:

- **SQLite** — `wq.wasm` (SQLite compiled to a wasm reactor) plus the
  `wcsql`/`sqlsh` front-ends: a database library and interactive shell
  with on-disk persistence, in Minecraft.
- **Picat** — the constraint/planning solver as `picat.wasm`, runnable
  one-shot, in warm REPL sessions, or served network-wide by the
  `picatd`/`pic` rednet daemon.

## Where to start

The documentation follows the [Diátaxis](https://diataxis.fr/) structure:

<div class="grid cards" markdown>

- **[Tutorials](tutorials/getting-started.md)** — learning-oriented.
  Run your first wasm module, then put a SQL shell on an in-game computer.

- **[How-to guides](how-to/install.md)** — task-oriented recipes.
  Install wasmcraft, embed the engine, persist a SQLite database, serve
  Picat over rednet, run the test suite.

- **[Reference](reference/lua-api.md)** — the dry facts.
  Every public Lua API, the WASI host surface, the CLI tools.

- **[Explanation](explanation/architecture.md)** — why it is the way it is.
  A code-level tour of the engine, the Lua 5.1 constraint, persistence
  through CC's filesystem.

</div>
