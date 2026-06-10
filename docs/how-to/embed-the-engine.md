# Embed the engine

Goal: load and drive wasm modules from your own Lua code — supplying imports,
calling exports, and reading/writing linear memory.

## Get the API table

**From the repo** (Lua 5.4 or Cobalt):

```lua
package.path = "src/?.lua;" .. package.path
local wasm = require("wasm")
local wasi = require("wasi")
```

**From the bundle** (one file, works on CC where there is no `package.path`):

```lua
local wasmcraft = loadfile("wasmcraft")()
-- wasmcraft.load / .instantiate / .wasi / .sql / ... (see the Lua API reference)
```

## Load, instantiate, call

```lua
local f = assert(io.open("wasm/add.wasm", "rb"))
local bytes = f:read("*a"); f:close()

local module = wasm.load(bytes)                       -- decode once
local inst = wasm.instantiate(module, {}, { mode = "interp" })
print(inst:call("add", 2, 3))                         --> 5
```

Modes are explicit contracts: `"interp"` (default) runs anywhere;
`"transpile"` compiles to Lua *source*, which loads on every CC build;
`"jit"` compiles to Lua 5.1 bytecode and **errors loudly** on VMs that
refuse binary chunks (CC:Tweaked >= 1.109) — probe with `wasmcraft.can_jit()`.
Opt-in `"auto"` picks the fastest available (jit -> transpile -> interp) and
reports the choice via `inst.mode`.

## Supply imports

Imports are a two-level table: `imports[module_name][field_name]`. A WASI
host is just a prebuilt import module:

```lua
local host = wasi.make({
  args  = { "prog", "first-arg" },
  write = io.write,            -- where stdout goes
  root  = "/tmp/sandbox",      -- preopened directory for file I/O
})
local inst = wasm.instantiate(module, { wasi_snapshot_preview1 = host })
inst:call("_start")
```

Custom host functions work the same way — plain Lua functions keyed by
import name:

```lua
local inst = wasm.instantiate(module, {
  env = { log_i32 = function(x) print("module says", x) end },
})
```

## Catch proc_exit

wasi-libc programs end by calling `proc_exit`, which unwinds as a Lua error
carrying a marker table. Wrap `_start`:

```lua
local ok, err = pcall(function() inst:call("_start") end)
if not ok then
  if type(err) == "table" and err[wasi.EXIT] then
    print("exit code", err.code)
  else
    error(err)
  end
end
```

(Or skip all of the above for command modules: the bundle's
`wasmcraft.run_wasi(bytes, args, writefn, opts)` does load + WASI + pcall and
returns the exit code.)

## Read and write linear memory

`inst.memory` is the module's linear memory; addresses are 0-based byte
offsets:

```lua
local mem = inst.memory
mem:storestr(ptr, "hello\0")        -- write bytes
local s  = mem:loadstr(ptr, 5)      -- read 5 bytes as a string
local b  = mem:get8(ptr)            -- single byte
mem:set8(ptr, 0x41)
```

The usual marshalling pattern for C-string APIs — allocate inside the module,
write, call, free (here against the `wq` SQLite reactor):

```lua
local p = inst:call("wq_malloc", #sql + 1)
inst.memory:storestr(p, sql)
inst.memory:set8(p + #sql, 0)
inst:call("wq_exec", p)
inst:call("wq_free", p)
```

## i64 values at the boundary

Lua numbers are doubles, so 64-bit integers are emulated. At the host
boundary:

- In **jit** mode, i64 results are converted to Lua numbers (exact up to
  2^53).
- In **interp** mode, i64 values cross as `{ h = high32, l = low32 }`
  tables. The WASI host accepts both forms.

## Instantiate the same module many times

`wasm.precompile(bytes, opts)` pays decode (and, on Cobalt, compile) once and
returns a factory:

```lua
local pre = wasm.precompile(bytes)
local a = pre:instantiate(imports)   -- cheap: fresh state, no recompile
local b = pre:instantiate(imports)
```

## Yielding on ComputerCraft

Long-running wasm must yield or CC kills the program. The bundle configures
this automatically when it detects CC. If you assemble the engine yourself:

```lua
wasm.set_yield(function()
  os.queueEvent("yield"); os.pullEvent("yield")
end, 200000)   -- interpreter: call the function every N instructions
```

In jit mode the compiler instead injects a tick at loop back-edges
(auto-enabled under CC, off on standalone Cobalt for full speed).
