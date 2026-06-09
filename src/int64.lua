-- 64-bit integer emulation for a Lua VM whose numbers are doubles.
-- A value is a table { h = high32, l = low32 }, both unsigned 0..2^32-1.
-- All ops compute the low 64 bits (wasm i64 wraps mod 2^64). Signedness is a
-- view, applied per-operation. Built on the bit32-compatible `bit` shim.
local bit = require("bit")
local floor = math.floor
local POW32 = 2 ^ 32
local POW16 = 65536
local spack, sunpack = string.pack, string.unpack

local I = {}
I.__index = I

local function mk(h, l) return setmetatable({ h = h, l = l }, I) end
I.mk = mk
I.ZERO = mk(0, 0)
I.ONE = mk(0, 1)

local function is(v) return type(v) == "table" and v.h ~= nil and v.l ~= nil end
I.is = is

-- ---- construction --------------------------------------------------------
function I.from_u32(x) return mk(0, x % POW32) end
function I.from_s32(x)
  x = x % POW32; if x < 0 then x = x + POW32 end
  return mk(x >= 0x80000000 and 0xFFFFFFFF or 0, x)
end

-- A signed-double whose integer part fits roughly in i64. Precision limited to
-- 53 bits, matching the host float; documented limitation for huge magnitudes.
function I.from_double_s(x)
  local neg = x < 0
  if neg then x = -x end
  x = floor(x)
  local h = floor(x / POW32) % POW32
  local l = x % POW32
  local v = mk(h, l)
  if neg then return I.neg(v) end
  return v
end
function I.from_double_u(x)
  x = floor(x)
  return mk(floor(x / POW32) % POW32, x % POW32)
end

function I.to_double_u(a) return a.h * POW32 + a.l end
function I.to_double_s(a)
  if a.h >= 0x80000000 then return -(I.to_double_u(I.neg(a))) end
  return a.h * POW32 + a.l
end

-- ---- bitwise -------------------------------------------------------------
function I.band(a, b) return mk(bit.band(a.h, b.h), bit.band(a.l, b.l)) end
function I.bor(a, b) return mk(bit.bor(a.h, b.h), bit.bor(a.l, b.l)) end
function I.bxor(a, b) return mk(bit.bxor(a.h, b.h), bit.bxor(a.l, b.l)) end
function I.bnot(a) return mk(bit.bnot(a.h), bit.bnot(a.l)) end

-- ---- arithmetic ----------------------------------------------------------
function I.add(a, b)
  local l = a.l + b.l
  local carry = 0
  if l >= POW32 then l = l - POW32; carry = 1 end
  local h = (a.h + b.h + carry) % POW32
  return mk(h, l)
end

function I.neg(a) return I.add(I.bnot(a), I.ONE) end

function I.sub(a, b)
  local l = a.l - b.l
  local borrow = 0
  if l < 0 then l = l + POW32; borrow = 1 end
  local h = a.h - b.h - borrow
  if h < 0 then h = h + POW32 end
  return mk(h, l)
end

function I.mul(a, b)
  local a0 = a.l % POW16; local a1 = floor(a.l / POW16)
  local a2 = a.h % POW16; local a3 = floor(a.h / POW16)
  local b0 = b.l % POW16; local b1 = floor(b.l / POW16)
  local b2 = b.h % POW16; local b3 = floor(b.h / POW16)
  local r0 = a0 * b0
  local r1 = a0 * b1 + a1 * b0
  local r2 = a0 * b2 + a1 * b1 + a2 * b0
  local r3 = a0 * b3 + a1 * b2 + a2 * b1 + a3 * b0
  local carry, o0, o1, o2, o3
  o0 = r0 % POW16; carry = floor(r0 / POW16)
  local v1 = r1 + carry; o1 = v1 % POW16; carry = floor(v1 / POW16)
  local v2 = r2 + carry; o2 = v2 % POW16; carry = floor(v2 / POW16)
  local v3 = r3 + carry; o3 = v3 % POW16
  return mk(o2 + o3 * POW16, o0 + o1 * POW16)
end

-- ---- comparisons ---------------------------------------------------------
function I.eq(a, b) return a.h == b.h and a.l == b.l end
function I.eqz(a) return a.h == 0 and a.l == 0 end
function I.lt_u(a, b) if a.h ~= b.h then return a.h < b.h end return a.l < b.l end
function I.lt_s(a, b)
  local sa = a.h >= 0x80000000
  local sb = b.h >= 0x80000000
  if sa ~= sb then return sa end -- a negative, b non-negative => a < b
  if a.h ~= b.h then return a.h < b.h end
  return a.l < b.l
end

-- ---- shifts --------------------------------------------------------------
function I.shl(a, n)
  n = n % 64
  if n == 0 then return mk(a.h, a.l) end
  if n < 32 then
    return mk(bit.bor(bit.lshift(a.h, n), bit.rshift(a.l, 32 - n)), bit.lshift(a.l, n))
  else
    return mk(bit.lshift(a.l, n - 32), 0)
  end
