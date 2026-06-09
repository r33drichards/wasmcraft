-- WebAssembly execution engine: instantiation + a structured-control interpreter.
local bit = require("bit")
local Memory = require("memory")

local M = {}

local POW32 = 2 ^ 32
local POW31 = 2 ^ 31
local sunpack, spack = string.unpack, string.pack
local floor = math.floor

-- i32 canonical form: unsigned 0..2^32-1 (exact in a double).
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

local function clz32(x) if x == 0 then return 32 end local n = 0; while x < 0x80000000 do x = x * 2; n = n + 1 end return n end
local function ctz32(x) if x == 0 then return 32 end local n = 0; while x % 2 == 0 do x = x / 2; n = n + 1 end return n end
local function popcnt32(x) local n = 0; while x > 0 do n = n + (x % 2); x = floor(x / 2) end return n end

-- ---- host/internal coercion (i32 only here; wider types in later milestones)
local function host_to_internal(t, v)
  if t == "i32" then return to_u32(v or 0) end
  return v or 0
end
local function internal_to_host(t, v)
  if t == "i32" then return to_s32(v) end
  return v
end

-- ---- block-type arity ----------------------------------------------------
local function bt_arity(mod, bt)
  if bt.typeidx then
    local ft = mod.types[bt.typeidx + 1]
    return #ft.params, #ft.results
  end
  return #bt.params, #bt.results
end

local Instance = {}
Instance.__index = Instance

local run -- forward decl

-- Evaluate a constant expression (global init / segment offset).
local function evalConst(inst, instrs)
  local v
  for i = 1, #instrs do
    local ins = instrs[i]
    local op = ins.op
    if op == "i32.const" then v = to_u32(ins.v)
    elseif op == "i64.const" then v = ins.v
    elseif op == "f32.const" or op == "f64.const" then v = ins.v
    elseif op == "global.get" then v = inst.globals[ins.x]
    elseif op == "ref.func" then v = ins.func
    elseif op == "ref.null" then v = nil
    elseif op == "end" then break
    else error("unsupported const expr op " .. op) end
  end
  return v
end

