-- Runtime support for compiled wasm functions. Compiled bytecode calls these
-- helpers (via an ENV upvalue table) for ops that don't map to a single Lua
-- bytecode instruction: signed compares, mul/div/shift/bitwise, bit counting.
-- Semantics mirror src/interp.lua exactly. (i64/float/memory added in later stages.)
local bit = require("bit")
local floor = math.floor
local POW32, POW31 = 2 ^ 32, 2 ^ 31

local function to_u32(x) x = x % POW32; if x < 0 then x = x + POW32 end; return x end
local function to_s32(x) x = to_u32(x); if x >= POW31 then x = x - POW32 end; return x end

local function clz32(x) if x == 0 then return 32 end local n = 0; while x < 0x80000000 do x = x * 2; n = n + 1 end return n end
local function ctz32(x) if x == 0 then return 32 end local n = 0; while x % 2 == 0 do x = x / 2; n = n + 1 end return n end
local function popcnt32(x) local n = 0; while x > 0 do n = n + (x % 2); x = floor(x / 2) end return n end

local M = {}

-- Build the ENV table of helpers (instance-independent for the i32 core).
function M.make()
  local E = {}

  E.mul = function(a, b)
    local al = a % 65536; local ah = floor(a / 65536)
    local bl = b % 65536; local bh = floor(b / 65536)
    local cross = (ah * bl + al * bh) % 65536
    return (al * bl + cross * 65536) % POW32
  end
  E.div_s = function(a, b)
    b = to_s32(b); a = to_s32(a)
    if b == 0 then error("wasm trap: integer divide by zero") end
    if a == -2147483648 and b == -1 then error("wasm trap: integer overflow") end
    local q = a / b; q = q >= 0 and floor(q) or -floor(-q); return to_u32(q)
  end
  E.div_u = function(a, b) if b == 0 then error("wasm trap: integer divide by zero") end return floor(a / b) end
  E.rem_s = function(a, b)
    b = to_s32(b); a = to_s32(a)
    if b == 0 then error("wasm trap: integer divide by zero") end
    local q = a / b; q = q >= 0 and floor(q) or -floor(-q); return to_u32(a - q * b)
  end
  E.rem_u = function(a, b) if b == 0 then error("wasm trap: integer divide by zero") end return a - floor(a / b) * b end

  E.band = function(a, b) return bit.band(a, b) end
  E.bor = function(a, b) return bit.bor(a, b) end
  E.bxor = function(a, b) return bit.bxor(a, b) end
  E.shl = function(a, b) return bit.lshift(a, b % 32) end
  E.shr_s = function(a, b) return bit.arshift(a, b % 32) end
  E.shr_u = function(a, b) return bit.rshift(a, b % 32) end
  E.rotl = function(a, b) return bit.lrotate(a, b % 32) end
  E.rotr = function(a, b) return bit.rrotate(a, b % 32) end

  E.clz = function(a) return clz32(a) end
  E.ctz = function(a) return ctz32(a) end
  E.popcnt = function(a) return popcnt32(a) end

  E.__unreachable = function() error("wasm trap: unreachable") end

  E.eqz = function(a) return a == 0 and 1 or 0 end
  E.eq = function(a, b) return a == b and 1 or 0 end
  E.ne = function(a, b) return a ~= b and 1 or 0 end
  E.lt_u = function(a, b) return a < b and 1 or 0 end
  E.gt_u = function(a, b) return a > b and 1 or 0 end
  E.le_u = function(a, b) return a <= b and 1 or 0 end
  E.ge_u = function(a, b) return a >= b and 1 or 0 end
  E.lt_s = function(a, b) return to_s32(a) < to_s32(b) and 1 or 0 end
  E.gt_s = function(a, b) return to_s32(a) > to_s32(b) and 1 or 0 end
  E.le_s = function(a, b) return to_s32(a) <= to_s32(b) and 1 or 0 end
  E.ge_s = function(a, b) return to_s32(a) >= to_s32(b) and 1 or 0 end

  return E
end

M.to_u32, M.to_s32 = to_u32, to_s32
return M
