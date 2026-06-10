# Getting started

In this tutorial you will run a real C program — compiled to WebAssembly —
on a Lua interpreter, three different ways: on Lua 5.4, on the Cobalt VM
(the engine ComputerCraft uses), and JIT-compiled on Cobalt. By the end you
will have run the test suite and know your checkout works.

You need [Nix](https://nixos.org/download/) installed. Everything else
(Lua 5.4, a JDK for Cobalt, wabt, wasmtime) comes from `shell.nix`.

## 1. Enter the dev shell

From the project root:

```sh
nix-shell
```

The first run downloads the toolchain; subsequent runs are instant. All
commands below assume you are inside this shell (or prefix them with
`nix-shell --run "..."`).

## 2. Run hello.wasm on Lua 5.4

`wasm/hello.wasm` is `csrc/hello.c` compiled with `zig cc -target wasm32-wasi`.
`run.lua` loads a WASI command module and calls its `_start`:

```sh
lua run.lua wasm/hello.wasm
```

You should see the program's output printed by the interpreter. Nothing
about the module was modified — wasi-libc's startup, stdio, and exit all go
through the WASI host in `src/wasi.lua`.

## 3. Run it on Cobalt — the real target

Cobalt is the Lua VM embedded in CC:Tweaked. `tools/cobalt` compiles a small
Java harness (once) and runs any Lua script on the standalone Cobalt jar:

```sh
tools/cobalt run.lua wasm/hello.wasm
```

Same output. This matters because Cobalt is Lua 5.1 with `bit32` — a much
smaller language than Lua 5.4 — and it is the VM your code will actually run
on in-game.

## 4. Turn on the JIT

On Cobalt, wasmcraft can compile each wasm function to Lua 5.1 bytecode
instead of interpreting it:

```sh
tools/cobalt run.lua --jit wasm/hello.wasm
```

For a module this small you won't feel the difference, so try something
heavier — SQLite creating a table, inserting, and querying:

```sh
time tools/cobalt run.lua wasm/sqlite.wasm              # interpreted
time tools/cobalt run.lua --jit wasm/sqlite.wasm        # bytecode, ~7-13x faster
time tools/cobalt run.lua --transpile wasm/sqlite.wasm  # Lua source, same ballpark
```

Modes are explicit: `--jit` errors loudly on VMs that refuse Lua 5.1 bytecode
(Lua 5.4, CC:Tweaked >= 1.109) — use `--transpile` there (source loads
everywhere), or opt into `--auto` to pick the fastest available.

## 5. Run the test suite

```sh
tools/test
```

Every `test/*_test.lua` runs twice — once on `lua` (5.4, fast) and once on
`tools/cobalt` (the real target). A green run ends with:

```
== all green ==
```

## Where to go next

- Put a SQL shell on an in-game computer:
  [SQLite in ComputerCraft](sqlite-in-computercraft.md)
- Use the engine from your own Lua code:
  [Embed the engine](../how-to/embed-the-engine.md)
- Understand the two execution modes:
  [Architecture](../explanation/architecture.md)
