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

return M
