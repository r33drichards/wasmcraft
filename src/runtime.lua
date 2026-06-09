-- Runtime support for compiled wasm functions. Compiled Lua 5.1 bytecode calls
-- these helpers (via an ENV upvalue) for everything that isn't a single Lua
-- instruction: signed/wider arithmetic, i64 (boxed), floats, conversions, and
-- memory/global/table/function access. Semantics mirror src/interp.lua exactly.
local bit = require("bit")
local I = require("int64")
local floor, ceil, abs, huge = math.floor, math.ceil, math.abs, math.huge
local sqrt = math.sqrt
local spack, sunpack = string.pack, string.unpack
local POW32, POW31, POW63, POW64 = 2 ^ 32, 2 ^ 31, 2 ^ 63, 2 ^ 64

local function to_u32(x) x = x % POW32; if x < 0 then x = x + POW32 end; return x end
local function to_s32(x) x = to_u32(x); if x >= POW31 then x = x - POW32 end; return x end

local function clz32(x) if x == 0 then return 32 end local n = 0; while x < 0x80000000 do x = x * 2; n = n + 1 end return n end
local function ctz32(x) if x == 0 then return 32 end local n = 0; while x % 2 == 0 do x = x / 2; n = n + 1 end return n end
local function popcnt32(x) local n = 0; while x > 0 do n = n + (x % 2); x = floor(x / 2) end return n end

local function f32round(x) return (sunpack("<f", spack("<f", x))) end
local function isnan(x) return x ~= x end
local function ftrunc(x) if x ~= x or x == huge or x == -huge then return x end return x >= 0 and floor(x) or ceil(x) end
local function fnearest(x)
  if x ~= x or x == huge or x == -huge or x == 0 then return x end
  local f = floor(x); local d = x - f; local r
  if d < 0.5 then r = f elseif d > 0.5 then r = f + 1 else r = (f % 2 == 0) and f or (f + 1) end
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
local function copysign(a, b) local s = (b < 0 or (b == 0 and 1 / b == -huge)); a = abs(a); return s and -a or a end

local M = {}
M.to_u32, M.to_s32 = to_u32, to_s32

