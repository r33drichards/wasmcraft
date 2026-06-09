-- Run a WASI "command" .wasm module through the pure-Lua interpreter.
-- Usage (from project root): tools/cobalt run.lua <module.wasm> [args...]
-- Works on Cobalt (the CC:Tweaked engine) and on lua5.4.
package.path = "src/?.lua;" .. package.path
local wasm = require("wasm")
local wasi = require("wasi")

local args = { ... }
local path = args[1]
if not path then error("usage: run.lua <module.wasm> [args...]") end

local f = assert(io.open(path, "rb"))
local bytes = f:read("*a")
f:close()

local module = wasm.load(bytes)

local prog_args = { path }
for i = 2, #args do prog_args[#prog_args + 1] = args[i] end

local host = wasi.make({
  write = io.write,
  writeerr = io.write,
  args = prog_args,
})
local inst = wasm.instantiate(module, { wasi_snapshot_preview1 = host })

local ok, err = pcall(function() inst:call("_start") end)

-- flush stdout if the host VM exposes it
pcall(function() io.stdout:flush() end)

if not ok then
  if type(err) == "table" and err[wasi.EXIT] then
    if err.code ~= 0 then io.write("\n[module exited with code " .. tostring(err.code) .. "]\n") end
  else
    error(err)
  end
end
