-- WebAssembly execution engine: instantiation + a structured-control interpreter.
local bit = require("bit")
local Memory = require("memory")
local I = require("int64")

local M = {}

local POW32 = 2 ^ 32
local POW31 = 2 ^ 31
local POW63 = 2 ^ 63
local POW64 = 2 ^ 64
local sunpack, spack = string.unpack, string.pack
local floor, ceil, abs = math.floor, math.ceil, math.abs
local huge = math.huge

-- ---- float helpers -------------------------------------------------------
local function f32round(x) return (sunpack("<f", spack("<f", x))) end
local function isnan(x) return x ~= x end
local function ftrunc(x)
  if x ~= x or x == huge or x == -huge then return x end
  return x >= 0 and floor(x) or ceil(x)
end
local function fnearest(x) -- round half to even
  if x ~= x or x == huge or x == -huge or x == 0 then return x end
  local f = floor(x)
  local diff = x - f
  local r
  if diff < 0.5 then r = f
  elseif diff > 0.5 then r = f + 1
  else r = (f % 2 == 0) and f or (f + 1) end
  if r == 0 and x < 0 then return -0.0 end
  return r
end
local function fmin(a, b)
  if a ~= a then return a end; if b ~= b then return b end
  if a == 0 and b == 0 then return (1 / a == -huge or 1 / b == -huge) and -0.0 or 0.0 end
  return a < b and a or b
end
local function fmax(a, b)
  if a ~= a then return a end; if b ~= b then return b end
  if a == 0 and b == 0 then return (1 / a == huge or 1 / b == huge) and 0.0 or -0.0 end
  return a > b and a or b
end
local function copysign(a, b)
  local s = (b < 0 or (b == 0 and 1 / b == -huge))
  a = abs(a)
  return s and -a or a
end

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

-- Cooperative yielding: heavy modules (e.g. SQLite) would otherwise run for
-- seconds and trip CC:Tweaked's "too long without yielding" watchdog. A host can
-- register a hook that is called every `yield_every` instructions.
local yield_hook = nil
local yield_every = 100000
local ycount = 0
function M.set_yield(fn, every)
  yield_hook = fn
  if every then yield_every = every end
end

local function clz32(x) if x == 0 then return 32 end local n = 0; while x < 0x80000000 do x = x * 2; n = n + 1 end return n end
local function ctz32(x) if x == 0 then return 32 end local n = 0; while x % 2 == 0 do x = x / 2; n = n + 1 end return n end
local function popcnt32(x) local n = 0; while x > 0 do n = n + (x % 2); x = floor(x / 2) end return n end

-- ---- host/internal coercion ----------------------------------------------
local function host_to_internal(t, v)
  if t == "i32" then return to_u32(v or 0) end
  if t == "i64" then
    if I.is(v) then return v end
    return I.from_double_s(v or 0)
  end
  if t == "f32" then return f32round(v or 0) end
  return v or 0 -- f64 native
