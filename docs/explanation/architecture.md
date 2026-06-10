# Architecture

wasmcraft is a WebAssembly engine: it takes the bytes of a `.wasm` module and
executes them on a Lua VM whose only number type is an IEEE double and whose
language (on the primary target, Cobalt) is Lua 5.1. This page walks through
the engine layer by layer, with the actual code.

One framing note up front: **wasmcraft is just the engine.** SQLite
(`sql.lua` + `wq.wasm`) and Picat (`picat.lua` + `picat.wasm`) are
applications *built on* wasmcraft — they are ordinary clients of the public
API described here, with no special hooks into the engine. Everything below
is about the engine itself.

```
                 your Lua code
                       │
            ┌──────────┴──────────┐
            │   wasm.lua façade   │   load() / instantiate() / precompile()
            └──────────┬──────────┘
                       │
   .wasm bytes ──► decoder.lua ──► module tables
                       │
            ┌──────────┴───────────┐
            ▼                      ▼
       interp.lua             compiler.lua ──► luabc.lua ──► Lua 5.1 bytecode
   (portable, anywhere)      (Cobalt loads it natively, ~7-13x)
            │                      │
            └────────┬─────────────┘
                     ▼
     memory.lua · int64.lua · bit.lua      shared substrate
                     │
                 wasi.lua                  optional host (an import module)
```

## The façade

`src/wasm.lua` is 55 lines and is the whole public surface. The only
decision it makes is which execution engine to hand a module to:

```lua
-- src/wasm.lua
local function is_cobalt()
  return _VERSION == "Lua 5.1" and rawget(_G, "bit32") ~= nil
end

function M.instantiate(module, imports, opts)
  local mode = opts and opts.mode or "interp"
  if (mode == "jit" or mode == "compile") and is_cobalt() then
    return require("compiler").instantiate(module, imports, opts)
  end
  return interp.instantiate(module, imports)
end
```

Both engines produce instances with an identical surface (`inst:call`,
`inst.memory`), so `mode = "jit"` is always safe to request — it simply
falls back where the bytecode can't load.

## Decoding

`src/leb.lua` is a byte cursor over the module string. It deliberately uses
**no bitwise operations** — LEB128 is decoded with multiplication — so the
same file parses on Lua 5.1 and 5.4 and needs no `bit` dependency:

```lua
-- src/leb.lua — unsigned LEB128, exact for values up to 2^53
function Reader:u_leb()
  local result, shift = 0, 1
  while true do
    local b = self:byte()
    result = result + (b % 128) * shift
    if b < 128 then return result end
    shift = shift * 128
  end
end
```

`src/decoder.lua` walks the section structure into plain Lua tables —
`mod.types`, `mod.codes`, `mod.exports`, and so on. Function bodies become
flat arrays of instruction tables like `{ op = "i32.add" }` or
`{ op = "local.get", x = 0 }`.

The one clever part: wasm's structured control (`block`/`loop`/`if`/`end`)
is **pre-linked at decode time**. A single pass with a stack records, on
every opener, the index of its matching `end` (and `else`), so neither
execution engine ever scans for block boundaries at run time:

```lua
-- src/decoder.lua — link control structures
local stack = {}
for i = 1, #instrs do
  local o = instrs[i].op
  if o == "block" or o == "loop" or o == "if" then
    stack[#stack + 1] = i
  elseif o == "else" then
    instrs[stack[#stack]].else_pc = i
  elseif o == "end" then
    local j = stack[#stack]; stack[#stack] = nil
    instrs[j].end_pc = i
  end
end
```

## Numbers on a VM that only has doubles

This is the central design problem, and three representations fall out of it.

**i32** values live in *canonical unsigned form* `0 .. 2^32-1` — a range a
double holds exactly. Signedness is not stored; it is a per-operation view:

```lua
-- src/interp.lua
local function to_u32(x)
  x = x % POW32
  if x < 0 then x = x + POW32 end
  return x
end
local function to_s32(x)
  x = to_u32(x)
  if x >= POW31 then x = x - POW32 end
  return x
end
```

Addition is just `(a + b) % 2^32` — the intermediate fits in a double. But
`a * b` of two 32-bit values can need 64 bits, which a double silently
rounds. So multiplication splits into 16-bit lanes, keeping every partial
product under 2^53:

```lua
-- src/interp.lua — i32.mul: low 32 bits via 16-bit lanes
local al = a % 65536; local ah = floor(a / 65536)
local bl = b % 65536; local bh = floor(b / 65536)
local cross = (ah * bl + al * bh) % 65536
push((al * bl + cross * 65536) % POW32)
```

**i64** cannot fit in a double at all, so `src/int64.lua` boxes values as a
pair of unsigned 32-bit halves and implements wrapping arithmetic with
explicit carries:

