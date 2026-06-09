-- Minimal test harness that runs identically on Cobalt (Lua 5.1) and lua5.4.
-- Each test file requires this, calls T.eq/T.ok/..., and ends with T.done().
-- Success prints "ALL_PASS"; any failure prints "FAILED" so callers can grep.
local T = { total = 0, fails = 0, name = "?" }

local function fmt(v)
  if type(v) == "table" and v.h and v.l then
    return string.format("i64(0x%08X%08X)", v.h, v.l)
  end
  return tostring(v)
end

function T.start(name) T.name = name end

function T.eq(got, want, msg)
  T.total = T.total + 1
  if got ~= want then
    T.fails = T.fails + 1
    print(string.format("  FAIL [%s]: %s\n    expected %s\n    got      %s",
      T.name, msg or "", fmt(want), fmt(got)))
  end
end

function T.ok(cond, msg)
  T.total = T.total + 1
  if not cond then
    T.fails = T.fails + 1
    print(string.format("  FAIL [%s]: %s", T.name, msg or "(condition false)"))
  end
end

-- Deep-ish equality for byte strings / numbers
function T.eqstr(got, want, msg)
  T.total = T.total + 1
  if got ~= want then
    T.fails = T.fails + 1
    local function hex(s)
      local o = {}
      for i = 1, #s do o[i] = string.format("%02X", string.byte(s, i)) end
      return table.concat(o, " ")
    end
    print(string.format("  FAIL [%s]: %s\n    expected %s\n    got      %s",
      T.name, msg or "", hex(want), hex(got)))
  end
end

function T.approx(got, want, eps, msg)
  T.total = T.total + 1
  eps = eps or 1e-9
  if type(got) ~= "number" or math.abs(got - want) > eps then
    T.fails = T.fails + 1
    print(string.format("  FAIL [%s]: %s\n    expected ~%s\n    got      %s",
      T.name, msg or "", tostring(want), tostring(got)))
  end
end

function T.done()
  print(string.format("%d/%d assertions passed", T.total - T.fails, T.total))
  if T.fails > 0 then print("FAILED") else print("ALL_PASS") end
end

return T
