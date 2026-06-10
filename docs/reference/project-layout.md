# Project layout

```
wasmcraft/
├── shell.nix          dev environment: lua5.4, JDK 21, wabt, wasmtime
├── run.lua            CLI runner for WASI command modules (repo-side)
├── src/               the engine (each file is a require-able module)
├── dist/              deployable artifacts (CC:Tweaked-ready)
├── csrc/              C sources compiled to wasm fixtures
├── wasm/              prebuilt .wasm fixtures
├── test/              test suite + .wat fixture sources
├── tools/             dev scripts (cobalt, test, build-fixtures, amalgamate)
└── vendor/            Cobalt jar, SQLite amalgamation
```

## `src/` — the engine

| Module | Lines | Role |
|---|---|---|
| `leb.lua` | ~80 | byte cursor + LEB128/primitive readers; pure arithmetic, no `bit32`, runs on 5.1 and 5.4 |
| `decoder.lua` | ~430 | binary module decoder (types, imports, functions, code, data, …) |
| `interp.lua` | ~560 | structured-control tree-walking interpreter; instantiation |
| `compiler.lua` | ~480 | wasm → Lua 5.1 bytecode compiler (Cobalt fast path) |
| `luabc.lua` | ~300 | Lua 5.1 bytecode emitter (opcodes, constants, chunk format) |
| `runtime.lua` | ~230 | helper library the compiled code calls through its ENV upvalue |
| `memory.lua` | ~60 | linear memory: byte table + loadstr/storestr/fill/copy/grow |
| `int64.lua` | ~240 | i64 emulation as `{h, l}` unsigned-32 pairs |
| `bit.lua` / `bit_native.lua` | tiny | bit32 shim: native `bit32` on Cobalt/CC, 5.3 operators on lua5.4 |
| `wasi.lua` | ~370 | WASI preview1 host: stdio/args/clock + real filesystem |
| `sql.lua` | ~110 | drives the `wq.wasm` SQLite reactor |
| `wasm.lua` | ~55 | public façade: `load`, `instantiate`, `precompile`, `set_yield` |

## `dist/` — deployables

| File | Kind | What |
|---|---|---|
| `wasmcraft.lua` | bundle (generated) | all of `src/` in one file; program + library |
| `wcsql.lua` | library | SQLite with persistence, self-bootstrapping |
| `sqlsh.lua` | program | interactive SQL shell |
| `picat.lua` | library | run Picat: `run`, `runfile`, `session` |
| `pirun.lua` | program | run a `.pi` file |
| `picatd.lua` | program | multi-session Picat daemon over rednet |
| `pic.lua` | program | client for `picatd` (pocket-computer friendly) |
| `planner.lua` | program | side-by-side planning demo on a monitor |

`wasmcraft.lua` is **generated** by `tools/amalgamate` — edit `src/`, not it.

## `csrc/` and `wasm/`

| Source | Fixture | What |
|---|---|---|
| `hello.c` | `hello.wasm` | smoke test |
| `compute.c` | `compute.wasm` | arithmetic workload |
| `sqlite_demo.c` + `sqlite3.c` | `sqlite.wasm`, `sqlite-min.wasm` | SQLite demo command module (O2 / Oz) |
| `wq.c` + `sqlite3.c` | `wq.wasm` | SQLite reactor with the generic query API |
| `test/wat/*.wat` | `wasm/*.wasm` | hand-written op-coverage fixtures (i32/i64/float ops, control, calls, memory, globals, br_table, …) |

## `test/`

`*_test.lua` files print `ALL_PASS` on success and run on both VMs via
`tools/test`. `harness.lua` holds the assertion helpers;
`probe_cobalt.lua` documents what the Cobalt VM does/doesn't support.
