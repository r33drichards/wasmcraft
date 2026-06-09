-- Byte cursor + LEB128/primitive readers over a binary string.
-- Pure arithmetic (no bit32) so it runs on both Cobalt (5.1) and lua5.4.
-- 1-indexed position, matching Lua string semantics.
local Reader = {}
Reader.__index = Reader

local sbyte, ssub = string.byte, string.sub
local sunpack = string.unpack

function Reader.new(data, pos)
  return setmetatable({ data = data, pos = pos or 1 }, Reader)
end

function Reader:eof()
  return self.pos > #self.data
end

function Reader:byte()
  local b = sbyte(self.data, self.pos)
  self.pos = self.pos + 1
  return b
end

function Reader:bytes(n)
  local s = ssub(self.data, self.pos, self.pos + n - 1)
  self.pos = self.pos + n
  return s
end

-- Unsigned LEB128. Exact for values up to 2^53 (covers all u32 + counts).
function Reader:u_leb()
  local result, shift = 0, 1
  while true do
    local b = sbyte(self.data, self.pos)
    self.pos = self.pos + 1
    result = result + (b % 128) * shift
    if b < 128 then return result end
    shift = shift * 128
  end
end

-- Signed LEB128. Exact for values in the s53 range (covers all s32).
function Reader:s_leb()
  local result, shift = 0, 1
  local b
  while true do
    b = sbyte(self.data, self.pos)
    self.pos = self.pos + 1
    result = result + (b % 128) * shift
    shift = shift * 128
    if b < 128 then break end
  end
  -- sign-extend: if the sign bit (0x40) of the final byte is set, subtract 2^bits.
  if (b % 128) >= 64 then result = result - shift end
  return result
end

-- Fixed-width little-endian unsigned 32-bit.
function Reader:u32()
  local v = sunpack("<I4", self.data, self.pos)
  self.pos = self.pos + 4
  return v
end

function Reader:f32()
  local v = sunpack("<f", self.data, self.pos)
  self.pos = self.pos + 4
  return v
end

function Reader:f64()
  local v = sunpack("<d", self.data, self.pos)
  self.pos = self.pos + 8
  return v
end

return Reader
