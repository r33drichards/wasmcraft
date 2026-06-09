-- Probe Cobalt's number model and the two libraries the WASM interpreter depends on.
print("lua version: " .. tostring(_VERSION))

-- 1) Are there integer/float subtypes (5.3) or just doubles (5.1/5.2)?
print("math.type: " .. tostring(math.type))            -- nil on 5.1/5.2
print("3/2 = " .. tostring(3/2))                        -- 1.5 everywhere
print("5 % 3 = " .. tostring(5 % 3))

-- 2) Exactness of 32-bit and beyond (double has 53-bit mantissa)
print("2^32 = " .. string.format("%.0f", 2^32))
print("2^53 exact? " .. tostring(2^53 == 2^53 + 1 and "NO" or "YES"))

-- 3) bit32 present and 32-bit semantics
print("bit32 = " .. tostring(bit32))
if bit32 then
  print("band(0xF0F0F0F0,0x0FF00FF0) = " .. string.format("0x%08X", bit32.band(0xF0F0F0F0, 0x0FF00FF0)))
  print("lshift(1,31) = " .. string.format("0x%08X", bit32.lshift(1, 31)))
  print("rshift(0x80000000,31) = " .. tostring(bit32.rshift(0x80000000, 31)))
  print("bxor wraps to u32: " .. string.format("0x%08X", bit32.bxor(0xFFFFFFFF, 0x00000001)))
end

-- 4) string.pack / string.unpack — LEB and IEEE decode backbone
print("string.pack = " .. tostring(string.pack))
if string.pack then
  local le = string.pack("<I4", 0xDEADBEEF)
  print("pack <I4 len = " .. #le)
  local v = string.unpack("<I4", le)
  print("roundtrip <I4 = " .. string.format("0x%08X", v))
  -- IEEE-754 float/double decode
  local f = string.unpack("<f", string.pack("<f", 3.5))
  print("float roundtrip 3.5 = " .. tostring(f))
  local d = string.unpack("<d", string.pack("<d", 3.141592653589793))
  print("double roundtrip pi = " .. tostring(d))
  -- single byte read
  print("byte read = " .. tostring(string.unpack("<B", "\255")))
end

-- 5) Can we get raw bytes / does string indexing work on binary data?
local bin = "\0\1\2\255"
print("#bin = " .. #bin .. ", byte4 = " .. string.byte(bin, 4))

print("PROBE_OK")
