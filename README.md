# wasmcraft

A WebAssembly engine written in pure Lua — small enough to drop onto a
[CC:Tweaked](https://tweaked.cc/) computer in Minecraft, correct enough to run
real C programs. Because it boots unmodified wasi-libc binaries, real software
follows: SQLite and the [Picat](http://picat-lang.org/) constraint solver run
in-game as applications *on top of* the engine.

**Docs: <https://r33drichards.github.io/wasmcraft/>**

```
.wasm bytes ──► decoder ──► interp   (portable, runs anywhere)
                      └───► compiler ──► Lua 5.1 bytecode  (Cobalt only, ~7-13x)
```

The headline result: **SQLite 3.53.2, compiled to `wasm32-wasi`, runs a real
`CREATE`/`INSERT`/`SELECT` through this engine on the actual Cobalt VM** —
output identical to `wasmtime`:

```
$ tools/cobalt run.lua wasm/sqlite.wasm
sqlite 3.53.2 in pure-Lua wasm interpreter
inserted, changes=5
-- SELECT name,score WHERE score>7.5 ORDER BY score DESC --
alice | 9.5
erin | 9.0
carol | 8.0
-- aggregate: count, avg --
5 | 7.950
```

## Why this is non-trivial on Cobalt

Cobalt is **Lua 5.1**: every number is an IEEE double, there are no native
integers, and no `&`/`|`/`<<` operators. The engine is built on four
capabilities verified empirically on Cobalt 0.7.3 (see
`test/probe_cobalt.lua`):

| Need | Solution |
|------|----------|
| i32 arithmetic & wrap | doubles hold 32-bit ints exactly; reduce mod 2³² |
| i32 bitwise/shift/rotate | Cobalt's `bit32` library |
| **i64** (no 64-bit-exact integers) | emulated as `{h, l}` two-word values (`src/int64.lua`) |
| f32/f64, LEB128, IEEE decode, float reinterpret | `string.pack`/`string.unpack` |

## The engine

- **Two execution modes.** A portable tree-walking interpreter, and a
  compiler that emits Lua 5.1 bytecode which Cobalt (the Lua VM inside
  CC:Tweaked) runs natively — roughly 7–13× faster. Mode is a flag;
  the JIT falls back to the interpreter on other VMs automatically,
  per-function within a module when one is too large to compile.
- **WASI preview1 host** with a real filesystem: preopened dirs,
  `path_open`/`fd_read`/`fd_write`/`fd_seek`/filestat/unlink, backed by host
  files (or CC's `fs` API in-game). Enough to boot unmodified wasi-libc
  command modules.
- **Differentially tested** against wasmtime, on both Lua 5.4 and the real
  Cobalt VM.

## Built on wasmcraft

These ship in `dist/` as applications on top of the engine — ordinary
clients of its public API:

- **SQLite in Minecraft.** `csrc/wq.c` wraps SQLite in a wasm reactor with a
  generic query API; `dist/wcsql.lua` exposes it as a tiny Lua library with
  on-disk persistence. `dist/sqlsh.lua` is an interactive SQL shell.
- **Picat in Minecraft.** Run constraint/planning programs through the 5.3 MB
  `picat.wasm` engine — one-shot, in a warm REPL session, or served to the
  whole rednet network by a resident daemon (`picatd` + `pic` client).

## Quick start (standalone)

No repo needed — wasmcraft is a single pure-Lua file. On any Lua 5.3/5.4:

```sh
curl -fsSLO https://github.com/r33drichards/wasmcraft/releases/latest/download/wasmcraft.lua
lua wasmcraft.lua hello.wasm
```

See the [install guide](https://r33drichards.github.io/wasmcraft/how-to/install/)
for library usage and SQLite. From a checkout, everything is driven through nix:

```sh
# run a WASI module on Lua 5.4
nix-shell --run "lua run.lua wasm/hello.wasm"

# run it on Cobalt (the CC:Tweaked VM), compiled to bytecode
nix-shell --run "tools/cobalt run.lua --jit wasm/hello.wasm"

# compiled to Lua SOURCE instead (works on CC:T >= 1.109, which bans bytecode)
nix-shell --run "tools/cobalt run.lua --transpile wasm/hello.wasm"

# the SQLite demo
nix-shell --run "tools/cobalt run.lua --jit wasm/sqlite.wasm"

# full test suite (each test runs on lua5.4 AND Cobalt)
nix-shell --run "tools/test"
```

## Quick start (in ComputerCraft)

Copy `dist/sqlsh.lua` onto a computer with HTTP enabled and run it — it
downloads the interpreter bundle and the SQLite reactor on first use:

```
sqlsh mydata.db
sql> CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT);
sql> INSERT INTO t(name) VALUES('alice');
sql> SELECT * FROM t;
```

Or use SQLite from your own program:

```lua
local sql = require("wcsql")
local db  = sql.open("data.db")              -- persists to the computer's disk
db:exec("CREATE TABLE IF NOT EXISTS t(id INTEGER PRIMARY KEY, name TEXT)")
db:exec("INSERT INTO t(name) VALUES('alice')")
for _, row in ipairs(db:query("SELECT id, name FROM t").rows) do
  print(row.id, row.name)
end
db:close()
```

## Project layout

| Path | What it is |
|---|---|
| `src/` | The engine: `decoder`, `interp`, `compiler` + `luabc`, `memory`, `int64`, `wasi`, `sql`, façade `wasm.lua` |
| `dist/` | Deployable artifacts: amalgamated `wasmcraft.lua` bundle, `wcsql`, `sqlsh`, `picat`, `pirun`, `picatd`, `pic`, `planner` |
| `csrc/` | C sources compiled to wasm fixtures (`zig cc -target wasm32-wasi`), incl. SQLite and the `wq` reactor |
| `wasm/` | Prebuilt `.wasm` fixtures |
| `test/` | Test suite (`*_test.lua`) + `.wat` fixture sources |
| `tools/` | `cobalt` (run scripts on the real VM), `test`, `build-fixtures`, `amalgamate` |

## Documentation

Full docs are published at **<https://r33drichards.github.io/wasmcraft/>**.
They live in `docs/` ([Diátaxis](https://diataxis.fr/)-organized) and build
with MkDocs:

```sh
nix-shell -p python3Packages.mkdocs python3Packages.mkdocs-material --run "mkdocs serve"
```

Start with the [getting-started tutorial](docs/tutorials/getting-started.md),
or jump to the [Lua API reference](docs/reference/lua-api.md).

## Development

```sh
nix-shell --run "tools/test"            # run the suite on lua5.4 + Cobalt
nix-shell --run "tools/test sql"        # only tests matching "sql"
tools/build-fixtures                    # regenerate wasm/ from test/wat + csrc
tools/amalgamate                        # regenerate dist/wasmcraft.lua
```

The engine sticks to the Lua 5.1 subset Cobalt supports (plus `bit32`), so
code that passes on Lua 5.4 locally must also pass on `tools/cobalt` before it
counts.
