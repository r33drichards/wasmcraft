-- wasm -> Lua 5.1 bytecode compiler (Cobalt fast path). Full op coverage:
-- i32/i64/f32/f64 arithmetic, conversions, memory, globals, calls, structured
-- control. Compiled functions take wasm params as Lua args, return wasm results
-- as Lua returns; the runtime ENV (helpers + memory/funcs/globals/tables) is an
-- upvalue. Self-contained: every defined function compiles into a closure that
-- calls others via ENV.funcs. Block/loop/if support results but not params.
local luabc = require("luabc")
local OP, RK = luabc.OP, luabc.RK
local runtime = require("runtime")
local Memory = require("memory")
local I = require("int64")

local function f32round(x) return (string.unpack("<f", string.pack("<f", x))) end
local function host_to_internal(t, v)
  if t == "i32" then return runtime.to_u32(v or 0) end
  if t == "i64" then if I.is(v) then return v end return I.from_double_s(v or 0) end
  if t == "f32" then return f32round(v or 0) end
  return v or 0
end
local function internal_to_host(t, v)
  if t == "i32" then return runtime.to_s32(v) end
  if t == "i64" then return I.to_double_s(v) end
  return v
end

local M = {}

-- op -> helper name. These pop their args and push one result (the helper does
-- the work). Binary unless noted; order of args = stack order.
local HELPER = {}
do
  local i32b = { "mul", "div_s", "div_u", "rem_s", "rem_u", "and", "or", "xor",
    "shl", "shr_s", "shr_u", "rotl", "rotr", "eq", "ne",
    "lt_s", "lt_u", "gt_s", "gt_u", "le_s", "le_u", "ge_s", "ge_u" }
  for _, n in ipairs(i32b) do
    local hn = n
    if n == "and" then hn = "band" elseif n == "or" then hn = "bor" elseif n == "xor" then hn = "bxor" end
    HELPER["i32." .. n] = { hn, 2 }
  end
  HELPER["i32.clz"] = { "clz", 1 }; HELPER["i32.ctz"] = { "ctz", 1 }; HELPER["i32.popcnt"] = { "popcnt", 1 }
  HELPER["i32.eqz"] = { "eqz", 1 }
  HELPER["i32.extend8_s"] = { "i32_extend8_s", 1 }; HELPER["i32.extend16_s"] = { "i32_extend16_s", 1 }
  -- i64
  local i64b = { "add", "sub", "mul", "div_s", "div_u", "rem_s", "rem_u", "and", "or", "xor",
    "shl", "shr_s", "shr_u", "rotl", "rotr", "eq", "ne",
    "lt_s", "lt_u", "gt_s", "gt_u", "le_s", "le_u", "ge_s", "ge_u" }
  for _, n in ipairs(i64b) do HELPER["i64." .. n] = { "i64_" .. n, 2 } end
  HELPER["i64.clz"] = { "i64_clz", 1 }; HELPER["i64.ctz"] = { "i64_ctz", 1 }; HELPER["i64.popcnt"] = { "i64_popcnt", 1 }
  HELPER["i64.eqz"] = { "i64_eqz", 1 }
  HELPER["i64.extend8_s"] = { "i64_extend8_s", 1 }; HELPER["i64.extend16_s"] = { "i64_extend16_s", 1 }
  HELPER["i64.extend32_s"] = { "i64_extend32_s", 1 }
  -- f32 (rounded helpers)
  for _, n in ipairs({ "abs", "neg", "ceil", "floor", "trunc", "nearest", "sqrt", "add", "sub", "mul", "div", "min", "max", "copysign" }) do
    HELPER["f32." .. n] = { "f32_" .. n, (n == "abs" or n == "neg" or n == "ceil" or n == "floor" or n == "trunc" or n == "nearest" or n == "sqrt") and 1 or 2 }
  end
  HELPER["f32.eq"] = { "feq", 2 }; HELPER["f32.ne"] = { "fne", 2 }; HELPER["f32.lt"] = { "flt", 2 }
  HELPER["f32.gt"] = { "fgt", 2 }; HELPER["f32.le"] = { "fle", 2 }; HELPER["f32.ge"] = { "fge", 2 }
  -- f64 unary + min/max/copysign via helpers; add/sub/mul/div/neg inline below
  HELPER["f64.abs"] = { "fabs", 1 }; HELPER["f64.ceil"] = { "ceil", 1 }; HELPER["f64.floor"] = { "floor", 1 }
  HELPER["f64.trunc"] = { "ftrunc", 1 }; HELPER["f64.nearest"] = { "fnearest", 1 }; HELPER["f64.sqrt"] = { "fsqrt", 1 }
  HELPER["f64.min"] = { "f64_min", 2 }; HELPER["f64.max"] = { "f64_max", 2 }; HELPER["f64.copysign"] = { "f64_copysign", 2 }
  HELPER["f64.eq"] = { "feq", 2 }; HELPER["f64.ne"] = { "fne", 2 }; HELPER["f64.lt"] = { "flt", 2 }
  HELPER["f64.gt"] = { "fgt", 2 }; HELPER["f64.le"] = { "fle", 2 }; HELPER["f64.ge"] = { "fge", 2 }
  -- conversions
  HELPER["i32.wrap_i64"] = { "i32_wrap_i64", 1 }
  HELPER["i64.extend_i32_s"] = { "i64_extend_i32_s", 1 }; HELPER["i64.extend_i32_u"] = { "i64_extend_i32_u", 1 }
  HELPER["i32.trunc_f32_s"] = { "i32_trunc_f_s", 1 }; HELPER["i32.trunc_f64_s"] = { "i32_trunc_f_s", 1 }
  HELPER["i32.trunc_f32_u"] = { "i32_trunc_f_u", 1 }; HELPER["i32.trunc_f64_u"] = { "i32_trunc_f_u", 1 }
  HELPER["i64.trunc_f32_s"] = { "i64_trunc_f_s", 1 }; HELPER["i64.trunc_f64_s"] = { "i64_trunc_f_s", 1 }
  HELPER["i64.trunc_f32_u"] = { "i64_trunc_f_u", 1 }; HELPER["i64.trunc_f64_u"] = { "i64_trunc_f_u", 1 }
  HELPER["i32.trunc_sat_f32_s"] = { "i32_trunc_sat_f_s", 1 }; HELPER["i32.trunc_sat_f64_s"] = { "i32_trunc_sat_f_s", 1 }
  HELPER["i32.trunc_sat_f32_u"] = { "i32_trunc_sat_f_u", 1 }; HELPER["i32.trunc_sat_f64_u"] = { "i32_trunc_sat_f_u", 1 }
  HELPER["i64.trunc_sat_f32_s"] = { "i64_trunc_sat_f_s", 1 }; HELPER["i64.trunc_sat_f64_s"] = { "i64_trunc_sat_f_s", 1 }
  HELPER["i64.trunc_sat_f32_u"] = { "i64_trunc_sat_f_u", 1 }; HELPER["i64.trunc_sat_f64_u"] = { "i64_trunc_sat_f_u", 1 }
  HELPER["f32.convert_i32_s"] = { "f32_convert_i32_s", 1 }; HELPER["f32.convert_i32_u"] = { "f32_convert_i32_u", 1 }
  HELPER["f64.convert_i32_s"] = { "f64_convert_i32_s", 1 }; HELPER["f64.convert_i32_u"] = { "f64_convert_i32_u", 1 }
  HELPER["f32.convert_i64_s"] = { "f32_convert_i64_s", 1 }; HELPER["f32.convert_i64_u"] = { "f32_convert_i64_u", 1 }
  HELPER["f64.convert_i64_s"] = { "f64_convert_i64_s", 1 }; HELPER["f64.convert_i64_u"] = { "f64_convert_i64_u", 1 }
  HELPER["f32.demote_f64"] = { "f32_demote_f64", 1 }; HELPER["f64.promote_f32"] = { "f64_promote_f32", 1 }
  HELPER["i32.reinterpret_f32"] = { "i32_reinterpret_f32", 1 }; HELPER["f32.reinterpret_i32"] = { "f32_reinterpret_i32", 1 }
  HELPER["i64.reinterpret_f64"] = { "i64_reinterpret_f64", 1 }; HELPER["f64.reinterpret_i64"] = { "f64_reinterpret_i64", 1 }