-- Execute one function by global function index with internal args. Returns array of results.
run = function(inst, funcIdx, args)
  local fn = inst.functions[funcIdx]
  if not fn then error("call to undefined function index " .. tostring(funcIdx)) end
  if fn.host then
    local res = fn.host(args, inst)
    return res or {}
  end

  local mod = inst.module
  local code = fn.code
  local ftype = fn.type
  local mem = inst.memory

  -- locals: params then declared (zero-initialised)
  local L = {}
  local np = #ftype.params
  for i = 1, np do L[i - 1] = args[i] or 0 end
  for i = 1, #code.locals do L[np + i - 1] = 0 end

  -- operand stack (st.n = height)
  local st = { n = 0 }
  local function push(v) st.n = st.n + 1; st[st.n] = v end
  local function pop() local v = st[st.n]; st.n = st.n - 1; return v end

  local body = code.body
  local n = #body

  -- control stack; bottom frame represents the function body
  local ctrl = { { kind = "block", height = 0, arity = #ftype.results, cont = n + 1 } }

  local function branch(label)
    local fi = #ctrl - label
    local fr = ctrl[fi]
    local keep = fr.arity
    local base = fr.height
    for i = 1, keep do st[base + i] = st[st.n - keep + i] end
    st.n = base + keep
    for i = #ctrl, fi + 1, -1 do ctrl[i] = nil end
    if fr.kind == "loop" then return fr.start else return fr.cont end
  end

  local function trap(msg) error("wasm trap: " .. msg) end
  local function ea(ins) return to_u32(pop() + ins.offset) end
  local function bounds(addr, sz) if addr + sz > mem.pages * 65536 then trap("out of bounds memory access") end end

  local pc = 1
  while pc <= n do
    local ins = body[pc]
    local op = ins.op
    local nextpc = pc + 1

    if op == "local.get" then push(L[ins.x])
    elseif op == "local.set" then L[ins.x] = pop()
    elseif op == "local.tee" then L[ins.x] = st[st.n]
    elseif op == "global.get" then push(inst.globals[ins.x])
    elseif op == "global.set" then inst.globals[ins.x] = pop()
    elseif op == "i32.const" then push(to_u32(ins.v))
    elseif op == "drop" then st.n = st.n - 1
    elseif op == "select" then
      local c = pop(); local b = pop(); local a = pop()
      push(c ~= 0 and a or b)

    -- structured control
    elseif op == "block" then
      local p, res = bt_arity(mod, ins.bt)
      ctrl[#ctrl + 1] = { kind = "block", height = st.n - p, arity = res, cont = ins.end_pc }
    elseif op == "loop" then
      local p, res = bt_arity(mod, ins.bt)
      ctrl[#ctrl + 1] = { kind = "loop", height = st.n - p, arity = p, start = pc + 1, cont = ins.end_pc }
    elseif op == "if" then
      local p, res = bt_arity(mod, ins.bt)
      local cond = pop()
      ctrl[#ctrl + 1] = { kind = "if", height = st.n - p, arity = res, cont = ins.end_pc }
      if cond == 0 then nextpc = ins.else_pc and (ins.else_pc + 1) or ins.end_pc end
    elseif op == "else" then
      nextpc = ins.end_pc -- reached only by falling out of the then-branch
    elseif op == "end" then
      ctrl[#ctrl] = nil
    elseif op == "br" then
      nextpc = branch(ins.label)
    elseif op == "br_if" then
      if pop() ~= 0 then nextpc = branch(ins.label) end
    elseif op == "br_table" then
      local i = pop()
      local t = ins.targets
      local lab = (i < #t) and t[i + 1] or ins.default
      nextpc = branch(lab)
    elseif op == "return" then
      nextpc = branch(#ctrl - 1)
    elseif op == "call" then
      local callee = inst.functions[ins.func]
      local cp = #callee.type.params
      local a = {}
      for i = cp, 1, -1 do a[i] = pop() end
      local res = run(inst, ins.func, a)
      for i = 1, #res do push(res[i]) end
    elseif op == "call_indirect" then
      local tbl = inst.tables[ins.table]
      local idx = pop()
      local target = tbl and tbl[idx]
      if target == nil then trap("uninitialized element " .. tostring(idx)) end
      local ft = mod.types[ins.typeidx + 1]
      local cp = #ft.params
      local a = {}
      for i = cp, 1, -1 do a[i] = pop() end
      local res = run(inst, target, a)
      for i = 1, #res do push(res[i]) end
    elseif op == "unreachable" then
      trap("unreachable")
    elseif op == "nop" then
      -- nothing

    -- memory
    elseif op == "i32.load" then local a = ea(ins); bounds(a, 4); push((sunpack("<I4", mem:loadstr(a, 4))))
    elseif op == "i32.load8_u" then local a = ea(ins); bounds(a, 1); push(mem:get8(a))
    elseif op == "i32.load8_s" then local a = ea(ins); bounds(a, 1); local b = mem:get8(a); push(to_u32(b >= 128 and b - 256 or b))
    elseif op == "i32.load16_u" then local a = ea(ins); bounds(a, 2); push((sunpack("<I2", mem:loadstr(a, 2))))
    elseif op == "i32.load16_s" then local a = ea(ins); bounds(a, 2); push(to_u32((sunpack("<i2", mem:loadstr(a, 2)))))
    elseif op == "i32.store" then local v = pop(); local a = ea(ins); bounds(a, 4); mem:storestr(a, spack("<I4", v))
    elseif op == "i32.store8" then local v = pop(); local a = ea(ins); bounds(a, 1); mem:set8(a, v % 256)
    elseif op == "i32.store16" then local v = pop(); local a = ea(ins); bounds(a, 2); mem:storestr(a, spack("<I2", v % 65536))
    elseif op == "memory.size" then push(mem:size())
    elseif op == "memory.grow" then local d = pop(); push(to_u32(mem:grow(d)))

    -- i32 comparisons
    elseif op == "i32.eqz" then push(pop() == 0 and 1 or 0)
    elseif op == "i32.eq" then push(pop() == pop() and 1 or 0)
    elseif op == "i32.ne" then push(pop() ~= pop() and 1 or 0)
    elseif op == "i32.lt_s" then local b = pop(); local a = pop(); push(to_s32(a) < to_s32(b) and 1 or 0)
    elseif op == "i32.lt_u" then local b = pop(); local a = pop(); push(a < b and 1 or 0)
    elseif op == "i32.gt_s" then local b = pop(); local a = pop(); push(to_s32(a) > to_s32(b) and 1 or 0)
    elseif op == "i32.gt_u" then local b = pop(); local a = pop(); push(a > b and 1 or 0)
    elseif op == "i32.le_s" then local b = pop(); local a = pop(); push(to_s32(a) <= to_s32(b) and 1 or 0)
    elseif op == "i32.le_u" then local b = pop(); local a = pop(); push(a <= b and 1 or 0)
    elseif op == "i32.ge_s" then local b = pop(); local a = pop(); push(to_s32(a) >= to_s32(b) and 1 or 0)
    elseif op == "i32.ge_u" then local b = pop(); local a = pop(); push(a >= b and 1 or 0)

    -- i32 arithmetic
    elseif op == "i32.clz" then push(clz32(pop()))
    elseif op == "i32.ctz" then push(ctz32(pop()))
    elseif op == "i32.popcnt" then push(popcnt32(pop()))
    elseif op == "i32.add" then local b = pop(); local a = pop(); push(to_u32(a + b))
    elseif op == "i32.sub" then local b = pop(); local a = pop(); push(to_u32(a - b))
    elseif op == "i32.mul" then
      local b = pop(); local a = pop()
      -- low 32 bits of a*b via 16-bit lanes (each partial product < 2^53)
      local al = a % 65536; local ah = floor(a / 65536)
      local bl = b % 65536; local bh = floor(b / 65536)
      local cross = (ah * bl + al * bh) % 65536
      push((al * bl + cross * 65536) % POW32)
    elseif op == "i32.div_s" then
      local b = to_s32(pop()); local a = to_s32(pop())
      if b == 0 then trap("integer divide by zero") end
      if a == -2147483648 and b == -1 then trap("integer overflow") end
      local q = a / b; q = q >= 0 and floor(q) or -floor(-q)
      push(to_u32(q))
    elseif op == "i32.div_u" then
      local b = pop(); local a = pop()
      if b == 0 then trap("integer divide by zero") end
      push(floor(a / b))
    elseif op == "i32.rem_s" then
      local b = to_s32(pop()); local a = to_s32(pop())
      if b == 0 then trap("integer divide by zero") end
      local q = a / b; q = q >= 0 and floor(q) or -floor(-q)
      push(to_u32(a - q * b))
    elseif op == "i32.rem_u" then
      local b = pop(); local a = pop()
      if b == 0 then trap("integer divide by zero") end
      push(a - floor(a / b) * b)
    elseif op == "i32.and" then push(bit.band(pop(), pop()))
    elseif op == "i32.or" then push(bit.bor(pop(), pop()))
    elseif op == "i32.xor" then push(bit.bxor(pop(), pop()))
    elseif op == "i32.shl" then local c = pop() % 32; push(bit.lshift(pop(), c))
    elseif op == "i32.shr_s" then local c = pop() % 32; push(bit.arshift(pop(), c))
    elseif op == "i32.shr_u" then local c = pop() % 32; push(bit.rshift(pop(), c))
    elseif op == "i32.rotl" then local c = pop() % 32; push(bit.lrotate(pop(), c))
    elseif op == "i32.rotr" then local c = pop() % 32; push(bit.rrotate(pop(), c))

    else
      error("interp: unhandled op " .. tostring(op))
    end

    pc = nextpc
  end

  local nres = #ftype.results
  local out = {}
  for i = nres, 1, -1 do out[i] = pop() end
  return out
end

function Instance:call(name, ...)
  local exp = self.module.exports[name]
  if not exp or exp.kind ~= "func" then error("no exported function '" .. tostring(name) .. "'") end
  local fn = self.functions[exp.index]
  local ftype = fn.type
  local raw = { ... }
  local args = {}
  for i = 1, #ftype.params do args[i] = host_to_internal(ftype.params[i], raw[i]) end
  local out = run(self, exp.index, args)
  local res = {}
  for i = 1, #ftype.results do res[i] = internal_to_host(ftype.results[i], out[i]) end
  return (table.unpack or unpack)(res)
end

function M.instantiate(module, imports)
  imports = imports or {}
  local inst = setmetatable({ module = module, imports = imports }, Instance)

  -- functions table (0-based global index space: imports first, then defined)
  inst.functions = {}
  for i = 1, module.numImportedFuncs do
    local imp = module.importedFuncs[i]
    local host = imports[imp.module] and imports[imp.module][imp.name]
    if not host then error("missing import: " .. imp.module .. "." .. imp.name) end
    inst.functions[i - 1] = { type = module.types[imp.typeidx + 1], host = host }
  end
  for j = 1, #module.funcTypeIdx do
    local idx = module.numImportedFuncs + (j - 1)
    inst.functions[idx] = { type = module.types[module.funcTypeIdx[j] + 1], code = module.codes[j] }
  end

  -- memory
  if module.importedMem then
    inst.memory = imports[module.importedMem.module][module.importedMem.name]
  elseif module.memories[1] then
    inst.memory = Memory.new(module.memories[1].min, module.memories[1].max)
  else
    inst.memory = Memory.new(0)
  end

  -- globals (imported first, then defined via const-expr init)
  inst.globals = {}
  -- (imported globals not exercised yet; left for Milestone D)
  for i = 1, #module.globals do
    inst.globals[module.numImportedGlobals + (i - 1)] = evalConst(inst, module.globals[i].init)
  end

  -- tables
  inst.tables = {}
  for i = 1, #module.tables do
    inst.tables[i - 1] = {} -- 0-based slots, nil by default
  end

  -- element segments (active → write into tables)
  for _, seg in ipairs(module.elements) do
    if seg.mode == "active" then
      local base = evalConst(inst, seg.offset)
      local tbl = inst.tables[seg.table or 0]
      for k = 1, #seg.funcs do tbl[base + k - 1] = seg.funcs[k] end
    end
  end

  -- data segments (active → write into memory)
  for _, seg in ipairs(module.datas) do
    if seg.mode == "active" then
      local base = evalConst(inst, seg.offset)
      inst.memory:storestr(base, seg.bytes)
    end
  end

  -- start function
  if module.start ~= nil then run(inst, module.start, {}) end

  return inst
end

return M
