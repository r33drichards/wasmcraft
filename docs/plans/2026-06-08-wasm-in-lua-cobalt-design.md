# WASM 3.0 interpreter in Lua, verified on Cobalt — design

Date: 2026-06-08
Spec reference: https://webassembly.github.io/spec/core/bikeshed/ (WebAssembly core, the “3.0” draft tree)

## Goal

A pure-Lua WebAssembly interpreter that loads and executes `.wasm` binary modules,
runnable on **Cobalt** (the Lua VM CC:Tweaked embeds). Stress test: compile SQLite to
wasm and run a query through the interpreter under Cobalt. Interpreter correctness is the
priority; SQLite is a best-effort capstone.

## Target environment — empirically pinned (Cobalt 0.7.3)

- `_VERSION` = **Lua 5.1**; `math.type` is nil → **all numbers are IEEE doubles** (53-bit mantissa).
- `2^53` is not exact → **i64 cannot be a Lua number**; emulate as two unsigned 32-bit halves.
- `bit32` present with full u32 semantics (`band/bor/bxor/bnot/lshift/rshift/arshift/lrotate/rrotate`).
  Not auto-installed by `CoreLibraries`; our harness adds it (CC:Tweaked also provides it).
- `string.pack/unpack/packsize` present: `<I4 <i4 <I8 <f <d <B` etc. → LEB128 byte reads,
  IEEE-754 f32/f64 decode, and float reinterpret all available.
- Binary strings are fully 8-bit clean (embedded NUL, byte 0xFF).

These four facts make the project feasible: i32 = double + bit32; i64 = {hi,lo} + bit32;
f64 = double; f32 = double rounded via `string.pack("<f")`; module bytes & memory = Lua strings.

## Number representation

- **i32**: a Lua number held canonically as **unsigned** `0 .. 2^32-1` (exact in a double).
  Bitwise/shift/rotate via `bit32`. add/sub/mul reduced mod 2^32; mul done in 16-bit lanes to
  stay under 2^53. Signed views computed on demand.
- **i64**: `{ h = u32, l = u32 }` (high, low). Full op set implemented on 16-bit lanes with bit32.
- **f64**: native Lua number.
- **f32**: native Lua number, re-rounded to single precision after each producing op via
  `string.unpack("<f", string.pack("<f", x))`.

## Linear memory

Mutable bytes in a Lua VM with immutable strings: store memory as an array of **32-bit
little-endian words** (`mem.words[i] = u32`), one Lua number per 4 bytes (~4x fewer slots than
one-number-per-byte). Byte get/set extract/insert within a word; typed loads/stores compose
bytes and use `string.pack/unpack` to reinterpret floats. Grows by 64KiB pages.

## Components

1. `src/leb.lua` — LEB128 (unsigned/signed) + primitive readers over a byte cursor.
2. `src/int64.lua` — i64 value type and its complete operation set.
3. `src/decoder.lua` — binary module decoder: magic/version, all sections, types, expressions.
4. `src/memory.lua` — word-backed linear memory; typed load/store; grow.
5. `src/interp.lua` — instantiation (imports/exports/globals/elems/data/start) + the structured
   control execution engine (block/loop/if/br/br_table/call/call_indirect/return, value stack).
6. `src/wasi.lua` — minimal WASI preview1 host (fd_write/read/seek/close, args/environ, clock,
   random, proc_exit) backed by Cobalt `io`/`os`, enough to boot a wasi-libc program.
7. `src/wasm.lua` — top-level façade: `load(bytes) -> module`, `instantiate(module, imports)`,
   `instance:call(export, ...)`.

## Instruction coverage (honest scope)

Target the subset real LLVM/clang C output uses, which is what SQLite needs:
- MVP integer/float/parametric/variable/memory/control ops (full).
- Sign-extension ops, non-trapping (saturating) float→int conversions.
- Multi-value blocks/returns.
- Bulk memory: `memory.copy/fill/init`, `data.drop` (+ table.copy/fill/init, elem.drop).
- Reference types: `ref.null/ref.func/ref.is_null`, `table.get/set/grow/size`.

Explicitly **out of scope** for now (documented, not silently skipped): SIMD `v128`, GC,
exception handling, `memory64`, threads/atomics, tail calls. SQLite is compiled `-mno-simd` etc.
so it does not require these.

## Verification strategy

- **Differential testing**: every fixture is run in `wasmtime` (oracle) and in our interpreter
  under **Cobalt**; results must match. `.wat` fixtures assembled with `wat2wasm`.
- Milestones, each ending in a Cobalt run:
  - A: decode + execute `add.wasm` → correct sum in Cobalt.
  - B: memory load/store, loops, `call`, `br_table` (iterative fib, memory sum).
  - C: i64 op suite + float ops + conversions vs wasmtime.
  - D: WASI stubs; run a wasi-sdk-compiled C program in Cobalt.
  - E (capstone): compile SQLite → wasm; run `CREATE/INSERT/SELECT` through the interpreter
    under Cobalt. Best-effort; document partials.

## Non-goals / YAGNI

No JIT, no full static validation (decode faithfully + trap at runtime), no SIMD/GC/EH unless a
target module demands it. Performance tuning only as needed to make milestones complete.
