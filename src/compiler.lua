-- wasm -> Lua 5.1 bytecode compiler (Cobalt fast path).
-- Stage 1: i32 arithmetic/compare/bitwise + structured control. Functions using
-- anything not yet supported are rejected by can_compile() so callers fall back
-- to the interpreter. Compiled functions take their wasm params as Lua args and
-- return their wasm results as Lua return values; the runtime ENV is an upvalue.
local luabc = require("luabc")
local OP = luabc.OP
local RK = luabc.RK
local runtime = require("runtime")

local M = {}

-- op -> helper name (binary: 2 i32 args -> i32) / (unary: 1 arg -> i32)
local BIN = {
  ["i32.mul"] = "mul", ["i32.div_s"] = "div_s", ["i32.div_u"] = "div_u",
  ["i32.rem_s"] = "rem_s", ["i32.rem_u"] = "rem_u",
  ["i32.and"] = "band", ["i32.or"] = "bor", ["i32.xor"] = "bxor",
  ["i32.shl"] = "shl", ["i32.shr_s"] = "shr_s", ["i32.shr_u"] = "shr_u",
  ["i32.rotl"] = "rotl", ["i32.rotr"] = "rotr",
  ["i32.eq"] = "eq", ["i32.ne"] = "ne",
  ["i32.lt_s"] = "lt_s", ["i32.lt_u"] = "lt_u", ["i32.gt_s"] = "gt_s", ["i32.gt_u"] = "gt_u",
  ["i32.le_s"] = "le_s", ["i32.le_u"] = "le_u", ["i32.ge_s"] = "ge_s", ["i32.ge_u"] = "ge_u",
}
local UN = { ["i32.clz"] = "clz", ["i32.ctz"] = "ctz", ["i32.popcnt"] = "popcnt", ["i32.eqz"] = "eqz" }
local SIMPLE = {
  ["nop"] = true, ["drop"] = true, ["select"] = true, ["return"] = true, ["unreachable"] = true,
  ["local.get"] = true, ["local.set"] = true, ["local.tee"] = true,
  ["i32.const"] = true, ["i32.add"] = true, ["i32.sub"] = true,
  ["block"] = true, ["loop"] = true, ["if"] = true, ["else"] = true, ["end"] = true,
  ["br"] = true, ["br_if"] = true, ["br_table"] = true,
}

local function empty_bt(bt)
  return bt and bt.params and #bt.params == 0 and #bt.results == 0
end

-- Can this function be compiled by the current stage?
function M.can_compile(mod, fidx)
  local code = mod.codes[fidx]
  if not code then return false end
  for _, ins in ipairs(code.body) do
    local op = ins.op
    if op == "block" or op == "loop" or op == "if" then
      if not empty_bt(ins.bt) then return false end -- only empty block types for now
    elseif not (SIMPLE[op] or BIN[op] or UN[op]) then
      return false
    end
  end
  return true
end