end

local LOAD = {
  ["i32.load"] = "i32_load", ["i32.load8_u"] = "i32_load8_u", ["i32.load8_s"] = "i32_load8_s",
  ["i32.load16_u"] = "i32_load16_u", ["i32.load16_s"] = "i32_load16_s",
  ["i64.load"] = "i64_load", ["i64.load8_u"] = "i64_load8_u", ["i64.load8_s"] = "i64_load8_s",
  ["i64.load16_u"] = "i64_load16_u", ["i64.load16_s"] = "i64_load16_s",
  ["i64.load32_u"] = "i64_load32_u", ["i64.load32_s"] = "i64_load32_s",
  ["f32.load"] = "f32_load", ["f64.load"] = "f64_load",
}
local STORE = {
  ["i32.store"] = "i32_store", ["i32.store8"] = "i32_store8", ["i32.store16"] = "i32_store16",
  ["i64.store"] = "i64_store", ["i64.store8"] = "i64_store8", ["i64.store16"] = "i64_store16", ["i64.store32"] = "i64_store32",
  ["f32.store"] = "f32_store", ["f64.store"] = "f64_store",
}

local function functype_of(mod, funcidx)
  local tix
  if funcidx < mod.numImportedFuncs then tix = mod.importedFuncs[funcidx + 1].typeidx
  else tix = mod.funcTypeIdx[funcidx - mod.numImportedFuncs + 1] end
  return mod.types[tix + 1]
