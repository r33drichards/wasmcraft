-- WASI command modules: real C compiled with zig cc -target wasm32-wasi,
-- run end-to-end through the interpreter. Output captured and compared to the
-- wasmtime oracle.
package.path = "src/?.lua;test/?.lua;" .. package.path
local T = require("harness")
local wasm = require("wasm")
local wasi = require("wasi")
T.start("wasi")

local function run_capture(name)
  local f = assert(io.open("wasm/" .. name .. ".wasm", "rb"))
  local b = f:read("*a"); f:close()
  local out = {}
  local host = wasi.make({ write = function(s) out[#out + 1] = s end, args = { name } })
  local inst = wasm.instantiate(wasm.load(b), { wasi_snapshot_preview1 = host })
  local ok, err = pcall(function() inst:call("_start") end)
  local exited = ok or (type(err) == "table" and err[wasi.EXIT])
  if not exited then error(err) end
  return table.concat(out)
end

T.eq(run_capture("hello"),
  "hello from wasm in cobalt; sum(1..100)=5050; len=25\n",
  "hello.c: printf + loop + libc")

T.eq(run_capture("compute"),
  "min=1 max=992 sum=25554 median=514\n",
  "compute.c: malloc + qsort (user call_indirect) + memory.grow")

T.done()
