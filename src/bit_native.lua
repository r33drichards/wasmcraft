-- bit32-compatible API built on Lua 5.3+/5.4 native bitwise operators.
-- Only loaded on a VM that lacks bit32 (i.e. lua5.4 dev), never on Cobalt 5.1.
local M = {}
local MASK = 0xFFFFFFFF
local function u(x) return math.floor(x) & MASK end

function M.band(a, b) return u(a) & u(b) end
function M.bor(a, b) return u(a) | u(b) end
function M.bxor(a, b) return u(a) ~ u(b) end
function M.bnot(a) return (~u(a)) & MASK end

function M.lshift(a, n)
  n = n % 4294967296
  if n >= 32 then return 0 end
  return (u(a) << n) & MASK
end

function M.rshift(a, n)
  n = n % 4294967296
  if n >= 32 then return 0 end
  return u(a) >> n -- logical: u(a) is a non-negative 32-bit value
end

function M.arshift(a, n)
  n = n % 4294967296
  local x = u(a)
  if n >= 32 then return (x & 0x80000000) ~= 0 and MASK or 0 end
  if (x & 0x80000000) ~= 0 then
    -- sign-extend by filling high bits
    return ((x >> n) | ((MASK << (32 - n)) & MASK)) & MASK
  end
  return x >> n
end

function M.lrotate(a, n)
  n = n % 32
  local x = u(a)
  return ((x << n) | (x >> (32 - n))) & MASK
end

function M.rrotate(a, n)
  n = n % 32
  local x = u(a)
  return ((x >> n) | (x << (32 - n))) & MASK
end

return M
