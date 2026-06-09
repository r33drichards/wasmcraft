-- Differential test: every fixture run through BOTH the interpreter and the
-- wasm->bytecode compiler must agree. COBALT ONLY (5.1 bytecode).
package.path = "src/?.lua;test/?.lua;" .. package.path
local T = require("harness")
local wasm = require("wasm")
local decoder = require("decoder")
local compiler = require("compiler")
T.start("compiler")

local function readwasm(name)
  local f = assert(io.open("wasm/" .. name .. ".wasm", "rb")); local b = f:read("*a"); f:close(); return b
end

local function approx(a, b)
  if type(a) == "number" and type(b) == "number" then
    if a ~= a and b ~= b then return true end -- NaN
    return math.abs(a - b) <= 1e-9 * math.max(1, math.abs(a))
  end
  return a == b
end

local function diff(name, calls)
  local b = readwasm(name)
  local ii = wasm.instantiate(wasm.load(b), {})
  local ok, ci = pcall(compiler.instantiate, decoder.load(b), {})
  if not ok then T.ok(false, name .. " compiles: " .. tostring(ci)); return end
  for _, c in ipairs(calls) do
    local label = name .. ":" .. table.concat(c, ",")
    local r1 = { ii:call((table.unpack or unpack)(c)) }
    local r2 = { ci:call((table.unpack or unpack)(c)) }
    local same = #r1 == #r2
    for k = 1, #r1 do if not approx(r1[k], r2[k]) then same = false end end
    T.ok(same, label .. "  interp=" .. tostring(r1[1]) .. " compiled=" .. tostring(r2[1]))
  end
end

diff("add", { { "add", 7, 35 }, { "add", -1, 1 }, { "add", 2147483647, 1 }, { "add", 100, -50 } })
diff("fib", { { "fib", 10 }, { "fib", 20 }, { "fib", 0 }, { "fib", 1 } })
diff("brtable", { { "sw", 0 }, { "sw", 1 }, { "sw", 2 }, { "sw", 3 }, { "sw", 7 } })
diff("call", { { "sumsq", 3, 4 } })
diff("indirect", { { "op", 0, 8, 5 }, { "op", 1, 8, 5 } })
diff("mem", { { "sum", 5 }, { "sum", 10 }, { "bytes" } })
diff("i32ops", { { "f", 5, 300 }, { "divrem", 17, 5 }, { "divrem", -17, 5 }, { "cmp", 3, 5 }, { "cmp", 0, 5 }, { "bits", 16 }, { "bits", 255 } })
diff("i64ops", { { "mul_lo" }, { "mul_hi" }, { "div" }, { "rem" }, { "shift" }, { "clz" }, { "eqz0" }, { "lts" }, { "ext", -1 }, { "ext", 5 } })
diff("floatops", { { "add", 0.5, 0.25 }, { "div", 1, 3 }, { "sqrt", 2 }, { "trunc", 3.7 }, { "nearest", 2.5 },
  { "floor", -1.5 }, { "min", 1, 2 }, { "copysign", 3, -1 }, { "i2f", -5 }, { "u2f", -1 }, { "f2i", 3.9 },
  { "f2u", 4000000000.5 }, { "demote", 3.14159265358979 }, { "reinterp", 0.1 } })

T.done()
