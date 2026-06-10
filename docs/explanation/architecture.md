# Architecture

wasmcraft executes WebAssembly on Lua VMs whose only number type is an IEEE
double and whose language (on the primary target) is Lua 5.1. Everything
about the design follows from those two constraints plus one goal: run real,
unmodified wasi-libc binaries inside ComputerCraft.

## The pipeline

```
.wasm bytes
   │
   ▼
 leb.lua ──── byte cursor + LEB128 readers (pure arithmetic, no bit32)
   │
   ▼
 decoder.lua ── sections → a plain-Lua module structure
   │
   ├──► interp.lua ──── tree-walking interpreter        (mode = "interp")
   │
   └──► compiler.lua ── per-function Lua 5.1 bytecode   (mode = "jit")
            │ luabc.lua  (bytecode emitter)
            │ runtime.lua (helpers the compiled code calls via an ENV upvalue)
            ▼
        Cobalt loads the chunks natively
```

Both paths share `memory.lua` (linear memory), `int64.lua` (i64 emulation),
and the `bit` shim, and both produce instances with an identical surface
(`inst:call`, `inst.memory`) — callers choose a mode, not an API.

## Why two execution modes

The **interpreter** is the portable baseline: it runs on anything from
Lua 5.4 to Cobalt, makes yielding trivial (it's a Lua loop — count
instructions, call a hook), and is straightforward to keep correct.

The **compiler** exists because the interpreter pays Lua-table-dispatch per
wasm instruction, and SQLite/Picat are millions of instructions. Cobalt is
Lua 5.1, and Lua 5.1 bytecode is a stable, documented format — so
`compiler.lua` translates each wasm function into a real Lua function
(params in registers, structured control mapped to jumps) and `luabc.lua`
serializes it as a chunk Cobalt's loader accepts. The measured win is
~7–13×. Heavy ops (i64 arithmetic, rotates, clz) don't get open-coded —
they call helpers in `runtime.lua` through an ENV table held as an upvalue,
which keeps the emitter simple and the bytecode small.

The jit is **Cobalt-only** by construction: PUC Lua 5.4 and LuaJIT won't
load 5.1 bytecode. `wasm.instantiate` detects Cobalt (Lua 5.1 + `bit32`)
and falls back to the interpreter elsewhere, so `mode = "jit"` is always
safe to request.

## Numbers on a VM with only doubles

- **i32** values are kept in canonical unsigned form `0..2^32-1` — exact in
  a double — and converted to a signed view per-operation where signedness
  matters.
- **i64** can't fit in a double, so `int64.lua` represents values as
  `{ h, l }` pairs of unsigned 32-bit halves and implements wrapping
  arithmetic, shifts, comparisons, and conversions on top of the `bit`
  shim. In jit mode these stay internal; results convert to Lua numbers at
  the host boundary.
- **f32** is a double rounded through single precision
  (`string.pack("<f", …)` round-trip) at every producing operation, which
  preserves f32 semantics including NaN/−0 edge cases the test fixtures
  exercise.

## Correctness strategy

Hand-written `.wat` fixtures cover the op space (`i32ops`, `i64ops`,
`floatops`, `brtable`, `indirect`, `mem`, `glob`, `edge`, …); C fixtures
prove wasi-libc startup and real workloads; wasmtime serves as the
differential oracle; and every test runs on **both** Lua 5.4 and the real
Cobalt jar, because the two VMs disagree in exactly the ways that matter
(see [Cobalt and ComputerCraft](cobalt-and-computercraft.md)).

The ultimate integration test is SQLite: if the WASI filesystem, i64 math,
and memory model are wrong anywhere, SQLite finds out.
