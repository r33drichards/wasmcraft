# wasm → Cobalt bytecode compiler — design & validation

Date: 2026-06-09

## Motivation

The tree-walking interpreter (`src/interp.lua`) is ~1000× slower than native per
wasm instruction (string-dispatch ladder + boxed values + per-byte memory table).
Workloads that execute many instructions — Picat's planner search (uninformed,
hundreds of millions of ops), SQLite — take minutes in-game.

Measured on Cobalt, a 2M-iteration loop (`wasm/loopbench.wasm`):

| Approach | Cobalt time | vs interp |
|---|---|---|
| String-dispatch interpreter | 19.0 s | 1× |
| Closure-threaded dispatch (prototype) | 11.0 s | 1.6× |
| **wasm → Lua 5.1 bytecode → Cobalt** | **1.0 s** | **19×** |

Closure-threading underwhelms on Cobalt because each closure call is a JVM frame
setup. The big win is removing the interpreter loop entirely: compile each wasm
function to **Lua 5.1 bytecode** and `load()` it, so Cobalt runs it on its own
(fast, Java-level) bytecode interpreter.

## Why bytecode, not Lua source

Lua 5.1 (Cobalt) has no `goto` and only single-level `break`, so emitting Lua
*source* would require a control-flow structuring pass to express wasm's
multi-level `br`. Lua *bytecode* has unconditional `JMP`, so wasm
`block`/`loop`/`if`/`br`/`br_table` map directly onto jumps. We emit the binary
chunk in pure Lua and `load` it — staying true to "pure Lua on Cobalt".

## Validated foundation (de-risk)

- Cobalt loads binary chunks: `loadstring(string.dump(f))` round-trips.
- Header captured empirically: `1b 4c 75 61 51 00 01 04 04 04 08 00`
  (sig `\27Lua`, v5.1, little-endian, sizeof int/size_t/instruction = 4, number =
  8-byte double, format 0). Strings = 4-byte size (incl. trailing NUL) + bytes.
- Hand-emitted chunks (no `string.dump`) load + run on Cobalt: `return 42` → 42,
  `add(3,4)` → 7.
- A codegen for the loop subset compiles `loopbench` to bytecode → **19× on Cobalt**,
  result verified against the interpreter and wasmtime.

## Codegen approach

- **Registers**: wasm locals → Lua registers `0..nlocals-1`; the wasm operand
  stack → registers `nlocals..` with a compile-time virtual stack pointer.
- **Cheap ops inline**: `local.get/set` → `MOVE`; `i32.const` → `LOADK`;
  `i32.add/sub` → `ADD/SUB` + `MOD 2^32` (i32 wrap).
- **Complex ops via runtime helpers** (globals/upvalues + `CALL`): signed
  compares, `mul/div/shift` (bit32), all i64 (boxed `{h,l}`), float rounding,
  memory load/store (table ops), conversions.
- **Control flow** → `JMP`: block = forward jumps patched at `end`; loop = backward
  jump to start; `br_if` = `EQ`(cond≠0) + `JMP`; `br_table` = a jump table.
- **Calls**: `call`/`call_indirect` → `CALL` into other compiled closures via a
  shared function table.

## Remaining work (full coverage to run SQLite / Picat)

1. `src/luabc.lua` — proper bytecode emitter (protos, constants, RK, nested
   closures + upvalues for the runtime/memory bindings).
2. `src/compiler.lua` — full op coverage: all i32/i64/f32/f64 ops, conversions,
   memory, globals, select/drop, `call`/`call_indirect`, `br_table`, if/else,
   multi-level `br`, multi-value.
3. Calling convention so compiled functions call each other + host (WASI) imports.
4. Integration: compile module functions to closures; per-function fallback to the
   interpreter for anything not yet supported (always correct, faster as coverage
   grows). Verify against the existing suite + wasmtime; benchmark SQLite/Picat.

The interpreter remains the portable path (lua5.4 and any non-Cobalt VM); the
compiler is the Cobalt fast path.
