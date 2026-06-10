# Cobalt and ComputerCraft

The engine's primary target is a computer inside Minecraft. That target
shapes the codebase more than WebAssembly does.

## The VM: Cobalt

CC:Tweaked embeds [Cobalt](https://github.com/SquidDev/Cobalt), a Java
reimplementation of **Lua 5.1** with `bit32` added. Three consequences:

**The whole codebase is written in the 5.1 subset.** No integer division
operator, no bitwise operators, no `goto`, no integers at all — even when
running on Lua 5.4 locally, the code restricts itself to what Cobalt parses.
The one exception, `bit_native.lua` (a faster bit library using 5.3
operators), is embedded in the bundle as a *string* and `load()`-ed only on
VMs that can parse it; Cobalt uses its native `bit32` instead via the
`bit.lua` shim.

**Lua 5.1 bytecode is a usable compilation target.** This is the unlock for
the jit: Cobalt's loader accepts standard 5.1 chunks, so wasm functions can
become native Lua functions. It's also why the jit doesn't travel — 5.4 and
LuaJIT changed their bytecode formats.

**Local green isn't green.** `tools/cobalt` runs any script on the real
standalone jar (via a small Java harness, `CobaltRunner.java`), and
`tools/test` runs every test on both VMs. `test/probe_cobalt.lua` documents
the observed differences. A change only counts when both columns pass.

## The jit lifecycle: generate, load, execute

The whole bytecode trick is three ordinary-looking steps. (How the compiler
*translates* wasm — registers, helpers, trampolines — is covered in
[Architecture](architecture.md); this is the Cobalt-facing mechanics.)

### 1. Generate — a chunk is just a string

`src/luabc.lua` assembles Lua 5.1 instructions by integer arithmetic — each
is one 32-bit word with the opcode and operands packed into bit fields —
and prefixes the 12-byte header Cobalt's `BytecodeLoader` checks
(`\27Lua`, version 5.1, little-endian, 4-byte ints, 8-byte doubles):

```lua
-- src/luabc.lua
-- instruction layout: op[0:6] A[6:14] C[14:23] B[23:32]
local function iABC(op, a, b, c) return u32(op + a * 64 + c * 16384 + b * 8388608) end

local HEADER = string.char(0x1b, 0x4c, 0x75, 0x61, 0x51, 0, 1, 4, 4, 4, 8, 0)
```

Each wasm function compiles to one chunk: a tiny *factory* proto whose only
child is the translated function. The factory exists to bind the runtime
environment — calling it with ENV returns the wasm function as a closure
capturing ENV as its single upvalue:

```lua
-- src/luabc.lua — wrap a compiled wasm function in function(ENV) return fn end
function M.loadable(wasmfn)
  local child = wasmfn:build()
  local fac = M.func(1, 0)          -- param 0 = ENV
  local idx = fac:add_child(child)
  fac:CLOSURE(1, idx)               -- R1 = closure(child)
  fac:_emit(iABC(OP.MOVE, 0, 0, 0)) -- upvalue binding: upval0 := ENV
  fac:RETURN(1, 2)
  return HEADER .. fac:build()
end
```

### 2. Load — `loadstring` does the work

Lua's standard `loadstring` accepts binary chunks, and Cobalt implements
the standard 5.1 format. So loading compiled wasm is one line per function,
straight from `compiler.instantiate`:

```lua
-- src/compiler.lua
local loader = loadstring or load
local ENV = runtime.make(inst)          -- helpers + memory/globals/funcs/tables
...
inst.funcs[gi] = loader(chunk, "wasmfn#" .. gi)(ENV)
```

This is also exactly why the jit is Cobalt-only: PUC Lua 5.4 and LuaJIT
changed their bytecode formats and reject the 5.1 header, so
`wasm.instantiate` gates on `is_cobalt()` and falls back to the
interpreter everywhere else.

### 3. Execute — it's just a Lua function

There is no dispatch loop, no wasmcraft code on the hot path. The compiled
function runs on Cobalt's own VM; the only seams back into the engine are
ENV lookups — including wasm `call`, which compiles to an ordinary Lua call
through `ENV.funcs`:

```lua
-- src/compiler.lua — wasm `call` becomes GETTABLE + CALL
fb:GETTABLE(fr, renv, kop(fb:kstr("funcs")))
fb:GETTABLE(fr, fr, kop(fb:knum(ins.func)))
for i = 0, na - 1 do fb:MOVE(fr + 1 + i, argbase + i) end
fb:CALL(fr, na + 1, nr + 1)
```

### All three steps, by hand

You can drive the pipeline yourself on the standalone Cobalt jar
(`nix-shell --run "tools/cobalt demo.lua"` from the repo root):

```lua
package.path = "src/?.lua;" .. package.path
local decoder  = require("decoder")
local compiler = require("compiler")
local runtime  = require("runtime")
local Memory   = require("memory")

local f = assert(io.open("wasm/add.wasm", "rb"))
local mod = decoder.load(f:read("*a")); f:close()

-- 1. generate: wasm function -> a Lua 5.1 binary chunk (a string)
local chunk = compiler.compile_func(mod, 1)
print(#chunk, chunk:byte(1, 4))   --> 175   27 76 117 97   ("\27Lua")

-- 2. load: Cobalt accepts the chunk; calling the factory binds ENV
local inst = { funcs = {}, globals = {}, tables = {}, memory = Memory.new(0) }
local add = loadstring(chunk, "wasmfn#0")(runtime.make(inst))

-- 3. execute: it is just a Lua function now
print(add(2, 3))                  --> 5
```

Run the same script under plain `lua` and step 2 fails — Lua 5.4 won't
load a 5.1 chunk — which is the entire portability story of the jit in one
error message.

## The watchdog: yielding or dying

CC:Tweaked time-slices all computers cooperatively and **kills** any program
that runs too long without yielding ("too long without yielding"). A wasm
engine is exactly such a program, so cooperation is built in at both levels:

- **Interpreter:** `wasm.set_yield(fn, every)` invokes a hook every N
  instructions. The bundle auto-installs
  `os.queueEvent("wasmcraft_yield"); os.pullEvent("wasmcraft_yield")` at
  200 000 instructions when it detects CC — queueing and pulling a private
  event resets the watchdog and resumes in the same tick.
- **Jit:** compiled code can't count instructions cheaply, so the compiler
  injects a tick at **loop back-edges** (`compiler.yield_in_loops`). It is
  auto-enabled only under CC (detected by `os.queueEvent` existing);
  standalone Cobalt leaves it off for full speed.

This leaks into library design too: the Picat session pump must distinguish
its own "waiting for stdin" yields from watchdog yields and forward the
latter to CC's scheduler.

## Distribution: one file over HTTP

CC computers have no `package.path` and no package manager; what they do
have is an `http` API and a global `fs`. So:

- `tools/amalgamate` flattens all of `src/` into `dist/wasmcraft.lua` with a
  miniature `require` shim — one file to install.
- The deployable programs (`sqlsh`, `wcsql`, `picatd`, …) each begin with a
  tiny bootstrap that downloads what's missing from a paste store and finds
  files across the CC/standalone layouts.
- Caches need invalidation: `wasmcraft.version` is bumped on publish, and
  long-lived programs like `picatd` check it and re-download stale copies
  ("self-healing").

The exception is `picat.wasm` (5.3 MB): too big to fetch casually, so it
ships on a floppy disk that mounts at `/disk/` — and the `picatd`/`pic`
split exists precisely so only **one** computer on a network needs that
floppy.

## Why this is worth it

Because the payoff is absurd in the best way: real SQLite transactions and
a real constraint solver running on an in-game computer, written in nothing
but Lua, surviving chunk unloads, served over in-game wireless. The
constraints (5.1, doubles, watchdog, whole-file I/O) are what make the
engineering interesting.
