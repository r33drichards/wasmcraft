# Lua API

The core engine façade is `src/wasm.lua` (`require("wasm")` with `src/` on
`package.path`). The amalgamated bundle (`loadfile("wasmcraft")()`) returns a
superset described at the bottom.

## Module: `wasm`

### `wasm.load(bytes) → module`

Decode a binary wasm module from a string of bytes. Raises on malformed or
unsupported input. The returned module is immutable and reusable across
instantiations.

### `wasm.instantiate(module, imports, opts) → instance`

Instantiate a decoded module.

| Parameter | Type | Meaning |
|---|---|---|
| `module` | decoded module | from `wasm.load` |
| `imports` | table | `imports[mod][field]` — host functions etc. A WASI host from `wasi.make` goes under key `wasi_snapshot_preview1` |
| `opts.mode` | `"interp"` (default) \| `"transpile"` \| `"jit"` \| `"auto"` | `"transpile"` emits Lua *source* (loads on every CC build). `"jit"` is STRICT bytecode - it errors loudly where binary chunks are refused (probe: `wasmcraft.can_jit()`). `"auto"` opts into fastest-available (jit -> transpile -> interp); `inst.mode` reports what ran |
| `opts.chunk_cache` | table | (jit) share compiled bytecode chunks across instantiations of the same module |

### `wasm.instantiate_bytes(bytes, imports, opts) → instance`

Convenience: `load` + `instantiate`.

### `wasm.precompile(bytes, opts) → pre`

Decode (and on Cobalt, prepare to compile) once; instantiate cheaply many
times. `opts.mode` defaults to `"jit"` here.

- `pre.module` — the decoded module
- `pre.jit` — whether the jit path is active
- `pre:instantiate(imports) → instance` — fresh state, no recompile

### `wasm.set_yield(fn, every)`

Interpreter cooperation hook: call `fn()` every `every` interpreted
instructions. Used under CC:Tweaked to satisfy the yield watchdog (the
bundle installs a `queueEvent`/`pullEvent` pair at 200 000 automatically).
For the jit path, see `compiler.yield_in_loops` (auto-on under CC).

### `wasm.is_cobalt() → bool`

True when running on Cobalt (detected as Lua 5.1 + `bit32`) — the only VM
that loads the emitted bytecode.

## Instances

Both execution modes produce the same surface:

### `inst:call(name, ...) → ...`

Call an exported function. Wasm params are Lua arguments, wasm results are
Lua return values.

- `i32` — Lua number (signed view at the host boundary)
- `f32`/`f64` — Lua number (f32 rounded through single precision)
- `i64` — jit mode: Lua number (exact to 2^53); interp mode: an
  `{ h = high32, l = low32 }` table (see `int64` below)

Raises on traps (unreachable, division by zero, out-of-bounds, …) and on
`proc_exit` (see [`wasi.EXIT`](wasi.md#exit-unwinding)).

### `inst.memory`

The instance's linear memory (`nil` if the module has none). 0-based byte
addresses:

| Method | Meaning |
|---|---|
| `mem:size()` | size in 64 KiB pages |
| `mem:bytelen()` | size in bytes |
| `mem:grow(delta) → old \| -1` | grow by `delta` pages |
| `mem:get8(a)` / `mem:set8(a, v)` | single byte |
| `mem:loadstr(a, n) → string` | read `n` bytes |
| `mem:storestr(a, s)` | write the bytes of `s` |
| `mem:fill(d, val, n)` | memset |
| `mem:copy(d, s, n)` | memmove (overlap-safe) |

## Module: `int64`

64-bit integers emulated as `{ h, l }` pairs of unsigned 32-bit halves
(wasm i64 wraps mod 2^64; signedness is a per-operation view). Relevant when
embedding against the interpreter:

- `I.is(v)` — is `v` an int64 table
- `I.from_double_s(n)` / `I.to_double_s(v)` — convert to/from Lua numbers
- `I.mk(h, l)` — construct from halves

## Bundle extras (`dist/wasmcraft.lua`)

`loadfile("wasmcraft")()` returns a table with `load`, `instantiate`,
`set_yield` (as above) plus:

| Field | Meaning |
|---|---|
| `wasmcraft.wasi` | the [`wasi` module](wasi.md) |
| `wasmcraft.sql` | the [`sql` module](sql.md) |
| `wasmcraft.version` | bundle version number; bump on publish so cached in-game copies self-refresh |
| `wasmcraft.run_wasi(bytes, prog_args, writefn, opts) → exitcode` | load + WASI host + `_start` + exit-unwind handling |
| `wasmcraft.run_file(path, args, opts) → exitcode` | `run_wasi` from a file (CC `fs` or `io`) |
| `wasmcraft.hostfs(root) → fs \| nil` | a host filesystem over CC's `fs` API; `nil` standalone (callers fall back to the `io` backend) |
| `wasmcraft.opendb(opts) → db` | open SQLite: `{ modulePath = "wq.wasm" \| module = bytes, path, root, fs }`; a slash-containing `path` is split into root + filename |

When run as a program rather than loaded as a library, the bundle behaves as
a CLI: `wasmcraft [--jit] <module.wasm> [args]`.
