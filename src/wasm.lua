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

-- Some CC:Tweaked builds (>= 1.109.0) refuse to load binary chunks entirely.
-- Probe once with a minimal valid 5.1 chunk ("return 42") so jit mode can fall
-- back to the interpreter instead of crashing mid-instantiate.
local BCPROBE = "\27\76\117\97\81\0\1\4\4\4\8\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\2\2\2\0\0\0\1\0\0\0\30\0\0\1\1\0\0\0\3\0\0\0\0\0\0\69\64\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0"
local can_jit_cached
function M.can_jit()
  if can_jit_cached == nil then
    if not is_cobalt() then can_jit_cached = false
    else
      local ok, f = pcall(loadstring or load, BCPROBE)
      can_jit_cached = ok and type(f) == "function" and select(2, pcall(f)) == 42
    end
  end
  return can_jit_cached
end

function M.load(bytes)
  return decoder.load(bytes)
end

-- Instantiate a decoded module. opts.mode:
--   "interp"    (default) tree-walking interpreter, runs anywhere
--   "transpile" wasm -> Lua SOURCE (text chunks load on every CC build)
--   "jit"       Lua 5.1 bytecode. STRICT: errors loudly if this VM refuses
--               binary chunks (CC:Tweaked >= 1.109) - no silent substitution
--   "auto"      fastest available: jit if loadable, else transpile, else interp
-- The returned instance carries inst.mode = what actually ran.
function M.instantiate(module, imports, opts)
  local mode = opts and opts.mode or "interp"
  local inst
  if mode == "jit" or mode == "compile" then
    if not M.can_jit() then
      error('jit unavailable: this VM refuses Lua 5.1 bytecode (CC:Tweaked >= 1.109 blocks it). Use mode="transpile" or mode="auto".', 0)
    end
    inst = require("compiler").instantiate(module, imports, opts)
    inst.mode = "jit"
  elseif mode == "transpile" then
    inst = require("transpiler").instantiate(module, imports, opts)
    inst.mode = "transpile"
  elseif mode == "auto" then
    if M.can_jit() then
      inst = require("compiler").instantiate(module, imports, opts)
      inst.mode = "jit"
    else
      local ok, t = pcall(require, "transpiler")
      if ok then
        inst = t.instantiate(module, imports, opts)
        inst.mode = "transpile"
      else
        inst = interp.instantiate(module, imports)
        inst.mode = "interp"
      end
    end
  else
    inst = interp.instantiate(module, imports)
    inst.mode = "interp"
  end
  return inst
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
  if (opts and opts.mode or "jit") ~= "interp" and M.can_jit() then
    local compiler = require("compiler")
    return { module = module, jit = true,
             instantiate = function(_, imports) return compiler.instantiate(module, imports) end }
  end
  return { module = module, jit = false,
           instantiate = function(_, imports) return interp.instantiate(module, imports) end }
end

M.set_yield = interp.set_yield

return M
