-- Compiler (wasm -> Lua 5.1 bytecode) correctness. COBALT ONLY: the emitted
-- bytecode is Lua 5.1 format, which only Cobalt loads. Results are checked
-- against the same values the interpreter/wasmtime produce.
package.path = "src/?.lua;test/?.lua;" .. package.path
local T = require("harness")
local decoder = require("decoder")
local compiler = require("compiler")
local runtime = require("runtime")
local to_u32, to_s32 = runtime.to_u32, runtime.to_s32
local loader = loadstring or load
T.start("compiler")

local cache = {}
local function load_mod(name)
  if cache[name] then return cache[name] end
  local f = assert(io.open("wasm/" .. name .. ".wasm", "rb")); local b = f:read("*a"); f:close()
  cache[name] = decoder.load(b); return cache[name]
end

-- compile the exported function `fname` of module `name`, return a callable
local function compile(name, fname)
  local mod = load_mod(name)
  local exp = mod.exports[fname]
  local fidx = exp.index - mod.numImportedFuncs + 1
  T.ok(compiler.can_compile(mod, fidx), name .. "." .. fname .. " can_compile")
  local chunk = compiler.compile_func(mod, fidx)
  local factory = assert(loader(chunk, name .. "." .. fname))
  return factory(runtime.make())
end

local function i(fn, ...) -- call with i32 args, signed result
  local a = { ... }; for k = 1, #a do a[k] = to_u32(a[k]) end
  return to_s32(fn((table.unpack or unpack)(a)))
end

-- add.wasm
local add = compile("add", "add")
T.eq(i(add, 7, 35), 42, "add(7,35)")
T.eq(i(add, -1, 1), 0, "add(-1,1) wraps")
T.eq(i(add, 2147483647, 1), -2147483648, "add overflow wraps")

-- fib (block/loop/br_if/br)
local fib = compile("fib", "fib")
T.eq(i(fib, 10), 55, "fib(10)")
T.eq(i(fib, 20), 6765, "fib(20)")
T.eq(i(fib, 0), 0, "fib(0)")

-- br_table
local sw = compile("brtable", "sw")
T.eq(i(sw, 0), 10, "sw(0)")
T.eq(i(sw, 1), 20, "sw(1)")
T.eq(i(sw, 2), 30, "sw(2)")
T.eq(i(sw, 3), 99, "sw(3) default")
T.eq(i(sw, 7), 99, "sw(7) default")

-- i32 op coverage
local f = compile("i32ops", "f")
T.eq(i(f, 5, 300), 1171, "i32ops f(5,300)")
local divrem = compile("i32ops", "divrem")
T.eq(i(divrem, 17, 5), 5, "divrem(17,5)")
T.eq(i(divrem, -17, 5), -5, "divrem(-17,5)")
local cmp = compile("i32ops", "cmp")
T.eq(i(cmp, 3, 5), 1, "cmp(3,5)")
T.eq(i(cmp, 0, 5), 101, "cmp(0,5)")
local bits = compile("i32ops", "bits")
T.eq(i(bits, 16), 32, "bits(16)")
T.eq(i(bits, 255), 32, "bits(255)")

T.done()