end
function I.shr_u(a, n)
  n = n % 64
  if n == 0 then return mk(a.h, a.l) end
  if n < 32 then
    return mk(bit.rshift(a.h, n), bit.bor(bit.rshift(a.l, n), bit.lshift(a.h, 32 - n)))
  else
    return mk(0, bit.rshift(a.h, n - 32))
  end
end
function I.shr_s(a, n)
  n = n % 64
  if n == 0 then return mk(a.h, a.l) end
  local fill = a.h >= 0x80000000 and 0xFFFFFFFF or 0
  if n < 32 then
    return mk(bit.arshift(a.h, n), bit.bor(bit.rshift(a.l, n), bit.lshift(a.h, 32 - n)))
  else
    return mk(fill, bit.arshift(a.h, n - 32))
  end
end
function I.rotl(a, n)
  n = n % 64
  if n == 0 then return mk(a.h, a.l) end
  return I.bor(I.shl(a, n), I.shr_u(a, 64 - n))
end
function I.rotr(a, n)
  n = n % 64
  if n == 0 then return mk(a.h, a.l) end
  return I.bor(I.shr_u(a, n), I.shl(a, 64 - n))
end

-- ---- bit counting --------------------------------------------------------
local function clz32(x) if x == 0 then return 32 end local n = 0; while x < 0x80000000 do x = x * 2; n = n + 1 end return n end
local function ctz32(x) if x == 0 then return 32 end local n = 0; while x % 2 == 0 do x = x / 2; n = n + 1 end return n end
local function popcnt32(x) local n = 0; while x > 0 do n = n + (x % 2); x = floor(x / 2) end return n end
function I.clz(a) if a.h ~= 0 then return clz32(a.h) end return 32 + clz32(a.l) end
function I.ctz(a) if a.l ~= 0 then return ctz32(a.l) end return 32 + ctz32(a.h) end
function I.popcnt(a) return popcnt32(a.h) + popcnt32(a.l) end

-- ---- division (unsigned long division, then sign fixups) -----------------
local function bit_at(a, i)
  if i < 32 then return floor(a.l / 2 ^ i) % 2 else return floor(a.h / 2 ^ (i - 32)) % 2 end
end
function I.divmod_u(n, d)
  if I.eqz(d) then error("wasm trap: integer divide by zero") end
  local q = mk(0, 0)
  local r = mk(0, 0)
  for i = 63, 0, -1 do
    r = I.shl(r, 1)
    if bit_at(n, i) == 1 then r.l = r.l + 1 end
    if not I.lt_u(r, d) then
      r = I.sub(r, d)
      if i < 32 then q.l = q.l + 2 ^ i else q.h = q.h + 2 ^ (i - 32) end
    end
  end
  return q, r
end
function I.div_u(a, b) local q = I.divmod_u(a, b); return q end
function I.rem_u(a, b) local _, r = I.divmod_u(a, b); return r end

local MIN64 = mk(0x80000000, 0)
function I.div_s(a, b)
  if I.eqz(b) then error("wasm trap: integer divide by zero") end
  if I.eq(a, MIN64) and I.eq(b, mk(0xFFFFFFFF, 0xFFFFFFFF)) then error("wasm trap: integer overflow") end
  local na = a.h >= 0x80000000; local nb = b.h >= 0x80000000
  local ua = na and I.neg(a) or a
  local ub = nb and I.neg(b) or b
  local q = I.divmod_u(ua, ub)
  if na ~= nb then return I.neg(q) end
  return q
end
function I.rem_s(a, b)
  if I.eqz(b) then error("wasm trap: integer divide by zero") end
  local na = a.h >= 0x80000000; local nb = b.h >= 0x80000000
  local ua = na and I.neg(a) or a
  local ub = nb and I.neg(b) or b
  local _, r = I.divmod_u(ua, ub)
  if na then return I.neg(r) end
  return r
end

-- ---- memory bytes (little-endian) ----------------------------------------
function I.to_bytes(a) return spack("<I4", a.l) .. spack("<I4", a.h) end
function I.from_bytes8(s) return mk((sunpack("<I4", s, 5)), (sunpack("<I4", s, 1))) end

-- ---- LEB128 (signed, up to 64 bits) for i64.const ------------------------
function I.read_sleb(r)
  local l, h = 0, 0
  local pos = 0 -- bit position
  local b
  while true do
    b = r:byte()
    local low7 = b % 128
    if pos < 32 then
      if pos + 7 <= 32 then
        l = l + low7 * 2 ^ pos
      else
        local lowbits = 32 - pos
        l = l + (low7 % 2 ^ lowbits) * 2 ^ pos
        h = h + floor(low7 / 2 ^ lowbits)
      end
    else
      h = h + low7 * 2 ^ (pos - 32)
    end
    pos = pos + 7
    if b < 128 then break end
  end
  l = l % POW32; h = h % POW32
  -- sign extend if the value is negative and bits remain
  if (b % 128) >= 64 then
    if pos < 32 then
      l = l + (POW32 - 2 ^ pos)
      h = 0xFFFFFFFF
    elseif pos < 64 then
      h = h + (POW32 - 2 ^ (pos - 32))
    end
  end
  return mk(h, l)
end

function I.tostring(a) return string.format("0x%08x%08x", a.h, a.l) end

return I