function M.make(inst)
  local E = {}
  local b01 = function(c) return c and 1 or 0 end

  -- ===== i32 =====
  E.mul = function(a, b)
    local al = a % 65536; local ah = floor(a / 65536); local bl = b % 65536; local bh = floor(b / 65536)
    return (al * bl + ((ah * bl + al * bh) % 65536) * 65536) % POW32
  end
  E.div_s = function(a, b) b = to_s32(b); a = to_s32(a)
    if b == 0 then error("wasm trap: integer divide by zero") end
    if a == -2147483648 and b == -1 then error("wasm trap: integer overflow") end
    local q = a / b; return to_u32(q >= 0 and floor(q) or -floor(-q)) end
  E.div_u = function(a, b) if b == 0 then error("wasm trap: integer divide by zero") end return floor(a / b) end
  E.rem_s = function(a, b) b = to_s32(b); a = to_s32(a)
    if b == 0 then error("wasm trap: integer divide by zero") end
    local q = a / b; q = q >= 0 and floor(q) or -floor(-q); return to_u32(a - q * b) end
  E.rem_u = function(a, b) if b == 0 then error("wasm trap: integer divide by zero") end return a - floor(a / b) * b end
  E.band = function(a, b) return bit.band(a, b) end
  E.bor = function(a, b) return bit.bor(a, b) end
  E.bxor = function(a, b) return bit.bxor(a, b) end
  E.shl = function(a, b) return bit.lshift(a, b % 32) end
  E.shr_s = function(a, b) return bit.arshift(a, b % 32) end
  E.shr_u = function(a, b) return bit.rshift(a, b % 32) end
  E.rotl = function(a, b) return bit.lrotate(a, b % 32) end
  E.rotr = function(a, b) return bit.rrotate(a, b % 32) end
  E.clz = clz32; E.ctz = ctz32; E.popcnt = popcnt32
  E.eqz = function(a) return b01(a == 0) end
  E.eq = function(a, b) return b01(a == b) end
  E.ne = function(a, b) return b01(a ~= b) end
  E.lt_u = function(a, b) return b01(a < b) end
  E.gt_u = function(a, b) return b01(a > b) end
  E.le_u = function(a, b) return b01(a <= b) end
  E.ge_u = function(a, b) return b01(a >= b) end
  E.lt_s = function(a, b) return b01(to_s32(a) < to_s32(b)) end
  E.gt_s = function(a, b) return b01(to_s32(a) > to_s32(b)) end
  E.le_s = function(a, b) return b01(to_s32(a) <= to_s32(b)) end
  E.ge_s = function(a, b) return b01(to_s32(a) >= to_s32(b)) end
  E.i32_extend8_s = function(a) a = a % 256; return to_u32(a >= 128 and a - 256 or a) end
  E.i32_extend16_s = function(a) a = a % 65536; return to_u32(a >= 32768 and a - 65536 or a) end

  -- ===== i64 (boxed {h,l}) =====
  E.mk64 = I.mk
  E.i64_add = I.add; E.i64_sub = I.sub; E.i64_mul = I.mul
  E.i64_div_s = I.div_s; E.i64_div_u = I.div_u; E.i64_rem_s = I.rem_s; E.i64_rem_u = I.rem_u
  E.i64_and = I.band; E.i64_or = I.bor; E.i64_xor = I.bxor
  E.i64_shl = function(a, b) return I.shl(a, b.l % 64) end
  E.i64_shr_s = function(a, b) return I.shr_s(a, b.l % 64) end
  E.i64_shr_u = function(a, b) return I.shr_u(a, b.l % 64) end
  E.i64_rotl = function(a, b) return I.rotl(a, b.l % 64) end
  E.i64_rotr = function(a, b) return I.rotr(a, b.l % 64) end
  E.i64_clz = function(a) return I.from_u32(I.clz(a)) end
  E.i64_ctz = function(a) return I.from_u32(I.ctz(a)) end
  E.i64_popcnt = function(a) return I.from_u32(I.popcnt(a)) end
  E.i64_eqz = function(a) return b01(I.eqz(a)) end
  E.i64_eq = function(a, b) return b01(I.eq(a, b)) end
  E.i64_ne = function(a, b) return b01(not I.eq(a, b)) end
  E.i64_lt_s = function(a, b) return b01(I.lt_s(a, b)) end
  E.i64_lt_u = function(a, b) return b01(I.lt_u(a, b)) end
  E.i64_gt_s = function(a, b) return b01(I.lt_s(b, a)) end
  E.i64_gt_u = function(a, b) return b01(I.lt_u(b, a)) end
  E.i64_le_s = function(a, b) return b01(not I.lt_s(b, a)) end
  E.i64_le_u = function(a, b) return b01(not I.lt_u(b, a)) end
  E.i64_ge_s = function(a, b) return b01(not I.lt_s(a, b)) end
  E.i64_ge_u = function(a, b) return b01(not I.lt_u(a, b)) end

  -- ===== conversions =====
  E.i32_wrap_i64 = function(a) return to_u32(a.l) end
  E.i64_extend_i32_s = function(x) return I.from_s32(to_s32(x)) end
  E.i64_extend_i32_u = function(x) return I.from_u32(x) end
  E.i64_extend8_s = function(a) local x = a.l % 256; return I.from_double_s(x >= 128 and x - 256 or x) end
  E.i64_extend16_s = function(a) local x = a.l % 65536; return I.from_double_s(x >= 32768 and x - 65536 or x) end
  E.i64_extend32_s = function(a) return I.from_s32(to_s32(a.l)) end
  E.i32_trunc_f_s = function(x) x = ftrunc(x); if isnan(x) or x < -POW31 or x >= POW31 then error("wasm trap: invalid conversion to integer") end return to_u32(x) end
  E.i32_trunc_f_u = function(x) x = ftrunc(x); if isnan(x) or x <= -1 or x >= POW32 then error("wasm trap: invalid conversion to integer") end return to_u32(x) end
  E.i64_trunc_f_s = function(x) x = ftrunc(x); if isnan(x) or x < -POW63 or x >= POW63 then error("wasm trap: invalid conversion to integer") end return I.from_double_s(x) end
  E.i64_trunc_f_u = function(x) x = ftrunc(x); if isnan(x) or x <= -1 or x >= POW64 then error("wasm trap: invalid conversion to integer") end return I.from_double_u(x) end
  E.i32_trunc_sat_f_s = function(x) if isnan(x) then return 0 elseif x < -POW31 then return to_u32(-POW31) elseif x >= POW31 then return POW31 - 1 else return to_u32(ftrunc(x)) end end
  E.i32_trunc_sat_f_u = function(x) if isnan(x) or x <= 0 then return 0 elseif x >= POW32 then return POW32 - 1 else return to_u32(ftrunc(x)) end end
  E.i64_trunc_sat_f_s = function(x) if isnan(x) then return I.ZERO elseif x < -POW63 then return I.mk(0x80000000, 0) elseif x >= POW63 then return I.mk(0x7FFFFFFF, 0xFFFFFFFF) else return I.from_double_s(ftrunc(x)) end end
  E.i64_trunc_sat_f_u = function(x) if isnan(x) or x <= 0 then return I.ZERO elseif x >= POW64 then return I.mk(0xFFFFFFFF, 0xFFFFFFFF) else return I.from_double_u(ftrunc(x)) end end
  E.f32_convert_i32_s = function(x) return f32round(to_s32(x)) end
  E.f32_convert_i32_u = function(x) return f32round(x) end
  E.f64_convert_i32_s = function(x) return to_s32(x) + 0.0 end
  E.f64_convert_i32_u = function(x) return x + 0.0 end
  E.f32_convert_i64_s = function(a) return f32round(I.to_double_s(a)) end
  E.f32_convert_i64_u = function(a) return f32round(I.to_double_u(a)) end
  E.f64_convert_i64_s = function(a) return I.to_double_s(a) end
  E.f64_convert_i64_u = function(a) return I.to_double_u(a) end
  E.f32_demote_f64 = function(x) return f32round(x) end
  E.f64_promote_f32 = function(x) return x end
  E.i32_reinterpret_f32 = function(x) return (sunpack("<I4", spack("<f", x))) end
  E.f32_reinterpret_i32 = function(x) return (sunpack("<f", spack("<I4", x))) end
  E.i64_reinterpret_f64 = function(x) return I.from_bytes8(spack("<d", x)) end
  E.f64_reinterpret_i64 = function(a) return (sunpack("<d", I.to_bytes(a))) end

  -- ===== floats =====
  E.f32round = f32round
  E.fabs = abs; E.fneg = function(x) return -x end
  E.ceil = ceil; E.floor = floor; E.ftrunc = ftrunc; E.fnearest = fnearest; E.fsqrt = sqrt
  E.fmin = fmin; E.fmax = fmax; E.copysign = copysign
  E.f32_abs = function(x) return f32round(abs(x)) end
  E.f32_neg = function(x) return f32round(-x) end
  E.f32_ceil = function(x) return f32round(ceil(x)) end
  E.f32_floor = function(x) return f32round(floor(x)) end
  E.f32_trunc = function(x) return f32round(ftrunc(x)) end
  E.f32_nearest = function(x) return f32round(fnearest(x)) end
  E.f32_sqrt = function(x) return f32round(sqrt(x)) end
  E.f32_add = function(a, b) return f32round(a + b) end
  E.f32_sub = function(a, b) return f32round(a - b) end
  E.f32_mul = function(a, b) return f32round(a * b) end
  E.f32_div = function(a, b) return f32round(a / b) end
  E.f32_min = function(a, b) return f32round(fmin(a, b)) end
  E.f32_max = function(a, b) return f32round(fmax(a, b)) end
  E.f32_copysign = function(a, b) return f32round(copysign(a, b)) end
  E.f64_min = fmin; E.f64_max = fmax; E.f64_copysign = copysign
  E.feq = function(a, b) return b01(a == b) end
  E.fne = function(a, b) return b01(a ~= b) end
  E.flt = function(a, b) return b01(a < b) end
  E.fgt = function(a, b) return b01(a > b) end
  E.fle = function(a, b) return b01(a <= b) end
  E.fge = function(a, b) return b01(a >= b) end

  -- ===== memory (closes over inst.memory) =====
  if inst then
    local mem = inst.memory
    local function bounds(a, sz) if a + sz > mem.pages * 65536 then error("wasm trap: out of bounds memory access") end end
    E.i32_load = function(a) bounds(a, 4); return (sunpack("<I4", mem:loadstr(a, 4))) end
    E.i32_load8_u = function(a) bounds(a, 1); return mem:get8(a) end
    E.i32_load8_s = function(a) bounds(a, 1); local x = mem:get8(a); return to_u32(x >= 128 and x - 256 or x) end
    E.i32_load16_u = function(a) bounds(a, 2); return (sunpack("<I2", mem:loadstr(a, 2))) end
    E.i32_load16_s = function(a) bounds(a, 2); return to_u32((sunpack("<i2", mem:loadstr(a, 2)))) end
    E.i32_store = function(a, v) bounds(a, 4); mem:storestr(a, spack("<I4", v)) end
    E.i32_store8 = function(a, v) bounds(a, 1); mem:set8(a, v % 256) end
    E.i32_store16 = function(a, v) bounds(a, 2); mem:storestr(a, spack("<I2", v % 65536)) end
    E.i64_load = function(a) bounds(a, 8); return I.from_bytes8(mem:loadstr(a, 8)) end
    E.i64_load8_u = function(a) bounds(a, 1); return I.from_u32(mem:get8(a)) end
    E.i64_load8_s = function(a) bounds(a, 1); local x = mem:get8(a); return I.from_double_s(x >= 128 and x - 256 or x) end
    E.i64_load16_u = function(a) bounds(a, 2); return I.from_u32((sunpack("<I2", mem:loadstr(a, 2)))) end
    E.i64_load16_s = function(a) bounds(a, 2); return I.from_double_s((sunpack("<i2", mem:loadstr(a, 2)))) end
    E.i64_load32_u = function(a) bounds(a, 4); return I.from_u32((sunpack("<I4", mem:loadstr(a, 4)))) end
    E.i64_load32_s = function(a) bounds(a, 4); return I.from_s32(to_s32((sunpack("<I4", mem:loadstr(a, 4))))) end
    E.i64_store = function(a, v) bounds(a, 8); mem:storestr(a, I.to_bytes(v)) end
    E.i64_store8 = function(a, v) bounds(a, 1); mem:set8(a, v.l % 256) end
    E.i64_store16 = function(a, v) bounds(a, 2); mem:storestr(a, spack("<I2", v.l % 65536)) end
    E.i64_store32 = function(a, v) bounds(a, 4); mem:storestr(a, spack("<I4", v.l)) end
    E.f32_load = function(a) bounds(a, 4); return (sunpack("<f", mem:loadstr(a, 4))) end
    E.f32_store = function(a, v) bounds(a, 4); mem:storestr(a, spack("<f", v)) end
    E.f64_load = function(a) bounds(a, 8); return (sunpack("<d", mem:loadstr(a, 8))) end
    E.f64_store = function(a, v) bounds(a, 8); mem:storestr(a, spack("<d", v)) end
    E.mem_size = function() return mem:size() end
    E.mem_grow = function(d) return to_u32(mem:grow(d)) end
    E.mem_fill = function(d, val, n) if d + n > mem.pages * 65536 then error("wasm trap: out of bounds memory access") end mem:fill(d, val, n) end
    E.mem_copy = function(d, s, n) local lim = mem.pages * 65536; if d + n > lim or s + n > lim then error("wasm trap: out of bounds memory access") end mem:copy(d, s, n) end

    E.funcs = inst.funcs
    E.globals = inst.globals
    E.tables = inst.tables
  end

  E.ZERO64 = I.ZERO
  E.__unreachable = function() error("wasm trap: unreachable") end

  -- Cooperative yield for CC's watchdog: compiled loop back-edges call __tick;
  -- every Nth call it yields to the event loop (queueEvent/pullEvent resumes in
  -- the same tick, just resetting the "too long without yielding" timer).
  if type(os) == "table" and os.queueEvent and os.pullEvent then
    E.__yield = function() os.queueEvent("wasmcraft"); os.pullEvent("wasmcraft") end
  end
  local ticks = 0
  E.__tick = function()
    ticks = ticks + 1
    if ticks >= 100000 then ticks = 0; if E.__yield then E.__yield() end end
  end
  return E
end

return M