```lua
-- src/int64.lua — a value is { h = high32, l = low32 }
function I.add(a, b)
  local l = a.l + b.l
  local carry = 0
  if l >= POW32 then l = l - POW32; carry = 1 end
  local h = (a.h + b.h + carry) % POW32
  return mk(h, l)
end
```

Signedness is again a view: `lt_s` and `lt_u` interpret the same box
differently. At the host boundary the box converts to a Lua number (exact
up to 2^53) — inside the engine it never unboxes.

**f32** is a double that gets re-rounded through single precision after
every producing operation, using `string.pack` as the rounding machine:

```lua
local function f32round(x) return (sunpack("<f", spack("<f", x))) end
```

`string.pack`/`string.unpack` also carry all IEEE decoding, reinterpret
casts (`i32.reinterpret_f32` is a pack/unpack round-trip), and typed memory
access. The handful of float edge cases doubles don't give you for free —
NaN propagation in `min`/`max`, negative zero, round-half-to-even — are
hand-written and pinned by the `floatops.wat` fixture.

## The interpreter

`src/interp.lua` executes the decoded instruction array directly. Per call
it builds three structures — locals, an operand stack with an explicit
height, and a control stack:

```lua
-- src/interp.lua — inside run()
local st = { n = 0 }                       -- operand stack
local function push(v) st.n = st.n + 1; st[st.n] = v end
local function pop() local v = st[st.n]; st.n = st.n - 1; return v end

-- bottom control frame represents the function body itself
local ctrl = { { kind = "block", height = 0, arity = #ftype.results, cont = n + 1 } }
```

