-- Top-level façade for the pure-Lua WebAssembly interpreter.
local decoder = require("decoder")
local interp = require("interp")

local M = {}

function M.load(bytes)
  return decoder.load(bytes)
end

function M.instantiate(module, imports)
  return interp.instantiate(module, imports)
end

-- Register a yield hook called every `every` instructions (for CC's watchdog).
M.set_yield = interp.set_yield

return M
