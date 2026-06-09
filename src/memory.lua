-- Linear memory. Bytes are held in a plain Lua table keyed by address (0-based),
-- defaulting to 0. Simple and correct; a word-packed variant can replace this if
-- a target module makes per-byte storage a bottleneck. Typed access is done by
-- the interpreter via loadstr/storestr + string.pack/unpack.
local Memory = {}
Memory.__index = Memory

local PAGE = 65536
Memory.PAGE = PAGE

local sbyte, schar = string.byte, string.char
local unpk = table.unpack or unpack

function Memory.new(minPages, maxPages)
  return setmetatable({ b = {}, pages = minPages or 0, max = maxPages }, Memory)
end

function Memory:size() return self.pages end
function Memory:bytelen() return self.pages * PAGE end

function Memory:grow(delta)
  local old = self.pages
  local np = old + delta
  if np > 65536 then return -1 end
  if self.max and np > self.max then return -1 end
  self.pages = np
  return old
end

function Memory:get8(a) return self.b[a] or 0 end
function Memory:set8(a, v) self.b[a] = v % 256 end

-- Return `n` bytes starting at `a` as a Lua string (for reinterpretation).
function Memory:loadstr(a, n)
  local b, t = self.b, {}
  for i = 1, n do t[i] = b[a + i - 1] or 0 end
  return schar(unpk(t))
end

-- Write the bytes of string `s` starting at address `a`.
function Memory:storestr(a, s)
  local b = self.b
  for i = 1, #s do b[a + i - 1] = sbyte(s, i) end
end

-- bulk memory: fill `n` bytes at `d` with byte `val`
function Memory:fill(d, val, n)
  local b = self.b
  val = val % 256
  for i = 0, n - 1 do b[d + i] = val end
end

-- bulk memory: copy `n` bytes from `s` to `d` (memmove semantics, overlap-safe)
function Memory:copy(d, s, n)
  local b = self.b
  if d <= s then
    for i = 0, n - 1 do b[d + i] = b[s + i] or 0 end
  else
    for i = n - 1, 0, -1 do b[d + i] = b[s + i] or 0 end
  end
end

return Memory
