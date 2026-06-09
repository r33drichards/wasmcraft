-- RED: structured control, i32 op set, memory, call, call_indirect, br_table.
-- Oracles captured from wasmtime.
package.path = "src/?.lua;test/?.lua;" .. package.path
local T = require("harness")
local wasm = require("wasm")
T.start("controlmem")

local function inst(name)
  local f = assert(io.open("wasm/" .. name .. ".wasm", "rb"))
  local b = f:read("*a"); f:close()
  return wasm.instantiate(wasm.load(b), {})
end

-- fib: block/loop/br_if/br, locals, i32.add, i32.ge_s
local fib = inst("fib")
T.eq(fib:call("fib", 10), 55, "fib(10)")
T.eq(fib:call("fib", 20), 6765, "fib(20)")
T.eq(fib:call("fib", 0), 0, "fib(0)")
T.eq(fib:call("fib", 1), 1, "fib(1)")

-- memory: store/load i32, store8/store16, load8_u/load16_u, mul
local mem = inst("mem")
T.eq(mem:call("sum", 5), 30, "sum(5)")
T.eq(mem:call("sum", 10), 285, "sum(10)")
T.eq(mem:call("bytes"), 48944, "bytes()")

-- call
T.eq(inst("call"):call("sumsq", 3, 4), 25, "sumsq(3,4)")

-- br_table
local sw = inst("brtable")
T.eq(sw:call("sw", 0), 10, "sw(0)")
T.eq(sw:call("sw", 1), 20, "sw(1)")
T.eq(sw:call("sw", 2), 30, "sw(2)")
T.eq(sw:call("sw", 3), 99, "sw(3) default")
T.eq(sw:call("sw", 7), 99, "sw(7) default")

-- call_indirect via table + elem
local ind = inst("indirect")
T.eq(ind:call("op", 0, 8, 5), 13, "op add")
T.eq(ind:call("op", 1, 8, 5), 3, "op sub")

-- i32 op coverage
local ops = inst("i32ops")
T.eq(ops:call("f", 5, 300), 1171, "f(5,300)")
T.eq(ops:call("divrem", 17, 5), 5, "divrem(17,5)")
T.eq(ops:call("divrem", -17, 5), -5, "divrem(-17,5)")
T.eq(ops:call("cmp", 3, 5), 1, "cmp(3,5)")
T.eq(ops:call("cmp", 0, 5), 101, "cmp(0,5)")
T.eq(ops:call("bits", 16), 32, "bits(16)")
T.eq(ops:call("bits", 255), 32, "bits(255)")

T.done()
