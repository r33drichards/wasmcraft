# wasmcraft — a WebAssembly interpreter in pure Lua, running on Cobalt

A from-scratch [WebAssembly](https://webassembly.github.io/spec/core/bikeshed/)
interpreter written in plain Lua, designed to run on **[Cobalt](https://github.com/cc-tweaked/Cobalt)**
— the Lua 5.1 VM that [CC:Tweaked](https://tweaked.cc) embeds in Minecraft.

It decodes `.wasm` binary modules and executes them. The headline result:
**SQLite 3.53.2, compiled to `wasm32-wasi`, runs a real `CREATE`/`INSERT`/`SELECT`
through this interpreter on the actual Cobalt engine** — output identical to `wasmtime`.

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
integers, and no `&`/`|`/`<<` operators. The interpreter is built around four
capabilities that were verified empirically on Cobalt 0.7.3 (see
`test/probe_cobalt.lua`):

| Need | Solution |
|------|----------|
| i32 arithmetic & wrap | doubles hold 32-bit ints exactly; reduce mod 2³² |
| i32 bitwise/shift/rotate | Cobalt's `bit32` library |
| **i64** (no 53-bit-exact integers) | emulated as `{h, l}` two-word values (`src/int64.lua`) |
| f32/f64, LEB128, IEEE decode, float reinterpret | `string.pack`/`string.unpack` |

## Layout

```
src/
  leb.lua       byte cursor + LEB128 / primitive readers
  int64.lua     64-bit integer emulation (two 32-bit words)
  bit.lua       bit32 on Cobalt; native-operator shim on lua5.4 (bit_native.lua)
  memory.lua    linear memory + typed/bulk access
  decoder.lua   wasm binary → module tables (all standard sections)
  interp.lua    instantiation + structured-control execution engine
  wasi.lua      minimal WASI preview1 host
  wasm.lua      load() / instantiate() façade
run.lua         CLI: run a WASI command module
tools/
  cobalt        run a Lua script on the real Cobalt VM (Java harness)
  test          run the suite on both lua5.4 and Cobalt
  build-fixtures (re)build every .wasm from source (zig cc / wat2wasm)
```

## Running

Everything is driven through `nix` (toolchains: lua5.4, JDK, wabt, wasmtime, zig).

```sh
nix-shell --run "tools/test"                      # full suite, both VMs
nix-shell --run "tools/cobalt run.lua wasm/hello.wasm"
nix-shell --run "tools/cobalt run.lua wasm/sqlite.wasm"
nix-shell --run "tools/build-fixtures"            # rebuild .wasm from csrc/ + test/wat/
```

## Verification

Every fixture is **differentially tested against `wasmtime`** (the oracle) and
run on **both lua5.4** (fast dev) **and Cobalt** (the real target). 105 assertions
across LEB128, i32/i64/float ops & conversions, structured control, memory,
`call`/`call_indirect`, WASI, and SQLite. Compiled C fixtures (`hello.c`,
`compute.c` with malloc+qsort) and SQLite are produced with `zig cc -target wasm32-wasi`.

## Running in-game (CC:Tweaked / real Cobalt)

`tools/amalgamate` bundles the whole interpreter into one file, `dist/wasmcraft.lua`,
with no `require`/`package.path` — drop it on a ComputerCraft computer and go.
Requires **CC:Tweaked 1.100+** (for `string.pack`); `bit32` is built in.

On an in-game Computer's terminal (HTTP is on by default):

```
wget https://paste-production.up.railway.app/wasmcraft-bundle wasmcraft
wget https://paste-production.up.railway.app/wc-hello.wasm hello.wasm
wasmcraft hello.wasm
```
→ `hello from wasm in cobalt; sum(1..100)=5050; len=25`

Other prebuilt modules: `wc-add.wasm` (exports `add`), `wc-compute.wasm`
(malloc + qsort). The bundle reads the `.wasm` via CC's `fs` API.

**SQLite in-game** is heavier: the 4.4 MB module exceeds a default computer's
1 MB disk *and* CC's "too long without yielding" budget. To try it, raise
`computer_space_limit` in the CC:Tweaked config and copy `wasm/sqlite.wasm`
straight into the computer's save folder
(`saves/<world>/computercraft/computer/<id>/`), then `wasmcraft sqlite.wasm`.

## Coverage (honest scope)

Implements the slice of the WASM spec that real LLVM/clang C output uses:
MVP integer/float/parametric/variable/memory/control instructions; multi-value
blocks; `call_indirect` with tables/elements; globals & data segments;
sign-extension ops; saturating (`trunc_sat`) and all numeric conversions; bulk
memory (`memory.copy`/`fill`). WASI preview1 is stubbed to the extent a
`:memory:` SQLite needs (`fd_write`, `clock_time_get`, `environ_*`, …).

**Out of scope** (documented, not silently skipped): SIMD `v128`, GC, exception
handling, `memory64`, threads/atomics, tail calls. SQLite is compiled without
these. Linear memory is byte-addressed for simplicity; a word-packed backend
would cut memory use for larger workloads.
