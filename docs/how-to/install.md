# Install wasmcraft

Goal: get wasmcraft running on your machine (or in your own Lua project),
outside of Minecraft. For the in-game install, see the
[SQLite in ComputerCraft tutorial](../tutorials/sqlite-in-computercraft.md) —
the `dist/` programs bootstrap themselves there.

## Requirements

A Lua VM that provides:

- `string.pack` / `string.unpack` (used for LEB128, IEEE floats, and memory
  reinterpretation), **and**
- either `bit32` or native bitwise operators.

In practice that means **Lua 5.3 or 5.4** (native operators), or **Cobalt
0.7.3+** (Lua 5.1 with `bit32` and `string.pack`). Plain PUC Lua 5.1/5.2 and
LuaJIT are not supported — they lack `string.pack`.

The engine is pure Lua: no C modules, nothing to compile.

## Option 1 — single file (recommended)

Everything ships in one amalgamated file. Download it and the SQLite
reactor (only needed if you want the database API):

```sh
curl -fsSLO https://github.com/r33drichards/wasmcraft/releases/latest/download/wasmcraft.lua
curl -fsSLO https://github.com/r33drichards/wasmcraft/releases/latest/download/wq.wasm
```

Use it as a library:

```lua
local wasmcraft = assert(loadfile("wasmcraft.lua"))()

-- run a WASI command module
wasmcraft.run_file("hello.wasm")

-- or open a SQLite database
local db = wasmcraft.opendb({ modulePath = "wq.wasm", path = "data.db" })
```

Or as a command-line runner:

```sh
lua wasmcraft.lua hello.wasm
```

!!! note
    The bundle is also what the ComputerCraft loaders download — it is the
    same file in both worlds.

## Option 2 — clone the repo

For development, hacking on the engine, or running the JIT on Cobalt:

```sh
git clone https://github.com/r33drichards/wasmcraft.git
cd wasmcraft
```

Add `src/` to the module path and require what you need:

```lua
package.path = "src/?.lua;" .. package.path
local wasm = require("wasm")
local wasi = require("wasi")
```

Or from the shell, without touching code:

```sh
export LUA_PATH="src/?.lua;;"
lua run.lua wasm/hello.wasm
```

With [Nix](https://nixos.org/download/) installed, `nix-shell` provides the
whole toolchain (Lua 5.4, JDK 21 for Cobalt, wabt, wasmtime) — and
`tools/cobalt` runs scripts on the real CC:Tweaked VM, where `--jit` mode
works:

```sh
nix-shell --run "tools/cobalt run.lua --jit wasm/hello.wasm"
```

## Verify the install

```sh
lua wasmcraft.lua hello.wasm        # option 1
lua run.lua wasm/hello.wasm         # option 2 (from the repo root)
```

A hello-world prints its output and exits 0. From the repo you can also run
the full test suite: `nix-shell --run "tools/test"`.

## Getting modules to run

Any `wasm32-wasi` command module works. Build your own from C in one line:

```sh
zig cc -target wasm32-wasi -Os -o hello.wasm hello.c
```

(or use wasi-sdk / clang with a wasi sysroot). The repo's `wasm/` directory
has ready-made fixtures — `hello.wasm`, `compute.wasm`, `sqlite.wasm` — and
[Rebuild fixtures](rebuild-artifacts.md) regenerates them from source.

## Next steps

- Drive modules from Lua: [Embed the engine](embed-the-engine.md)
- Use the database API: [Use SQLite from Lua](use-sqlite-from-lua.md)
- Run it in Minecraft: [SQLite in ComputerCraft](../tutorials/sqlite-in-computercraft.md)
