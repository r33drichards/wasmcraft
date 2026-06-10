-- Run a WASI "command" .wasm module.
-- Usage (from project root): tools/cobalt run.lua [--jit] <module.wasm> [args...]
--   (default)  interpreted — portable, yields to CC's event loop
--   --jit      compile to Cobalt bytecode and run natively (Cobalt only, ~7-13x;
--              falls back to interpreted on other VMs)
package.path = "src/?.lua;" .. package.path
local wasm = require("wasm")
local wasi = require("wasi")

local args = { ... }
local mode = "interp"
while true do
  if args[1] == "--interp" then mode = "interp"
  elseif args[1] == "--jit" or args[1] == "--compile" then mode = "jit"
  elseif args[1] == "--transpile" then mode = "transpile"
  elseif args[1] == "--auto" then mode = "auto"
  else break end
  table.remove(args, 1)
end
local path = args[1]
if not path then error("usage: run.lua [--jit] <module.wasm> [args...]") end

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
local inst = wasm.instantiate(module, { wasi_snapshot_preview1 = host }, { mode = mode })

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