end

local function bt_arity(mod, bt)
  if bt.typeidx then local ft = mod.types[bt.typeidx + 1]; return #ft.params, #ft.results end
  return #bt.params, #bt.results
end

function M.compile_func(mod, fidx)
  local ftype = mod.types[mod.funcTypeIdx[fidx] + 1]
  local code = mod.codes[fidx]
  local nparams = #ftype.params
  local locals_types = {}
  for i = 1, nparams do locals_types[i - 1] = ftype.params[i] end
  for i = 1, #code.locals do locals_types[nparams + i - 1] = code.locals[i] end
  local nlocals = nparams + #code.locals
  -- wasm locals live in a Lua table L (not registers) so functions with many
  -- locals don't blow past Lua's ~250-register limit. Registers are only the
  -- ENV, the L table, and the (shallow) operand stack.
  local renv = nparams         -- ENV upvalue cached here
  local Ltab = nparams + 1     -- locals table
  local kscr = nparams + 2     -- scratch register for spilling out-of-range constants
  local base = nparams + 3     -- operand stack base
  local nres = #ftype.results

  local fb = luabc.func(nparams, 1)
  fb:use(base)
  local kwrap = fb:knum(4294967296.0)
  local k0 = fb:knum(0.0)
  -- Operand usable in an RK position. Lua's RK field is 9 bits, so a constant
  -- index must be < 256; spill larger ones into kscr via LOADK.
  local function kop(kidx)
    if kidx < 256 then return RK(kidx) end
    fb:LOADK(kscr, kidx); return kscr
  end
  fb:GETUPVAL(renv, 0)
  fb:NEWTABLE(Ltab, 0, 0)
  for r = 0, nparams - 1 do fb:SETTABLE(Ltab, kop(fb:knum(r)), r) end
  for r = nparams, nlocals - 1 do
    if locals_types[r] == "i64" then
      local z = base; fb:GETTABLE(z, renv, kop(fb:kstr("ZERO64"))); fb:SETTABLE(Ltab, kop(fb:knum(r)), z)
    else
      fb:SETTABLE(Ltab, kop(fb:knum(r)), kop(k0))
    end
  end

  local vsp = 0
  local ctrl = {}
  local dead = false
  local dead_depth = 0
  local function go_dead() dead = true; dead_depth = #ctrl end

  local function helper(name, nargs, nresx)
    local argbase = base + vsp - nargs
    local f = base + vsp
    fb:GETTABLE(f, renv, kop(fb:kstr(name)))
    for i = 0, nargs - 1 do fb:MOVE(f + 1 + i, argbase + i) end
    fb:CALL(f, nargs + 1, nresx + 1)
    for i = 0, nresx - 1 do fb:MOVE(argbase + i, f + i) end
    vsp = vsp - nargs + nresx
  end

  local function ea_inline(addrreg, offset)
    if offset and offset ~= 0 then
      fb:ARITH(OP.ADD, addrreg, addrreg, kop(fb:knum(offset)))
      fb:ARITH(OP.MOD, addrreg, addrreg, kop(kwrap))
    end
  end

  local function branch_to(fr)
    local keep = fr.br_arity
    local dst = base + fr.height
    local src = base + vsp - keep
    if dst ~= src then for i = 0, keep - 1 do fb:MOVE(dst + i, src + i) end end
    fb:jmp(fr.exit)
  end

  local function do_end()
    local fr = ctrl[#ctrl]; ctrl[#ctrl] = nil
    if fr.kind == "block" then fb:place(fr.exit)
    elseif fr.kind == "if" then
      if not fr.else_seen then fb:place(fr.else_label) end
      fb:place(fr.exit)
    end
    vsp = fr.height + fr.results
  end
  local function do_else()
    local fr = ctrl[#ctrl]
    branch_to(fr)
    fb:place(fr.else_label); fr.else_seen = true
    vsp = fr.height
  end

  for _, ins in ipairs(code.body) do
    local op = ins.op
    if dead then
      if (op == "end" or op == "else") and #ctrl == dead_depth then
        if op == "end" then do_end() else do_else() end
        dead = false
      elseif op == "block" or op == "loop" or op == "if" then
        ctrl[#ctrl + 1] = { kind = "dead", height = vsp, results = 0, br_arity = 0 }
      elseif op == "end" then
        ctrl[#ctrl] = nil -- pop a nested placeholder inside the dead region
      end
    elseif op == "local.get" then fb:GETTABLE(base + vsp, Ltab, kop(fb:knum(ins.x))); vsp = vsp + 1
    elseif op == "local.set" then vsp = vsp - 1; fb:SETTABLE(Ltab, kop(fb:knum(ins.x)), base + vsp)
    elseif op == "local.tee" then fb:SETTABLE(Ltab, kop(fb:knum(ins.x)), base + vsp - 1)
    elseif op == "global.get" then
      local g = base + vsp
      fb:GETTABLE(g, renv, kop(fb:kstr("globals"))); fb:GETTABLE(g, g, kop(fb:knum(ins.x)))
      vsp = vsp + 1
    elseif op == "global.set" then
      vsp = vsp - 1; local v = base + vsp; local t = base + vsp + 1
      fb:GETTABLE(t, renv, kop(fb:kstr("globals"))); fb:SETTABLE(t, kop(fb:knum(ins.x)), v)
    elseif op == "drop" then vsp = vsp - 1
    elseif op == "nop" then -- nothing
    elseif op == "i32.const" then fb:LOADK(base + vsp, fb:knum(ins.v % 4294967296)); vsp = vsp + 1
    elseif op == "f32.const" or op == "f64.const" then fb:LOADK(base + vsp, fb:knum(ins.v)); vsp = vsp + 1
    elseif op == "i64.const" then
      local f = base + vsp
      fb:GETTABLE(f, renv, kop(fb:kstr("mk64")))
      fb:LOADK(f + 1, fb:knum(ins.v.h)); fb:LOADK(f + 2, fb:knum(ins.v.l))
      fb:CALL(f, 3, 2); vsp = vsp + 1
    elseif op == "i32.add" then local b = base + vsp - 1; local a = base + vsp - 2; fb:ARITH(OP.ADD, a, a, b); fb:ARITH(OP.MOD, a, a, kop(kwrap)); vsp = vsp - 1
    elseif op == "i32.sub" then local b = base + vsp - 1; local a = base + vsp - 2; fb:ARITH(OP.SUB, a, a, b); fb:ARITH(OP.MOD, a, a, kop(kwrap)); vsp = vsp - 1
    elseif op == "f64.add" then local b = base + vsp - 1; local a = base + vsp - 2; fb:ARITH(OP.ADD, a, a, b); vsp = vsp - 1
    elseif op == "f64.sub" then local b = base + vsp - 1; local a = base + vsp - 2; fb:ARITH(OP.SUB, a, a, b); vsp = vsp - 1
    elseif op == "f64.mul" then local b = base + vsp - 1; local a = base + vsp - 2; fb:ARITH(OP.MUL, a, a, b); vsp = vsp - 1
    elseif op == "f64.div" then local b = base + vsp - 1; local a = base + vsp - 2; fb:ARITH(OP.DIV, a, a, b); vsp = vsp - 1
    elseif op == "f64.neg" then local a = base + vsp - 1; fb:UNM(a, a)
    elseif HELPER[op] then helper(HELPER[op][1], HELPER[op][2], 1)
    elseif LOAD[op] then ea_inline(base + vsp - 1, ins.offset); helper(LOAD[op], 1, 1)
    elseif STORE[op] then ea_inline(base + vsp - 2, ins.offset); helper(STORE[op], 2, 0)
    elseif op == "memory.size" then helper("mem_size", 0, 1)
    elseif op == "memory.grow" then helper("mem_grow", 1, 1)
    elseif op == "memory.fill" then helper("mem_fill", 3, 0)
    elseif op == "memory.copy" then helper("mem_copy", 3, 0)
    elseif op == "select" then
      local c = base + vsp - 1; local bb = base + vsp - 2; local aa = base + vsp - 3
      fb:EQ(0, c, kop(k0)); local L = fb:label(); fb:jmp(L); fb:MOVE(aa, bb); fb:place(L); vsp = vsp - 2
    elseif op == "block" then
      local p, r = bt_arity(mod, ins.bt); assert(p == 0, "block with params")
      ctrl[#ctrl + 1] = { kind = "block", height = vsp, results = r, br_arity = r, exit = fb:label() }
    elseif op == "loop" then
      local p, r = bt_arity(mod, ins.bt); assert(p == 0, "loop with params")
      local L = fb:label(); fb:place(L)
      ctrl[#ctrl + 1] = { kind = "loop", height = vsp, results = r, br_arity = 0, exit = L }
    elseif op == "if" then
      local p, r = bt_arity(mod, ins.bt); assert(p == 0, "if with params")
      vsp = vsp - 1; local cond = base + vsp
      local fr = { kind = "if", height = vsp, results = r, br_arity = r, exit = fb:label(), else_label = fb:label(), else_seen = false }
      fb:EQ(1, cond, kop(k0)); fb:jmp(fr.else_label)
      ctrl[#ctrl + 1] = fr
    elseif op == "else" then do_else()
    elseif op == "end" then do_end()
    elseif op == "br" then branch_to(ctrl[#ctrl - ins.label]); go_dead()
    elseif op == "br_if" then
      vsp = vsp - 1; local cond = base + vsp
      local fr = ctrl[#ctrl - ins.label]
      if fr.br_arity == 0 then
        fb:EQ(0, cond, kop(k0)); fb:jmp(fr.exit)
      else
        -- if cond==0 skip the branch; else move values + jump
        fb:EQ(1, cond, kop(k0)); local L = fb:label(); fb:jmp(L)
        branch_to(fr); fb:place(L)
      end
    elseif op == "br_table" then
      vsp = vsp - 1; local idx = base + vsp
      for i = 1, #ins.targets do
        local fr = ctrl[#ctrl - ins.targets[i]]
        fb:EQ(1, idx, kop(fb:knum(i - 1))); local L = fb:label(); fb:jmp(L)
        -- equal: branch; else fall to next compare
        local L2 = fb:label(); fb:jmp(L2) -- unconditional skip of branch block
        fb:place(L) -- target when idx==i-1
        vsp = vsp + 1 -- idx still logically present for value moves
        branch_to(fr); vsp = vsp - 1
        fb:place(L2)
      end
      local frd = ctrl[#ctrl - ins.default]
      vsp = vsp + 1; branch_to(frd); vsp = vsp - 1
      go_dead()
    elseif op == "return" then
      if nres == 0 then fb:RETURN(0, 1) else fb:RETURN(base + vsp - nres, nres + 1) end
      go_dead()
    elseif op == "unreachable" then
      local f = base + vsp; fb:GETTABLE(f, renv, kop(fb:kstr("__unreachable"))); fb:CALL(f, 1, 1); go_dead()
    elseif op == "call" then
      local ct = functype_of(mod, ins.func)
      local na = #ct.params; local nr = #ct.results
      local argbase = base + vsp - na; local fr = base + vsp
      fb:GETTABLE(fr, renv, kop(fb:kstr("funcs"))); fb:GETTABLE(fr, fr, kop(fb:knum(ins.func)))
      for i = 0, na - 1 do fb:MOVE(fr + 1 + i, argbase + i) end
      fb:CALL(fr, na + 1, nr + 1)
      for i = 0, nr - 1 do fb:MOVE(argbase + i, fr + i) end
      vsp = vsp - na + nr
    elseif op == "call_indirect" then
      local ct = mod.types[ins.typeidx + 1]
      local na = #ct.params; local nr = #ct.results
      vsp = vsp - 1; local idxr = base + vsp
      local argbase = base + vsp - na; local fr = base + vsp + 1; local tmp = base + vsp + 2
      fb:GETTABLE(fr, renv, kop(fb:kstr("tables"))); fb:GETTABLE(fr, fr, kop(fb:knum(ins.table)))
      fb:GETTABLE(fr, fr, idxr)
      fb:GETTABLE(tmp, renv, kop(fb:kstr("funcs"))); fb:GETTABLE(fr, tmp, fr)
      for i = 0, na - 1 do fb:MOVE(fr + 1 + i, argbase + i) end
      fb:CALL(fr, na + 1, nr + 1)
      for i = 0, nr - 1 do fb:MOVE(argbase + i, fr + i) end
      vsp = vsp - na + nr
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

-- ---- instantiation: compile every function, wire the instance --------------
local function evalConst(inst, instrs)
  local v
  for _, ins in ipairs(instrs) do
    local op = ins.op
    if op == "i32.const" then v = runtime.to_u32(ins.v)
    elseif op == "i64.const" then v = ins.v
    elseif op == "f32.const" or op == "f64.const" then v = ins.v
    elseif op == "global.get" then v = inst.globals[ins.x]
    elseif op == "ref.func" then v = ins.func
    elseif op == "ref.null" then v = nil
    elseif op == "end" then break end
  end
  return v
end

function M.instantiate(module, imports)
  imports = imports or {}
  local loader = loadstring or load
  local inst = { module = module }

  if module.importedMem then
    inst.memory = imports[module.importedMem.module][module.importedMem.name]
  elseif module.memories[1] then
    inst.memory = Memory.new(module.memories[1].min, module.memories[1].max)
  else
    inst.memory = Memory.new(0)
  end

  inst.funcs = {}
  inst.globals = {}
  inst.tables = {}
  local ENV = runtime.make(inst)

  -- imported functions wrapped to the uniform calling convention
  for i = 1, module.numImportedFuncs do
    local imp = module.importedFuncs[i]
    local host = imports[imp.module] and imports[imp.module][imp.name]
    if not host then error("missing import: " .. imp.module .. "." .. imp.name) end
    local fi = i - 1
    inst.funcs[fi] = function(...)
      local res = host({ ... }, inst)
      return (table.unpack or unpack)(res or {})
    end
  end
  -- defined functions: lazily compiled on first call (big modules have many
  -- functions that never run; compiling all of them up front would be wasteful).
  for j = 1, #module.funcTypeIdx do
    local gi = module.numImportedFuncs + (j - 1)
    inst.funcs[gi] = function(...)
      local fn = assert(loader(M.compile_func(module, j), "wasmfn#" .. gi))(ENV)
      inst.funcs[gi] = fn
      return fn(...)
    end
  end

  for i = 1, #module.globals do
    inst.globals[module.numImportedGlobals + (i - 1)] = evalConst(inst, module.globals[i].init)
  end
  for i = 1, #module.tables do inst.tables[i - 1] = {} end
  for _, seg in ipairs(module.elements) do
    if seg.mode == "active" then
      local b = evalConst(inst, seg.offset); local tbl = inst.tables[seg.table or 0]
      for k = 1, #seg.funcs do tbl[b + k - 1] = seg.funcs[k] end
    end
  end
  for _, seg in ipairs(module.datas) do
    if seg.mode == "active" then inst.memory:storestr(evalConst(inst, seg.offset), seg.bytes) end
  end

  function inst:call(name, ...)
    local exp = module.exports[name]
    if not exp or exp.kind ~= "func" then error("no exported function '" .. tostring(name) .. "'") end
    local ftype = functype_of(module, exp.index)
    local raw = { ... }
    local args = {}
    for i = 1, #ftype.params do args[i] = host_to_internal(ftype.params[i], raw[i]) end
    local out = { self.funcs[exp.index]((table.unpack or unpack)(args)) }
    local res = {}
    for i = 1, #ftype.results do res[i] = internal_to_host(ftype.results[i], out[i]) end
    return (table.unpack or unpack)(res)
  end
  inst.set_yield = require("interp").set_yield

  if module.start ~= nil then inst.funcs[module.start]() end
  return inst
end

M.runtime = runtime
return M