end
local function internal_to_host(t, v)
  if t == "i32" then return to_s32(v) end
  if t == "i64" then return I.to_double_s(v) end -- may lose precision >2^53
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
    if yield_hook then
      ycount = ycount + 1
      if ycount >= yield_every then ycount = 0; yield_hook() end
    end
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
    elseif op == "memory.fill" then
      local n = pop(); local val = pop(); local d = pop()
      if d + n > mem.pages * 65536 then trap("out of bounds memory access") end
      mem:fill(d, val, n)
    elseif op == "memory.copy" then
      local n = pop(); local s = pop(); local d = pop()
      local lim = mem.pages * 65536
      if d + n > lim or s + n > lim then trap("out of bounds memory access") end
      mem:copy(d, s, n)

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

    -- ===== i64 =====
    elseif op == "i64.const" then push(ins.v)
    elseif op == "i64.eqz" then push(I.eqz(pop()) and 1 or 0)
    elseif op == "i64.eq" then local b = pop(); local a = pop(); push(I.eq(a, b) and 1 or 0)
    elseif op == "i64.ne" then local b = pop(); local a = pop(); push(I.eq(a, b) and 0 or 1)
    elseif op == "i64.lt_s" then local b = pop(); local a = pop(); push(I.lt_s(a, b) and 1 or 0)
    elseif op == "i64.lt_u" then local b = pop(); local a = pop(); push(I.lt_u(a, b) and 1 or 0)
    elseif op == "i64.gt_s" then local b = pop(); local a = pop(); push(I.lt_s(b, a) and 1 or 0)
    elseif op == "i64.gt_u" then local b = pop(); local a = pop(); push(I.lt_u(b, a) and 1 or 0)
    elseif op == "i64.le_s" then local b = pop(); local a = pop(); push(I.lt_s(b, a) and 0 or 1)
    elseif op == "i64.le_u" then local b = pop(); local a = pop(); push(I.lt_u(b, a) and 0 or 1)
    elseif op == "i64.ge_s" then local b = pop(); local a = pop(); push(I.lt_s(a, b) and 0 or 1)
    elseif op == "i64.ge_u" then local b = pop(); local a = pop(); push(I.lt_u(a, b) and 0 or 1)
    elseif op == "i64.clz" then push(I.from_u32(I.clz(pop())))
    elseif op == "i64.ctz" then push(I.from_u32(I.ctz(pop())))
    elseif op == "i64.popcnt" then push(I.from_u32(I.popcnt(pop())))
    elseif op == "i64.add" then local b = pop(); local a = pop(); push(I.add(a, b))
    elseif op == "i64.sub" then local b = pop(); local a = pop(); push(I.sub(a, b))
    elseif op == "i64.mul" then local b = pop(); local a = pop(); push(I.mul(a, b))
    elseif op == "i64.div_s" then local b = pop(); local a = pop(); push(I.div_s(a, b))
    elseif op == "i64.div_u" then local b = pop(); local a = pop(); push(I.div_u(a, b))
    elseif op == "i64.rem_s" then local b = pop(); local a = pop(); push(I.rem_s(a, b))
    elseif op == "i64.rem_u" then local b = pop(); local a = pop(); push(I.rem_u(a, b))
    elseif op == "i64.and" then local b = pop(); local a = pop(); push(I.band(a, b))
    elseif op == "i64.or" then local b = pop(); local a = pop(); push(I.bor(a, b))
    elseif op == "i64.xor" then local b = pop(); local a = pop(); push(I.bxor(a, b))
    elseif op == "i64.shl" then local c = pop(); push(I.shl(pop(), c.l % 64))
    elseif op == "i64.shr_s" then local c = pop(); push(I.shr_s(pop(), c.l % 64))
    elseif op == "i64.shr_u" then local c = pop(); push(I.shr_u(pop(), c.l % 64))
    elseif op == "i64.rotl" then local c = pop(); push(I.rotl(pop(), c.l % 64))
    elseif op == "i64.rotr" then local c = pop(); push(I.rotr(pop(), c.l % 64))

    -- ===== conversions =====
    elseif op == "i32.wrap_i64" then push(to_u32(pop().l))
    elseif op == "i64.extend_i32_s" then push(I.from_s32(to_s32(pop())))
    elseif op == "i64.extend_i32_u" then push(I.from_u32(pop()))
    elseif op == "i32.extend8_s" then local x = pop() % 256; push(to_u32(x >= 128 and x - 256 or x))
    elseif op == "i32.extend16_s" then local x = pop() % 65536; push(to_u32(x >= 32768 and x - 65536 or x))
    elseif op == "i64.extend8_s" then local x = pop().l % 256; push(I.from_double_s(x >= 128 and x - 256 or x))
    elseif op == "i64.extend16_s" then local x = pop().l % 65536; push(I.from_double_s(x >= 32768 and x - 65536 or x))
    elseif op == "i64.extend32_s" then push(I.from_s32(to_s32(pop().l)))

    elseif op == "i32.trunc_f32_s" or op == "i32.trunc_f64_s" then
      local x = ftrunc(pop())
      if isnan(x) or x < -POW31 or x >= POW31 then trap("invalid conversion to integer") end
      push(to_u32(x))
    elseif op == "i32.trunc_f32_u" or op == "i32.trunc_f64_u" then
      local x = ftrunc(pop())
      if isnan(x) or x <= -1 or x >= POW32 then trap("invalid conversion to integer") end
      push(to_u32(x))
    elseif op == "i64.trunc_f32_s" or op == "i64.trunc_f64_s" then
      local x = ftrunc(pop())
      if isnan(x) or x < -POW63 or x >= POW63 then trap("invalid conversion to integer") end
      push(I.from_double_s(x))
    elseif op == "i64.trunc_f32_u" or op == "i64.trunc_f64_u" then
      local x = ftrunc(pop())
      if isnan(x) or x <= -1 or x >= POW64 then trap("invalid conversion to integer") end
      push(I.from_double_u(x))
    elseif op == "i32.trunc_sat_f32_s" or op == "i32.trunc_sat_f64_s" then
      local x = pop()
      if isnan(x) then push(0) elseif x < -POW31 then push(to_u32(-POW31)) elseif x >= POW31 then push(POW31 - 1) else push(to_u32(ftrunc(x))) end
    elseif op == "i32.trunc_sat_f32_u" or op == "i32.trunc_sat_f64_u" then
      local x = pop()
      if isnan(x) or x <= 0 then push(0) elseif x >= POW32 then push(POW32 - 1) else push(to_u32(ftrunc(x))) end
    elseif op == "i64.trunc_sat_f32_s" or op == "i64.trunc_sat_f64_s" then
      local x = pop()
      if isnan(x) then push(I.ZERO) elseif x < -POW63 then push(I.mk(0x80000000, 0)) elseif x >= POW63 then push(I.mk(0x7FFFFFFF, 0xFFFFFFFF)) else push(I.from_double_s(ftrunc(x))) end
    elseif op == "i64.trunc_sat_f32_u" or op == "i64.trunc_sat_f64_u" then
      local x = pop()
      if isnan(x) or x <= 0 then push(I.ZERO) elseif x >= POW64 then push(I.mk(0xFFFFFFFF, 0xFFFFFFFF)) else push(I.from_double_u(ftrunc(x))) end

    elseif op == "f32.convert_i32_s" then push(f32round(to_s32(pop())))
    elseif op == "f32.convert_i32_u" then push(f32round(pop()))
    elseif op == "f64.convert_i32_s" then push(to_s32(pop()) + 0.0)
    elseif op == "f64.convert_i32_u" then push(pop() + 0.0)
    elseif op == "f32.convert_i64_s" then push(f32round(I.to_double_s(pop())))
    elseif op == "f32.convert_i64_u" then push(f32round(I.to_double_u(pop())))
    elseif op == "f64.convert_i64_s" then push(I.to_double_s(pop()))
    elseif op == "f64.convert_i64_u" then push(I.to_double_u(pop()))
    elseif op == "f32.demote_f64" then push(f32round(pop()))
    elseif op == "f64.promote_f32" then push(pop())

    elseif op == "i32.reinterpret_f32" then push((sunpack("<I4", spack("<f", pop()))))
    elseif op == "f32.reinterpret_i32" then push((sunpack("<f", spack("<I4", pop()))))
    elseif op == "i64.reinterpret_f64" then push(I.from_bytes8(spack("<d", pop())))
    elseif op == "f64.reinterpret_i64" then push((sunpack("<d", I.to_bytes(pop()))))

    -- ===== float arithmetic =====
    elseif op == "f64.abs" then push(abs(pop()))
    elseif op == "f64.neg" then push(-pop())
    elseif op == "f64.ceil" then push(ceil(pop()))
    elseif op == "f64.floor" then push(floor(pop()))
    elseif op == "f64.trunc" then push(ftrunc(pop()))
    elseif op == "f64.nearest" then push(fnearest(pop()))
    elseif op == "f64.sqrt" then push(math.sqrt(pop()))
    elseif op == "f64.add" then local b = pop(); push(pop() + b)
    elseif op == "f64.sub" then local b = pop(); push(pop() - b)
    elseif op == "f64.mul" then local b = pop(); push(pop() * b)
    elseif op == "f64.div" then local b = pop(); push(pop() / b)
    elseif op == "f64.min" then local b = pop(); push(fmin(pop(), b))
    elseif op == "f64.max" then local b = pop(); push(fmax(pop(), b))
    elseif op == "f64.copysign" then local b = pop(); push(copysign(pop(), b))
    elseif op == "f32.abs" then push(f32round(abs(pop())))
    elseif op == "f32.neg" then push(f32round(-pop()))
    elseif op == "f32.ceil" then push(f32round(ceil(pop())))
    elseif op == "f32.floor" then push(f32round(floor(pop())))
    elseif op == "f32.trunc" then push(f32round(ftrunc(pop())))
    elseif op == "f32.nearest" then push(f32round(fnearest(pop())))
    elseif op == "f32.sqrt" then push(f32round(math.sqrt(pop())))
    elseif op == "f32.add" then local b = pop(); push(f32round(pop() + b))
    elseif op == "f32.sub" then local b = pop(); push(f32round(pop() - b))
    elseif op == "f32.mul" then local b = pop(); push(f32round(pop() * b))
    elseif op == "f32.div" then local b = pop(); push(f32round(pop() / b))
    elseif op == "f32.min" then local b = pop(); push(f32round(fmin(pop(), b)))
    elseif op == "f32.max" then local b = pop(); push(f32round(fmax(pop(), b)))
    elseif op == "f32.copysign" then local b = pop(); push(f32round(copysign(pop(), b)))

    -- ===== float comparisons (NaN-aware via Lua semantics) =====
    elseif op == "f32.eq" or op == "f64.eq" then local b = pop(); push(pop() == b and 1 or 0)
    elseif op == "f32.ne" or op == "f64.ne" then local b = pop(); push(pop() ~= b and 1 or 0)
    elseif op == "f32.lt" or op == "f64.lt" then local b = pop(); push(pop() < b and 1 or 0)
    elseif op == "f32.gt" or op == "f64.gt" then local b = pop(); push(pop() > b and 1 or 0)
    elseif op == "f32.le" or op == "f64.le" then local b = pop(); push(pop() <= b and 1 or 0)
    elseif op == "f32.ge" or op == "f64.ge" then local b = pop(); push(pop() >= b and 1 or 0)

    -- ===== i64 / float memory =====
    elseif op == "i64.load" then local a = ea(ins); bounds(a, 8); push(I.from_bytes8(mem:loadstr(a, 8)))
    elseif op == "i64.store" then local v = pop(); local a = ea(ins); bounds(a, 8); mem:storestr(a, I.to_bytes(v))
    elseif op == "i64.load8_u" then local a = ea(ins); bounds(a, 1); push(I.from_u32(mem:get8(a)))
    elseif op == "i64.load8_s" then local a = ea(ins); bounds(a, 1); local b = mem:get8(a); push(I.from_double_s(b >= 128 and b - 256 or b))
    elseif op == "i64.load16_u" then local a = ea(ins); bounds(a, 2); push(I.from_u32((sunpack("<I2", mem:loadstr(a, 2)))))
    elseif op == "i64.load16_s" then local a = ea(ins); bounds(a, 2); push(I.from_double_s((sunpack("<i2", mem:loadstr(a, 2)))))
    elseif op == "i64.load32_u" then local a = ea(ins); bounds(a, 4); push(I.from_u32((sunpack("<I4", mem:loadstr(a, 4)))))
    elseif op == "i64.load32_s" then local a = ea(ins); bounds(a, 4); push(I.from_s32(to_s32((sunpack("<I4", mem:loadstr(a, 4))))))
    elseif op == "i64.store8" then local v = pop(); local a = ea(ins); bounds(a, 1); mem:set8(a, v.l % 256)
    elseif op == "i64.store16" then local v = pop(); local a = ea(ins); bounds(a, 2); mem:storestr(a, spack("<I2", v.l % 65536))
    elseif op == "i64.store32" then local v = pop(); local a = ea(ins); bounds(a, 4); mem:storestr(a, spack("<I4", v.l))
    elseif op == "f32.load" then local a = ea(ins); bounds(a, 4); push((sunpack("<f", mem:loadstr(a, 4))))
    elseif op == "f32.store" then local v = pop(); local a = ea(ins); bounds(a, 4); mem:storestr(a, spack("<f", v))
    elseif op == "f64.load" then local a = ea(ins); bounds(a, 8); push((sunpack("<d", mem:loadstr(a, 8))))
    elseif op == "f64.store" then local v = pop(); local a = ea(ins); bounds(a, 8); mem:storestr(a, spack("<d", v))

    -- ===== const (float) =====
    elseif op == "f32.const" then push(ins.v)
    elseif op == "f64.const" then push(ins.v)

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
