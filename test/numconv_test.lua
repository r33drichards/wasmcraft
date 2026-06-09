-- i64 ops, float ops, and conversions end-to-end through the interpreter.
-- Oracles from wasmtime.
package.path = "src/?.lua;test/?.lua;" .. package.path
local T = require("harness")
local wasm = require("wasm")
T.start("numconv")

local function inst(name)
  local f = assert(io.open("wasm/" .. name .. ".wasm", "rb"))
  local b = f:read("*a"); f:close()
  return wasm.instantiate(wasm.load(b), {})
end

-- i64
local i = inst("i64ops")
T.eq(i:call("mul_lo"), 1, "i64 mul low word")
T.eq(i:call("mul_hi"), 2, "i64 mul high word (carry across 32-bit boundary)")
T.eq(i:call("div"), -1123222089, "i64 div_s low32")
T.eq(i:call("rem"), -1, "i64 rem_s")
T.eq(i:call("shift"), 8, "i64 shr_u across words")
T.eq(i:call("clz"), 31, "i64 clz of 2^32")
T.eq(i:call("eqz0"), 1, "i64 eqz 0")
T.eq(i:call("lts"), 1, "i64 lt_s -5<3")
T.eq(i:call("ext", -1), -1, "i64 extend_i32_s high word = all ones")
T.eq(i:call("ext", 5), 0, "i64 extend_i32_s high word of positive")

-- float
local f = inst("floatops")
T.eq(f:call("add", 0.5, 0.25), 0.75, "f64 add")
T.eq(f:call("div", 1, 3), 0.3333333333333333, "f64 div")
T.eq(f:call("sqrt", 2), 1.4142135623730951, "f64 sqrt")
T.eq(f:call("trunc", 3.7), 3, "f64 trunc pos")
T.eq(f:call("trunc", -3.7), -3, "f64 trunc neg")
T.eq(f:call("nearest", 2.5), 2, "f64 nearest half-to-even down")
T.eq(f:call("nearest", 3.5), 4, "f64 nearest half-to-even up")
T.eq(f:call("floor", -1.5), -2, "f64 floor")
T.eq(f:call("min", 1, 2), 1, "f64 min")
T.eq(f:call("copysign", 3, -1), -3, "f64 copysign")
T.eq(f:call("i2f", -5), -5, "convert i32_s")
T.eq(f:call("u2f", -1), 4294967295, "convert i32_u")
T.eq(f:call("f2i", 3.9), 3, "trunc_f64_s")
T.eq(f:call("f2u", 4000000000.5), -294967296, "trunc_f64_u wraps to s32 view")
T.approx(f:call("demote", 3.14159265358979), 3.1415927, 1e-6, "f32.demote_f64")
T.eq(f:call("reinterp", 0.1), -1717986918, "i64.reinterpret_f64 low word")

T.done()
