-- Top-level façade for the pure-Lua WebAssembly engine, with two execution
-- modes:
--   "interp"  (default, portable) — the tree-walking interpreter. Runs anywhere
--             (lua5.4, Cobalt, ...) and yields to CC's event loop.
--   "jit"     (Cobalt only)       — compile each function to Lua 5.1 bytecode and
--             run it natively on Cobalt's VM (~7-13x). Falls back to "interp"
--             automatically on VMs that can't load 5.1 bytecode.
-- Both produce an instance with the same surface: inst:call(name, ...),
-- inst.memory, inst.set_yield.
local decoder = require("decoder")
local interp = require("interp")

local M = {}

-- Cobalt is Lua 5.1 with bit32 — the only VM that loads our emitted bytecode.
local function is_cobalt()
  return _VERSION == "Lua 5.1" and rawget(_G, "bit32") ~= nil
end
M.is_cobalt = is_cobalt

function M.load(bytes)
  return decoder.load(bytes)
end

-- Instantiate a decoded module. opts.mode = "interp" (default) | "jit".
function M.instantiate(module, imports, opts)
  local mode = opts and opts.mode or "interp"
  if (mode == "jit" or mode == "compile") and is_cobalt() then
    return require("compiler").instantiate(module, imports, opts)
  end
  return interp.instantiate(module, imports)
end

-- Convenience: load + instantiate from raw bytes.
function M.instantiate_bytes(bytes, imports, opts)
  return M.instantiate(decoder.load(bytes), imports, opts)
end

-- Compile-once cache. precompile() builds the per-function bytecode chunks once;
-- the returned object instantiates cheaply many times (fresh state, no recompile).
-- Only meaningful in "jit" mode on Cobalt; in "interp" mode it's a thin wrapper.
function M.precompile(bytes, opts)
  local module = decoder.load(bytes)
  if (opts and opts.mode or "jit") ~= "interp" and is_cobalt() then
    local compiler = require("compiler")
    return { module = module, jit = true,
             instantiate = function(_, imports) return compiler.instantiate(module, imports) end }
  end
  return { module = module, jit = false,
           instantiate = function(_, imports) return interp.instantiate(module, imports) end }
end

M.set_yield = interp.set_yield

return M
