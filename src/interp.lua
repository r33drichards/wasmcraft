-- WebAssembly execution engine: instantiation + a structured interpreter.
-- Grows per milestone; currently: const/local ops + i32.add, linear bodies.
local M = {}

local POW32 = 2 ^ 32
local POW31 = 2 ^ 31

-- i32 canonical form is unsigned 0..2^32-1 (exact in a double).
local function to_u32(x)
  x = x % POW32
  if x < 0 then x = x + POW32 end
  return x
end
local function to_s32(x)
  x = to_u32(x)
  if x >= POW31 then x = x - POW32 end
  return x
end
M.to_u32, M.to_s32 = to_u32, to_s32

-- Coerce a host-supplied Lua value into the internal form for a given valtype.
local function host_to_internal(t, v)
  if t == "i32" then return to_u32(v or 0) end
  return v or 0 -- i64/f32/f64 handled in later milestones
end

-- Coerce an internal value back to a host-friendly Lua value.
local function internal_to_host(t, v)
  if t == "i32" then return to_s32(v) end
  return v
end

local Instance = {}
Instance.__index = Instance

-- Execute one function (by defined-function index) with the given internal args.
local function invoke(inst, funcIdx, args)
  local mod = inst.module
  local typeIdx = mod.funcTypeIdx[funcIdx - mod.numImportedFuncs + 1] -- 0-based -> code slot
  -- funcIdx here is 0-based overall; with no imports it indexes codes directly.
  local code = mod.codes[funcIdx - mod.numImportedFuncs + 1]
  local ftype = mod.types[typeIdx + 1]

  -- locals: params first, then declared locals (zero-initialised)
  local locals = {}
  for i = 1, #ftype.params do locals[i - 1] = args[i] or 0 end
  local base = #ftype.params
  for i = 1, #code.locals do locals[base + i - 1] = 0 end

  -- value stack
  local stack, sp = {}, 0
  local function push(v) sp = sp + 1; stack[sp] = v end
  local function pop() local v = stack[sp]; sp = sp - 1; return v end

  local body = code.body
  local pc = 1
  local n = #body
  while pc <= n do
    local ins = body[pc]
    local op = ins.op
    if op == "local.get" then
      push(locals[ins.x])
    elseif op == "local.set" then
      locals[ins.x] = pop()
    elseif op == "local.tee" then
      locals[ins.x] = stack[sp]
    elseif op == "i32.const" then
      push(to_u32(ins.v))
    elseif op == "i32.add" then
      local b, a = pop(), pop()
      push(to_u32(a + b))
    elseif op == "nop" then
      -- no-op
    elseif op == "return" then
      break
    elseif op == "unreachable" then
      error("wasm trap: unreachable")
    else
      error("interp: unhandled op " .. tostring(op))
    end
    pc = pc + 1
  end

  -- collect results (top-of-stack, in order)
  local nres = #ftype.results
  local out = {}
  for i = nres, 1, -1 do out[i] = pop() end
  return out, ftype
end

function Instance:call(name, ...)
  local exp = self.module.exports[name]
  if not exp or exp.kind ~= "func" then error("no exported function '" .. tostring(name) .. "'") end
  local mod = self.module
  local funcIdx = exp.index
  local typeIdx = mod.funcTypeIdx[funcIdx - mod.numImportedFuncs + 1]
  local ftype = mod.types[typeIdx + 1]

  local rawArgs = { ... }
  local args = {}
  for i = 1, #ftype.params do args[i] = host_to_internal(ftype.params[i], rawArgs[i]) end

  local out = invoke(self, funcIdx, args)

  -- return host-friendly values
  local res = {}
  for i = 1, #ftype.results do res[i] = internal_to_host(ftype.results[i], out[i]) end
  return table.unpack and table.unpack(res) or unpack(res)
end

function M.instantiate(module, imports)
  return setmetatable({ module = module, imports = imports or {} }, Instance)
end

return M