-- Compile one function to a loadable chunk. loadstring(chunk)(ENV) -> Lua fn.
function M.compile_func(mod, fidx)
  local ftype = mod.types[mod.funcTypeIdx[fidx] + 1]
  local code = mod.codes[fidx]
  local nparams = #ftype.params
  local nlocals = nparams + #code.locals
  local renv = nlocals          -- ENV cached here
  local base = nlocals + 1      -- operand stack base
  local nres = #ftype.results

  local fb = luabc.func(nparams, 1) -- 1 upvalue = ENV
  fb:use(base)                      -- reserve through operand base
  local kwrap = fb:knum(4294967296.0)
  local k0 = fb:knum(0.0)

  fb:GETUPVAL(renv, 0)              -- cache ENV
  for r = nparams, nlocals - 1 do fb:LOADK(r, k0) end -- zero declared locals

  local vsp = 0
  local ctrl = {}
  local dead = false

  local function call_helper(name, nargs)
    local argbase = base + vsp - nargs
    local f = base + vsp
    fb:GETTABLE(f, renv, RK(fb:kstr(name)))
    for i = 0, nargs - 1 do fb:MOVE(f + 1 + i, argbase + i) end
    fb:CALL(f, nargs + 1, 2)
    fb:MOVE(argbase, f)
    vsp = vsp - nargs + 1
  end

  local function do_end()
    local fr = ctrl[#ctrl]; ctrl[#ctrl] = nil
    if fr.kind == "block" then fb:place(fr.exit)
    elseif fr.kind == "if" then
      if not fr.else_seen then fb:place(fr.else_label) end
      fb:place(fr.exit)
    end -- loop: exit was placed at start
    vsp = fr.height
  end

  local function do_else()
    local fr = ctrl[#ctrl]
    fb:jmp(fr.exit)
    fb:place(fr.else_label)
    fr.else_seen = true
    vsp = fr.height
  end

  for _, ins in ipairs(code.body) do
    local op = ins.op
    if dead then
      if op == "end" then do_end(); dead = false
      elseif op == "else" then do_else(); dead = false
      elseif op == "block" or op == "loop" then
        ctrl[#ctrl + 1] = { kind = "dead" } -- placeholder to keep depth
      end
      -- otherwise skip
    elseif op == "local.get" then fb:MOVE(base + vsp, ins.x); vsp = vsp + 1
    elseif op == "local.set" then vsp = vsp - 1; fb:MOVE(ins.x, base + vsp)
    elseif op == "local.tee" then fb:MOVE(ins.x, base + vsp - 1)
    elseif op == "drop" then vsp = vsp - 1
    elseif op == "nop" then -- nothing
    elseif op == "i32.const" then fb:LOADK(base + vsp, fb:knum(ins.v % 4294967296)); vsp = vsp + 1
    elseif op == "i32.add" then
      local b = base + vsp - 1; local a = base + vsp - 2
      fb:ARITH(OP.ADD, a, a, b); fb:ARITH(OP.MOD, a, a, RK(kwrap)); vsp = vsp - 1
    elseif op == "i32.sub" then
      local b = base + vsp - 1; local a = base + vsp - 2
      fb:ARITH(OP.SUB, a, a, b); fb:ARITH(OP.MOD, a, a, RK(kwrap)); vsp = vsp - 1
    elseif BIN[op] then call_helper(BIN[op], 2)
    elseif UN[op] then call_helper(UN[op], 1)
    elseif op == "select" then
      local c = base + vsp - 1; local bb = base + vsp - 2; local aa = base + vsp - 3
      fb:EQ(0, c, RK(k0)); local L = fb:label(); fb:jmp(L)
      fb:MOVE(aa, bb); fb:place(L); vsp = vsp - 2
    elseif op == "block" then
      ctrl[#ctrl + 1] = { kind = "block", height = vsp, exit = fb:label() }
    elseif op == "loop" then
      local L = fb:label(); fb:place(L)
      ctrl[#ctrl + 1] = { kind = "loop", height = vsp, exit = L }
    elseif op == "if" then
      vsp = vsp - 1; local cond = base + vsp
      local fr = { kind = "if", height = vsp, exit = fb:label(), else_label = fb:label(), else_seen = false }
      fb:EQ(1, cond, RK(k0)); fb:jmp(fr.else_label)
      ctrl[#ctrl + 1] = fr
    elseif op == "else" then do_else()
    elseif op == "end" then do_end()
    elseif op == "br" then
      local fr = ctrl[#ctrl - ins.label]; fb:jmp(fr.exit); dead = true
    elseif op == "br_if" then
      vsp = vsp - 1; local cond = base + vsp
      fb:EQ(0, cond, RK(k0)); fb:jmp(ctrl[#ctrl - ins.label].exit)
    elseif op == "br_table" then
      vsp = vsp - 1; local idx = base + vsp
      for i = 1, #ins.targets do
        fb:EQ(1, idx, RK(fb:knum(i - 1))); fb:jmp(ctrl[#ctrl - ins.targets[i]].exit)
      end
      fb:jmp(ctrl[#ctrl - ins.default].exit); dead = true
    elseif op == "return" then
      if nres == 0 then fb:RETURN(0, 1) else fb:RETURN(base + vsp - nres, nres + 1) end
      dead = true
    elseif op == "unreachable" then
      local f = base + vsp; fb:GETTABLE(f, renv, RK(fb:kstr("__unreachable"))); fb:CALL(f, 1, 1); dead = true
    else
      error("compiler: unhandled op " .. op)
    end
  end

  if not dead then
    if nres == 0 then fb:RETURN(0, 1) else fb:RETURN(base + vsp - nres, nres + 1) end
  end
  fb:RETURN(0, 1)

  return luabc.loadable(fb)
end

return M
