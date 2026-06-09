-- RED: decode add.wasm, instantiate, call exported "add". i32 wrap semantics.
package.path = "src/?.lua;test/?.lua;" .. package.path
local T = require("harness")
local wasm = require("wasm")
T.start("add")

local f = assert(io.open("wasm/add.wasm", "rb"))
local bytes = f:read("*a"); f:close()

local mod = wasm.load(bytes)
local inst = wasm.instantiate(mod, {})

T.eq(inst:call("add", 7, 35), 42, "add(7,35)")
T.eq(inst:call("add", -1, 1), 0, "add(-1,1) wraps to 0")
T.eq(inst:call("add", 2147483647, 1), -2147483648, "add signed overflow wraps")
T.eq(inst:call("add", 100, -50), 50, "add(100,-50)")

T.done()
