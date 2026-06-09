-- Capstone: SQLite (amalgamation) compiled to wasm32-wasi, run end-to-end
-- through the pure-Lua interpreter. Output compared to the wasmtime oracle.
package.path = "src/?.lua;test/?.lua;" .. package.path
local T = require("harness")
local wasm = require("wasm")
local wasi = require("wasi")
T.start("sqlite")

local f = assert(io.open("wasm/sqlite.wasm", "rb"))
local b = f:read("*a"); f:close()

local out = {}
local host = wasi.make({ write = function(s) out[#out + 1] = s end, args = { "sqlite" } })
local inst = wasm.instantiate(wasm.load(b), { wasi_snapshot_preview1 = host })
local ok, err = pcall(function() inst:call("_start") end)
if not (ok or (type(err) == "table" and err[wasi.EXIT])) then error(err) end

local expected =
  "sqlite 3.53.2 in pure-Lua wasm interpreter\n" ..
  "inserted, changes=5\n" ..
  "-- SELECT name,score WHERE score>7.5 ORDER BY score DESC --\n" ..
  "alice | 9.5\n" ..
  "erin | 9.0\n" ..
  "carol | 8.0\n" ..
  "-- aggregate: count, avg --\n" ..
  "5 | 7.950\n"

T.eq(table.concat(out), expected, "SQLite CREATE/INSERT/SELECT/aggregate output")
T.done()