The main loop is one long `if/elseif` dispatch on `ins.op` over a program
counter. Branching is where the structured-control design pays off: a `br`
to label *k* finds the frame *k* levels up, slides that frame's result
values down to its entry height, discards inner frames, and jumps straight
to the pre-linked target — `start` for a `loop` (back-edge), `cont`
(the decoder's `end_pc`) for a `block`:

```lua
-- src/interp.lua
local function branch(label)
  local fi = #ctrl - label
  local fr = ctrl[fi]
  local keep = fr.arity
  local base = fr.height
  for i = 1, keep do st[base + i] = st[st.n - keep + i] end
  st.n = base + keep
  for i = #ctrl, fi + 1, -1 do ctrl[i] = nil end
  if fr.kind == "loop" then return fr.start else return fr.cont end
end
```

`return` is just a branch to the bottom frame; `br_table` pops an index and
picks a label; `call` recurses into `run` with popped arguments. Traps are
Lua errors prefixed `"wasm trap: "`, raised at explicit checks (bounds,
divide-by-zero, the `0x80000000 / -1` overflow case, uninitialized table
elements).

The loop head also implements cooperative yielding — a host-registered hook
called every N instructions, which is how long runs survive CC:Tweaked's
watchdog (see [Cobalt and ComputerCraft](cobalt-and-computercraft.md)):

```lua
if yield_hook then
  ycount = ycount + 1
  if ycount >= yield_every then ycount = 0; yield_hook() end
end
```

The interpreter is the portable baseline and the semantic reference: it
runs anywhere, and the compiler's helpers are defined to mirror it exactly.

## The compiler

The interpreter pays Lua-table dispatch per wasm instruction, and SQLite is
millions of instructions. The fix exploits a Cobalt-specific fact: **Cobalt
loads standard Lua 5.1 bytecode**, and Lua 5.1 bytecode is a stable,
documented register machine. So `src/compiler.lua` translates each wasm
function into a real Lua function, and Cobalt executes it natively — no
dispatch loop at all. Measured speedup: ~7–13×.

### Register layout

A wasm function becomes a Lua function whose parameters arrive in registers
0..n-1, with a fixed frame after them:

```lua
-- src/compiler.lua — build_fb()
local renv = nparams         -- ENV table, cached from an upvalue
local Ltab = nparams + 1     -- wasm locals live in a Lua table
local kscr = nparams + 2     -- scratch for spilling out-of-range constants
local base = nparams + 3     -- wasm operand stack starts here, in registers
```

Two non-obvious choices:

- **Locals go in a table, not registers.** Real wasm functions (wasi-libc
  builds especially) can declare hundreds of locals; Lua functions cap out
  around 250 registers. The locals table costs a `GETTABLE`/`SETTABLE` per
  access but never overflows. Only the operand stack — which is shallow in
  practice — occupies registers.
- **Everything external comes through one ENV table** held as the
  function's single upvalue: runtime helpers, `memory`, `globals`, `funcs`,
  tables. Compiled functions call each other via `ENV.funcs[i]`, so a
  compiled module is a set of mutually-recursive closures over one shared
  environment.

### Compilation is a stack simulation

The compiler walks the instruction array once, tracking the *virtual* stack
pointer `vsp`. A value "on the wasm stack" at height *k* simply lives in
register `base + k`. Simple ops compile to one or two Lua instructions
inline:

```lua
-- src/compiler.lua — i32.add becomes ADD then MOD 2^32, in place
elseif op == "i32.add" then
  local b = base + vsp - 1; local a = base + vsp - 2
  fb:ARITH(OP.ADD, a, a, b)
  fb:ARITH(OP.MOD, a, a, kop(kwrap))   -- kwrap = constant 4294967296
  vsp = vsp - 1
```

Anything that won't inline cleanly — signed ops, i64 (boxed), float edge
cases, all memory traffic — calls a named helper from
`src/runtime.lua` through ENV. The emitter for that is generic:

```lua
-- src/compiler.lua — pop nargs, call ENV[name], push nres
local function helper(name, nargs, nresx)
  local argbase = base + vsp - nargs
  local f = base + vsp
  fb:GETTABLE(f, renv, kop(fb:kstr(name)))
  for i = 0, nargs - 1 do fb:MOVE(f + 1 + i, argbase + i) end
  fb:CALL(f, nargs + 1, nresx + 1)
  for i = 0, nresx - 1 do fb:MOVE(argbase + i, f + i) end
  vsp = vsp - nargs + nresx
end
```

A 400-entry table maps opcodes to helper names (`i32.div_s → "div_s"`,
`i64.add → "i64_add"`, `f32.sqrt → "f32_sqrt"`, …). The helpers'
semantics deliberately mirror `interp.lua` line for line — the interpreter
is the reference, the runtime is its transcription.

Control flow maps wasm's structured labels onto `JMP` with patched offsets:
each `block`/`if` gets a label object, `br` moves result values down and
jumps, `loop` back-edges jump backwards (optionally emitting an
`ENV.__tick()` call first — the jit's watchdog yield). Dead code after an
unconditional branch is skipped entirely rather than compiled.

### Emitting real bytecode

`src/luabc.lua` is a from-scratch Lua 5.1 bytecode assembler — instruction
packing, constant pools with deduplication, jump fixups, and the chunk
header Cobalt's loader checks:

```lua
-- src/luabc.lua
-- instruction layout: op[0:6] A[6:14] C[14:23] B[23:32]
local function iABC(op, a, b, c) return u32(op + a * 64 + c * 16384 + b * 8388608) end

-- \x1bLua, version 5.1, little-endian, 4-byte int/size_t/instruction, 8-byte doubles
local HEADER = string.char(0x1b, 0x4c, 0x75, 0x61, 0x51, 0, 1, 4, 4, 4, 8, 0)
```

Each compiled function is wrapped in a tiny factory proto —
`function(ENV) return <the function> end` — so a chunk is self-contained:
`loadstring(chunk)(ENV)` yields the wasm function with its environment
bound as the upvalue.

### Trampolines: when SQLite outgrows Lua's jump range

Lua 5.1 has exactly **one** jump instruction, and its offset lives in the
18-bit `sBx` field — a reach of ±131,071 instructions. Wasm branches have
no such limit, and SQLite's amalgamation contains functions (the VDBE
dispatch loop, the parser) whose compiled bodies are longer than that: a
`br` from deep inside to the function's `end` simply cannot be encoded as
one `JMP`. Unlike a real ISA, Lua bytecode has no long-jump form to fall
back on.

The plain build refuses such a function outright:

```lua
-- src/luabc.lua — build()
local sbx = j.label.target - j.pos - 1
if sbx > 131071 or sbx < -131071 then
  error("function too large: jump out of range")
end
```

The compiler catches that error and retries with a relaxed build
(`compile_func` → `compile_oversized`), which reroutes each too-far jump
through **trampolines** — intermediate `JMP`s that each hop part of the
distance:

```
src ──JMP──► trampoline ──JMP──► trampoline ──JMP──► target
   ≤131k        ≤131k               ≤131k
```

Two problems make this more interesting than it sounds.

**Where can a trampoline live?** It's an instruction spliced into the
middle of a function body — if control ever *fell through* into it, it
would teleport execution somewhere wild. The only safe slots are dead
code. So during normal emission the compiler marks **anchors**: positions
immediately after an unconditional control transfer, which fall-through
can never reach:

```lua
-- src/luabc.lua — called after every br / br_table / return / unreachable.
-- Code there is never reached by fall-through, so build_relaxed() may
-- splice trampoline JMPs in.
function FB:anchor() self.anchors[#self.anchors + 1] = #self.code + 1 end
```

Big functions have lots of unconditional branches, so anchors are dense
enough in practice that a hop toward any target can always find one.

**Insertion moves everything.** Splicing a trampoline shifts every
instruction after it, which changes jump distances — possibly pushing
previously-fine jumps out of range, which demands more trampolines, which
shift positions again. So relaxation iterates to a fixed point:

```lua
-- src/luabc.lua — build_relaxed()
for pass = 1, 500 do
  recompute()                                  -- positions incl. current tramps
  added = false
  for _, j in ipairs(self.jumps) do
    local srcpos = newpos(j.pos)
    if not (j.imm and ok_range(srcpos, j.imm)) then
      j.imm = route1(srcpos, { label = j.label })  -- may create a trampoline
    end
  end
  for _, rec in ipairs(allTramps) do           -- trampolines re-route too:
    if not ok_range(trampPos(rec), rec.imm) then -- a hop can itself be too far
      rec.imm = route1(trampPos(rec), rec.finalT) -- and chain through another
    end
  end
  if not added then break end
end
```

Three details keep this converging instead of oscillating:

- **Memoization** — one trampoline per (anchor, label); every jump heading
  for the same target routes through the same hop instead of spawning its
  own.
- **Stickiness** — a jump that already has an in-range immediate target
  keeps it; only jumps actually knocked out of range re-route.
- **Margin** — routing uses a safe reach of 130,000 rather than the hard
  131,071, so the small position shifts from later insertions don't
  invalidate earlier routing decisions.

The output is the same proto with identical semantics — some branches just
take two or three hops, costing one `JMP` dispatch each on those paths.
Only the relaxed path pays any of this; normally-sized functions never run
it.

### Lazy, per-function compilation

Compilation is per-function and happens on first call. The fallback chain
for each function is: plain build → relaxed (trampoline) build → the
interpreter. A function that ends up interpreted registers in the same
`inst.funcs` table as its compiled siblings, so the two kinds call each
other freely and one stubborn function doesn't cost the module its speed.
The optional `chunk_cache` records compiled chunks (and `"interp"`
markers), so repeat instantiations of the same module skip codegen
entirely — that's what `wasm.precompile` builds on, and how a warm Picat
daemon serves a second session without recompiling 5 MB of engine.

### A worked example

The `add` fixture, end to end:

```wasm
(func (export "add") (param i32 i32) (result i32)
  local.get 0
  local.get 1
  i32.add)
```

The decoder produces
`{ {op="local.get", x=0}, {op="local.get", x=1}, {op="i32.add"}, {op="end"} }`.
The interpreter pushes `L[0]`, pushes `L[1]`, then pops twice and pushes
`to_u32(a + b)`. The compiler instead emits (registers: `R2`=ENV, `R3`=locals
table, `R5`=stack base):

```
GETTABLE R5, R3, K"0"     ; push local 0
GETTABLE R6, R3, K"1"     ; push local 1
ADD      R5, R5, R6       ; i32.add ...
MOD      R5, R5, K2^32    ; ...wrapped to u32
RETURN   R5, 2            ; one result
```

Cobalt runs that at full VM speed — there is no wasmcraft code on the hot
path at all.

## The WASI host is just an import module

`src/wasi.lua` is not wired into the engine. It builds an ordinary imports
table — Lua functions keyed by WASI's import names — that you pass to
`instantiate` like any other host functions:

```lua
local host = wasi.make({ args = {"prog"}, write = io.write, root = "." })
local inst = wasm.instantiate(module, { wasi_snapshot_preview1 = host })
```

That separation is what makes the engine general: a module importing your
own `env.whatever` functions needs no WASI at all, and the WASI host itself
never touches engine internals beyond `inst.memory`. Its file model (whole
files cached as in-memory images, flushed on sync/close) is covered in
[WASI and persistence](wasi-and-persistence.md).

## Correctness strategy

- **Hand-written `.wat` fixtures** (`test/wat/`) pin the op space:
  `i32ops`, `i64ops`, `floatops`, `brtable`, `indirect`, `mem`, `glob`,
  `edge`, …
- **C fixtures** prove wasi-libc startup and real workloads
  (`hello`, `compute`, SQLite).
- **wasmtime is the differential oracle** — same module, same input,
  byte-identical output expected.
- **Every test runs on both VMs** (`tools/test`): Lua 5.4 for speed, the
  real Cobalt jar because the two disagree in exactly the ways that matter.
- **The interpreter checks the compiler.** Same module, both modes, same
  results (`test/compiler_test.lua`) — the tree-walker is simple enough to
  trust, which makes it the reference for the bytecode path.

The ultimate integration test is SQLite: if the i64 carries, the memory
model, or the WASI filesystem are wrong anywhere, a `CREATE`/`INSERT`/
`SELECT` round-trip finds out.

## What's deliberately *not* in the engine

No SIMD (`v128` decodes as a type but doesn't execute), no threads/atomics,
no GC types, no exception handling, no multiple memories. Block/loop/if
take no parameters in the jit path (results work; params trigger an
assertion and the interpreter handles those modules). Each gap is an
error, not a silent wrong answer.
