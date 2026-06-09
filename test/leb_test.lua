-- RED: LEB128 decode + primitive byte reads. The backbone of the binary decoder.
package.path = "src/?.lua;test/?.lua;" .. package.path
local T = require("harness")
local leb = require("leb")
T.start("leb")

local function R(bytes) return leb.new(bytes) end

-- Unsigned LEB128 (canonical examples)
T.eq(R("\x00"):u_leb(), 0, "uleb 0")
T.eq(R("\x7F"):u_leb(), 127, "uleb 127")
T.eq(R("\x80\x01"):u_leb(), 128, "uleb 128")
T.eq(R("\xE5\x8E\x26"):u_leb(), 624485, "uleb 624485")
T.eq(R("\xFF\xFF\xFF\xFF\x0F"):u_leb(), 4294967295, "uleb 0xFFFFFFFF")

-- Signed LEB128 (canonical examples)
T.eq(R("\x00"):s_leb(), 0, "sleb 0")
T.eq(R("\x7F"):s_leb(), -1, "sleb -1")
T.eq(R("\x3F"):s_leb(), 63, "sleb 63")
T.eq(R("\x40"):s_leb(), -64, "sleb -64")
T.eq(R("\xC0\xBB\x78"):s_leb(), -123456, "sleb -123456")
T.eq(R("\xE5\x8E\x26"):s_leb(), 624485, "sleb 624485")

-- Position advances correctly across a sequence
local r = leb.new("\x80\x01\x7F\x05")
T.eq(r:u_leb(), 128, "seq uleb 128")
T.eq(r:s_leb(), -1, "seq sleb -1")
T.eq(r:byte(), 5, "seq byte 5")
T.ok(r:eof(), "eof after consuming all")

-- Fixed-width reads
local r2 = leb.new("\x01\x02\x03\x04ABCD")
T.eq(r2:u32(), 0x04030201, "u32 little-endian")
T.eqstr(r2:bytes(4), "ABCD", "raw bytes")

-- Float decode via string.unpack path
local r3 = leb.new(string.pack("<f", 3.5) .. string.pack("<d", 2.5))
T.eq(r3:f32(), 3.5, "f32 decode")
T.eq(r3:f64(), 2.5, "f64 decode")

T.done()
