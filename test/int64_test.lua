-- int64 two-word emulation, checked against hand-computed values.
package.path = "src/?.lua;test/?.lua;" .. package.path
local T = require("harness")
local I = require("int64")
local leb = require("leb")
T.start("int64")

local function H(a) return string.format("%08x%08x", a.h, a.l) end
local function eqi(got, h, l, msg) T.eq(H(got), string.format("%08x%08x", h, l), msg) end

-- construction
eqi(I.from_u32(0xFFFFFFFF), 0, 0xFFFFFFFF, "from_u32")
eqi(I.from_s32(-1), 0xFFFFFFFF, 0xFFFFFFFF, "from_s32(-1)")
eqi(I.from_s32(-2), 0xFFFFFFFF, 0xFFFFFFFE, "from_s32(-2)")

-- add / sub / carry / borrow
eqi(I.add(I.from_u32(0xFFFFFFFF), I.ONE), 1, 0, "add carry")
eqi(I.sub(I.mk(1, 0), I.ONE), 0, 0xFFFFFFFF, "sub borrow")
eqi(I.neg(I.ONE), 0xFFFFFFFF, 0xFFFFFFFF, "neg(1) = -1")

-- mul
eqi(I.mul(I.from_u32(0xFFFFFFFF), I.from_u32(0xFFFFFFFF)), 0xFFFFFFFE, 0x00000001, "0xFFFFFFFF^2")
eqi(I.mul(I.mk(0x12345678, 0x9ABCDEF0), I.from_u32(2)), 0x2468ACF1, 0x3579BDE0, "mul by 2 with carry")

-- shifts
eqi(I.shl(I.ONE, 32), 1, 0, "shl 32")
eqi(I.shl(I.ONE, 63), 0x80000000, 0, "shl 63")
eqi(I.shr_u(I.mk(0x80000000, 0), 63), 0, 1, "shr_u 63")
eqi(I.shr_s(I.mk(0x80000000, 0), 63), 0xFFFFFFFF, 0xFFFFFFFF, "shr_s sign fill")
eqi(I.rotl(I.ONE, 64), 0, 1, "rotl 64 == identity")
eqi(I.rotr(I.ONE, 1), 0x80000000, 0, "rotr 1")

-- comparisons
T.ok(I.lt_u(I.from_u32(5), I.from_u32(9)), "lt_u")
T.ok(I.lt_s(I.from_s32(-1), I.from_s32(1)), "lt_s neg<pos")
T.ok(not I.lt_s(I.from_s32(1), I.from_s32(-1)), "lt_s pos<neg false")
T.ok(I.eqz(I.ZERO), "eqz")

-- division
do
  local q, r = I.divmod_u(I.from_u32(100), I.from_u32(7))
  eqi(q, 0, 14, "100/7 q"); eqi(r, 0, 2, "100%7 r")
end
eqi(I.div_s(I.from_s32(-100), I.from_s32(7)), 0xFFFFFFFF, 0xFFFFFFF2, "-100/7 = -14")
eqi(I.rem_s(I.from_s32(-100), I.from_s32(7)), 0xFFFFFFFF, 0xFFFFFFFE, "-100%7 = -2")

-- clz/ctz/popcnt
T.eq(I.clz(I.ONE), 63, "clz 1")
T.eq(I.ctz(I.mk(1, 0)), 32, "ctz 2^32")
T.eq(I.popcnt(I.mk(0xFFFFFFFF, 0xFFFFFFFF)), 64, "popcnt all ones")

-- bytes roundtrip
do
  local v = I.mk(0xDEADBEEF, 0xCAFEBABE)
  local s = I.to_bytes(v)
  T.eq(#s, 8, "to_bytes len")
  eqi(I.from_bytes8(s), 0xDEADBEEF, 0xCAFEBABE, "bytes roundtrip")
end

-- signed LEB for i64.const
eqi(I.read_sleb(leb.new("\x7F")), 0xFFFFFFFF, 0xFFFFFFFF, "sleb -1")
eqi(I.read_sleb(leb.new("\x00")), 0, 0, "sleb 0")
-- 0x80 0x80 0x80 0x80 0x80 0x80 0x80 0x80 0x80 0x01 == 1<<63
eqi(I.read_sleb(leb.new("\x80\x80\x80\x80\x80\x80\x80\x80\x80\x01")), 0x80000000, 0, "sleb 1<<63")
-- 624485 fits low
eqi(I.read_sleb(leb.new("\xE5\x8E\x26")), 0, 624485, "sleb 624485")

T.done()
