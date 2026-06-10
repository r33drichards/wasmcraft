# Run a wasm module

Goal: execute a WASI command module (a program with a `_start`, e.g. anything
built with `zig cc -target wasm32-wasi` or wasi-sdk) from the command line.

## Standalone, from the repo

`run.lua` is the development runner:

```sh
# portable interpreter (works on any Lua)
lua run.lua wasm/hello.wasm arg1 arg2

# on Cobalt, JIT-compiled (~7-13x faster)
tools/cobalt run.lua --jit wasm/hello.wasm arg1 arg2
```

Flags:

- `--jit` (alias `--compile`) — compile functions to Lua 5.1 bytecode.
  Cobalt only; other VMs fall back to the interpreter automatically.
- `--interp` — force the interpreter (the default).

Program arguments after the module path are passed through as WASI argv,
with the module path as `argv[0]`.

## In ComputerCraft

The amalgamated bundle doubles as a runner program. With `dist/wasmcraft.lua`
on the computer as `wasmcraft`:

```
wasmcraft --jit mymodule.wasm arg1 arg2
```

Use `--jit` in-game: Cobalt loads the emitted bytecode natively and the
compiler injects yields at loop back-edges, so long runs don't trip CC's
"too long without yielding" watchdog.

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
