# Run a wasm module

Goal: execute a WASI command module (a program with a `_start`, e.g. anything
built with `zig cc -target wasm32-wasi` or wasi-sdk) from the command line.

## Standalone, from the repo

`run.lua` is the development runner:

```sh
# portable interpreter (works on any Lua)
lua run.lua wasm/hello.wasm arg1 arg2

# compiled to Lua source (loads everywhere, incl. CC:T >= 1.109)
tools/cobalt run.lua --transpile wasm/hello.wasm arg1 arg2

# compiled to Lua 5.1 bytecode (errors loudly where bytecode is refused)
tools/cobalt run.lua --jit wasm/hello.wasm arg1 arg2
```

Mode flags (mutually exclusive, last one wins):

- `--interp` — the interpreter (default); runs on any Lua.
- `--transpile` — compile functions to Lua *source*. Loads on every CC build
  and on lua5.4; on a Picat workload it benchmarks at parity with bytecode.
- `--jit` (alias `--compile`) — compile to Lua 5.1 bytecode. STRICT: errors
  loudly on VMs that refuse binary chunks (CC:Tweaked >= 1.109).
- `--auto` — opt-in fastest available: jit if loadable, else transpile, else
  the interpreter.

Program arguments after the module path are passed through as WASI argv,
with the module path as `argv[0]`.

## In ComputerCraft

The amalgamated bundle doubles as a runner program. With `dist/wasmcraft.lua`
on the computer as `wasmcraft`:

```
wasmcraft --transpile mymodule.wasm arg1 arg2
```

Use `--transpile` in-game: CC:Tweaked >= 1.109 refuses to load bytecode, so
`--jit` errors loudly on modern servers (check yours with the bctest probe or
`wasmcraft.can_jit()`). Both compiled modes inject yields at loop back-edges,
so long runs don't trip CC's "too long without yielding" watchdog.

## Exit codes

A module calling `proc_exit` unwinds cleanly. `run.lua` and the bundle print
`[module exited with code N]` for nonzero exits; from the library API,
`wasmcraft.run_wasi`/`run_file` return the exit code instead.

## Checking a module against a reference

The dev shell includes wasmtime as an oracle. If output differs, the bug is
on our side:

```sh
wasmtime wasm/compute.wasm
lua run.lua wasm/compute.wasm
```
