-- wasm -> Lua 5.1 SOURCE transpiler. Third backend: same semantics as
-- src/compiler.lua (the bytecode compiler), but emits Lua *source text*, which
-- loads on CC:Tweaked >= 1.109 (binary chunks are refused there).
--
--   M.transpile_func(mod, fidx)      -> source string (structured emission)
--   M.transpile_oversized(mod, fidx) -> source string (flattened dispatcher,
--                                       for functions beyond Lua's limits)
--   loadstring(src)(ENV)             -> the wasm function (params in, results out)
--   M.instantiate(module, imports, opts) -- same shape as compiler.instantiate
--
-- Values follow runtime.lua: i32 = unsigned Lua number 0..2^32-1, i64 = {h,l},
-- f32/f64 = Lua number. All non-trivial ops call the same ENV helpers the
-- bytecode compiler calls.
local runtime = require("runtime")
local Memory = require("memory")
local I = require("int64")

local floor, abs, huge = math.floor, math.abs, math.huge
local format, concat = string.format, table.concat

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

-- Yield emission mirrors the bytecode compiler's switch: read its flag so both
-- backends behave identically under CC.
local function yield_enabled()
  local ok, c = pcall(require, "compiler")
  return (ok and c.yield_in_loops) and true or false
end

-- ---- op tables (mirrors compiler.lua exactly) ------------------------------
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
  local i64b = { "add", "sub", "mul", "div_s", "div_u", "rem_s", "rem_u", "and", "or", "xor",
    "shl", "shr_s", "shr_u", "rotl", "rotr", "eq", "ne",
    "lt_s", "lt_u", "gt_s", "gt_u", "le_s", "le_u", "ge_s", "ge_u" }
  for _, n in ipairs(i64b) do HELPER["i64." .. n] = { "i64_" .. n, 2 } end
  HELPER["i64.clz"] = { "i64_clz", 1 }; HELPER["i64.ctz"] = { "i64_ctz", 1 }; HELPER["i64.popcnt"] = { "i64_popcnt", 1 }
  HELPER["i64.eqz"] = { "i64_eqz", 1 }
  HELPER["i64.extend8_s"] = { "i64_extend8_s", 1 }; HELPER["i64.extend16_s"] = { "i64_extend16_s", 1 }
  HELPER["i64.extend32_s"] = { "i64_extend32_s", 1 }
  for _, n in ipairs({ "abs", "neg", "ceil", "floor", "trunc", "nearest", "sqrt", "add", "sub", "mul", "div", "min", "max", "copysign" }) do
    HELPER["f32." .. n] = { "f32_" .. n, (n == "abs" or n == "neg" or n == "ceil" or n == "floor" or n == "trunc" or n == "nearest" or n == "sqrt") and 1 or 2 }
  end
  HELPER["f32.eq"] = { "feq", 2 }; HELPER["f32.ne"] = { "fne", 2 }; HELPER["f32.lt"] = { "flt", 2 }
  HELPER["f32.gt"] = { "fgt", 2 }; HELPER["f32.le"] = { "fle", 2 }; HELPER["f32.ge"] = { "fge", 2 }
  HELPER["f64.abs"] = { "fabs", 1 }; HELPER["f64.ceil"] = { "ceil", 1 }; HELPER["f64.floor"] = { "floor", 1 }
  HELPER["f64.trunc"] = { "ftrunc", 1 }; HELPER["f64.nearest"] = { "fnearest", 1 }; HELPER["f64.sqrt"] = { "fsqrt", 1 }
  HELPER["f64.min"] = { "f64_min", 2 }; HELPER["f64.max"] = { "f64_max", 2 }; HELPER["f64.copysign"] = { "f64_copysign", 2 }
  HELPER["f64.eq"] = { "feq", 2 }; HELPER["f64.ne"] = { "fne", 2 }; HELPER["f64.lt"] = { "flt", 2 }
  HELPER["f64.gt"] = { "fgt", 2 }; HELPER["f64.le"] = { "fle", 2 }; HELPER["f64.ge"] = { "fge", 2 }
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

-- ---- number formatting for source text -------------------------------------
local function fmti(n) return format("%.0f", n) end
local function fmtnum(v)
  if v ~= v then return "(0/0)" end                 -- NaN (runtime-evaluated; 5.1 won't fold x/0)
  if v == huge then return "(1/0)" end
  if v == -huge then return "(-(1/0))" end
  if v == floor(v) and abs(v) <= 9007199254740992 then return format("%.0f", v) end
  return format("%.17g", v)                          -- round-trips doubles exactly
end

-- ---- helper-usage pre-scan (decides which ENV fields get hoisted) ----------
local function scan_uses(code, yield)
  local counts = {}
  local function use(n) counts[n] = (counts[n] or 0) + 1 end
  for i = 1, #code.locals do
    if code.locals[i] == "i64" then use("ZERO64") end
  end
  for _, ins in ipairs(code.body) do
    local op = ins.op
    local h = HELPER[op]
    if h then use(h[1])
    elseif LOAD[op] then use(LOAD[op])
    elseif STORE[op] then use(STORE[op])
    elseif op == "i64.const" then use("mk64")
    elseif op == "global.get" or op == "global.set" then use("globals")
    elseif op == "call" then use("funcs")
    elseif op == "call_indirect" then use("funcs"); use("tables")
    elseif op == "memory.size" then use("mem_size")
    elseif op == "memory.grow" then use("mem_grow")
    elseif op == "memory.fill" then use("mem_fill")
    elseif op == "memory.copy" then use("mem_copy")
    elseif op == "unreachable" then use("__unreachable")
    elseif yield and (op == "br" or op == "br_if" or op == "loop") then use("__tick")
    end
  end
  return counts
end

-- Lua 5.1 closures cap at 60 upvalues; keep the hoisted set comfortably below.
local function pick_hoist(counts, cap)
  local names = {}
  for n in pairs(counts) do names[#names + 1] = n end
  table.sort(names, function(a, b)
    if counts[a] ~= counts[b] then return counts[a] > counts[b] end
    return a < b
  end)
  local set, list = {}, {}
  for i = 1, math.min(cap, #names) do set[names[i]] = true; list[i] = names[i] end
  return set, list
end

local function hoist_lines(out, list)
  local i = 1
  while i <= #list do
    local j = math.min(i + 11, #list)
    local ls, rs = {}, {}
    for k = i, j do ls[#ls + 1] = list[k]; rs[#rs + 1] = "E." .. list[k] end
    out[#out + 1] = "local " .. concat(ls, ", ") .. " = " .. concat(rs, ", ")
    i = j + 1
  end
end

-- Emit `L = {...}` init lines (params + typed zero defaults), like compiler.lua.
local function emit_local_init(emit, ref, nparams, nlocals, locals_types)
  local r = nparams
  while r < nlocals do
    local t = locals_types[r]
    local e = r
    while e + 1 < nlocals and ((locals_types[e + 1] == "i64") == (t == "i64")) do e = e + 1 end
    local valstr = (t == "i64") and ref("ZERO64") or "0"
    if e - r >= 3 then
      emit("for i = " .. r .. ", " .. e .. " do L[i] = " .. valstr .. " end")
    else
      for k = r, e do emit("L[" .. k .. "] = " .. valstr) end
    end
    r = e + 1
  end
end

-- ---- shared per-op emission (everything except control flow) ---------------
-- cx: { slot(i)->string, emit(line), ref(name)->string, vsp, setv(v) }
local function core_step(mod, cx, ins)
  local op = ins.op
  local emit, slot, ref = cx.emit, cx.slot, cx.ref
  local v = cx.vsp
  if op == "local.get" then
    emit(slot(v) .. " = L[" .. ins.x .. "]"); cx.setv(v + 1)
  elseif op == "local.set" then
    cx.setv(v - 1); emit("L[" .. ins.x .. "] = " .. slot(v - 1))
  elseif op == "local.tee" then
    emit("L[" .. ins.x .. "] = " .. slot(v - 1))
  elseif op == "global.get" then
    emit(slot(v) .. " = " .. ref("globals") .. "[" .. ins.x .. "]"); cx.setv(v + 1)
  elseif op == "global.set" then
    cx.setv(v - 1); emit(ref("globals") .. "[" .. ins.x .. "] = " .. slot(v - 1))
  elseif op == "drop" then cx.setv(v - 1)
  elseif op == "nop" then -- nothing
  elseif op == "i32.const" then
    emit(slot(v) .. " = " .. fmti(ins.v % 4294967296)); cx.setv(v + 1)
  elseif op == "f32.const" or op == "f64.const" then
    emit(slot(v) .. " = " .. fmtnum(ins.v)); cx.setv(v + 1)
  elseif op == "i64.const" then
    emit(slot(v) .. " = " .. ref("mk64") .. "(" .. fmti(ins.v.h) .. ", " .. fmti(ins.v.l) .. ")"); cx.setv(v + 1)
  elseif op == "i32.add" then
    local a, b = slot(v - 2), slot(v - 1)
    emit(a .. " = (" .. a .. " + " .. b .. ") % 4294967296"); cx.setv(v - 1)
  elseif op == "i32.sub" then
    local a, b = slot(v - 2), slot(v - 1)
    emit(a .. " = (" .. a .. " - " .. b .. ") % 4294967296"); cx.setv(v - 1)
  elseif op == "f64.add" then
    local a, b = slot(v - 2), slot(v - 1); emit(a .. " = " .. a .. " + " .. b); cx.setv(v - 1)
  elseif op == "f64.sub" then
    local a, b = slot(v - 2), slot(v - 1); emit(a .. " = " .. a .. " - " .. b); cx.setv(v - 1)
  elseif op == "f64.mul" then
    local a, b = slot(v - 2), slot(v - 1); emit(a .. " = " .. a .. " * " .. b); cx.setv(v - 1)
  elseif op == "f64.div" then
    local a, b = slot(v - 2), slot(v - 1); emit(a .. " = " .. a .. " / " .. b); cx.setv(v - 1)
  elseif op == "f64.neg" then
    local a = slot(v - 1); emit(a .. " = -" .. a)
  elseif HELPER[op] then
    local h = HELPER[op]
    if h[2] == 1 then
      local a = slot(v - 1); emit(a .. " = " .. ref(h[1]) .. "(" .. a .. ")")
    else
      local a, b = slot(v - 2), slot(v - 1)
      emit(a .. " = " .. ref(h[1]) .. "(" .. a .. ", " .. b .. ")"); cx.setv(v - 1)
    end
  elseif LOAD[op] then
    local a = slot(v - 1)
    local ea = (ins.offset and ins.offset ~= 0)
      and ("(" .. a .. " + " .. fmti(ins.offset) .. ") % 4294967296") or a
    emit(a .. " = " .. ref(LOAD[op]) .. "(" .. ea .. ")")
  elseif STORE[op] then
    local a, val = slot(v - 2), slot(v - 1)
    local ea = (ins.offset and ins.offset ~= 0)
      and ("(" .. a .. " + " .. fmti(ins.offset) .. ") % 4294967296") or a
    emit(ref(STORE[op]) .. "(" .. ea .. ", " .. val .. ")"); cx.setv(v - 2)
  elseif op == "memory.size" then
    emit(slot(v) .. " = " .. ref("mem_size") .. "()"); cx.setv(v + 1)
  elseif op == "memory.grow" then
    local a = slot(v - 1); emit(a .. " = " .. ref("mem_grow") .. "(" .. a .. ")")
  elseif op == "memory.fill" then
    emit(ref("mem_fill") .. "(" .. slot(v - 3) .. ", " .. slot(v - 2) .. ", " .. slot(v - 1) .. ")"); cx.setv(v - 3)
  elseif op == "memory.copy" then
    emit(ref("mem_copy") .. "(" .. slot(v - 3) .. ", " .. slot(v - 2) .. ", " .. slot(v - 1) .. ")"); cx.setv(v - 3)
  elseif op == "select" then
    emit("if " .. slot(v - 1) .. " == 0 then " .. slot(v - 3) .. " = " .. slot(v - 2) .. " end"); cx.setv(v - 2)
  elseif op == "call" then
    local ct = functype_of(mod, ins.func)
    local na, nr = #ct.params, #ct.results
    local b = v - na
    local args = {}
    for i = 0, na - 1 do args[i + 1] = slot(b + i) end
    local callstr = ref("funcs") .. "[" .. ins.func .. "](" .. concat(args, ", ") .. ")"
    if nr == 0 then emit(callstr)
    else
      local outs = {}
      for i = 0, nr - 1 do outs[i + 1] = slot(b + i) end
      emit(concat(outs, ", ") .. " = " .. callstr)
    end
    cx.setv(b + nr)
  elseif op == "call_indirect" then
    local ct = mod.types[ins.typeidx + 1]
    local na, nr = #ct.params, #ct.results
    local idx = slot(v - 1)
    local b = v - 1 - na
    local args = {}
    for i = 0, na - 1 do args[i + 1] = slot(b + i) end
    local callstr = ref("funcs") .. "[" .. ref("tables") .. "[" .. ins.table .. "][" .. idx .. "]](" ..
      concat(args, ", ") .. ")"
    if nr == 0 then emit(callstr)
    else
      local outs = {}
      for i = 0, nr - 1 do outs[i + 1] = slot(b + i) end
      emit(concat(outs, ", ") .. " = " .. callstr)
    end
    cx.setv(b + nr)
  else
    return false
  end
  return true
end

-- =============================================================================
-- Structured emission: wasm control becomes Lua control. block -> repeat..until
-- true; loop -> while true do repeat..until true <route> end; if -> repeat if..
-- Multi-level br: __br counts remaining frames; a cascade after every frame
-- closer consumes one level per frame, loops route __br==0 to "continue".
-- =============================================================================
local MAX_DEPTH = 60
local MAX_BODY = 8000
local MAX_SLOTS = 110

function M.transpile_func(mod, fidx)
  local ftype = mod.types[mod.funcTypeIdx[fidx] + 1]
  local code = mod.codes[fidx]
  local body = code.body
  if #body > MAX_BODY then error("transpiler: body too large (" .. #body .. " instrs)") end
  local nparams = #ftype.params
  local nres = #ftype.results
  if nparams > 100 then error("transpiler: too many params") end
  local yield = yield_enabled()

  local locals_types = {}
  for i = 1, nparams do locals_types[i - 1] = ftype.params[i] end
  for i = 1, #code.locals do locals_types[nparams + i - 1] = code.locals[i] end
  local nlocals = nparams + #code.locals

  local counts = scan_uses(code, yield)
  local hoisted, hlist = pick_hoist(counts, 52)
  local function ref(n) if hoisted[n] then return n end return "E." .. n end

  local lines = {}
  local function emit(s) lines[#lines + 1] = s end
  local maxslot = 0
  local function slot(i)
    if i + 1 > maxslot then maxslot = i + 1 end
    return "s" .. i
  end

  local cx = { emit = emit, slot = slot, ref = ref, vsp = 0 }
  function cx.setv(v) cx.vsp = v; if v > maxslot then maxslot = v end end

  local ctrl = {}
  local dead, dead_depth = false, 0
  local function go_dead() dead = true; dead_depth = #ctrl end

  local CASCADE = "if __br then if __br > 0 then __br = __br - 1 break end __br = nil end"
  local function cascade(fr)
    -- __br can only reach the outermost frame's closer as 0 (function-level br
    -- is emitted as a direct return), and `break` there would be a syntax error.
    if fr.idx == 1 then emit("if __br then __br = nil end") else emit(CASCADE) end
  end

  local function return_stmt(h)
    if nres == 0 then return "return" end
    local t = {}
    for i = 0, nres - 1 do t[i + 1] = slot(h - nres + i) end
    return "return " .. concat(t, ", ")
  end

  -- moves + control transfer for a br to frame fr at relative depth d
  local function branch_stmt(fr, d)
    local parts = {}
    local keep = fr.br_arity
    local dst, src = fr.height, cx.vsp - keep
    if dst ~= src then
      for i = 0, keep - 1 do parts[#parts + 1] = slot(dst + i) .. " = " .. slot(src + i) end
    end
    if d == 0 then
      if fr.kind == "loop" then parts[#parts + 1] = "__br = 0 break"
      else parts[#parts + 1] = "break" end
    else
      parts[#parts + 1] = "__br = " .. d .. " break"
    end
    return concat(parts, " ")
  end

  local function do_end()
    local fr = ctrl[#ctrl]; ctrl[#ctrl] = nil
    if fr.kind == "block" then
      emit("until true"); cascade(fr)
    elseif fr.kind == "if" then
      emit("end until true"); cascade(fr)
    elseif fr.kind == "loop" then
      emit("until true")
      emit("if __br ~= 0 then break end __br = nil")
      emit("end")
      cascade(fr)
    end
    cx.setv(fr.height + fr.results)
  end
  local function do_else()
    local fr = ctrl[#ctrl]
    fr.else_seen = true
    emit("else")
    cx.setv(fr.height)
  end

  for _, ins in ipairs(body) do
    local op = ins.op
    if dead then
      if (op == "end" or op == "else") and #ctrl == dead_depth then
        if op == "end" then do_end() else do_else() end
        dead = false
      elseif op == "block" or op == "loop" or op == "if" then
        ctrl[#ctrl + 1] = { kind = "dead", height = cx.vsp, results = 0, br_arity = 0, idx = #ctrl + 1 }
      elseif op == "end" then
        ctrl[#ctrl] = nil
      end
    elseif core_step(mod, cx, ins) then
      -- handled
    elseif op == "block" then
      local p, r = bt_arity(mod, ins.bt); assert(p == 0, "block with params")
      if #ctrl >= MAX_DEPTH then error("transpiler: control nesting too deep") end
      emit("repeat")
      ctrl[#ctrl + 1] = { kind = "block", height = cx.vsp, results = r, br_arity = r, idx = #ctrl + 1 }
    elseif op == "loop" then
      local p, r = bt_arity(mod, ins.bt); assert(p == 0, "loop with params")
      if #ctrl >= MAX_DEPTH then error("transpiler: control nesting too deep") end
      emit("while true do repeat")
      ctrl[#ctrl + 1] = { kind = "loop", height = cx.vsp, results = r, br_arity = 0, idx = #ctrl + 1 }
    elseif op == "if" then
      local p, r = bt_arity(mod, ins.bt); assert(p == 0, "if with params")
      if #ctrl >= MAX_DEPTH then error("transpiler: control nesting too deep") end
      cx.setv(cx.vsp - 1)
      emit("repeat if " .. slot(cx.vsp) .. " ~= 0 then")
      ctrl[#ctrl + 1] = { kind = "if", height = cx.vsp, results = r, br_arity = r, idx = #ctrl + 1, else_seen = false }
    elseif op == "else" then do_else()
    elseif op == "end" then do_end()
    elseif op == "br" then
      local d = ins.label
      if d >= #ctrl then
        emit(return_stmt(cx.vsp))
      else
        local fr = ctrl[#ctrl - d]
        if yield and fr.kind == "loop" then emit(ref("__tick") .. "()") end
        emit(branch_stmt(fr, d))
      end
      go_dead()
    elseif op == "br_if" then
      cx.setv(cx.vsp - 1)
      local cond = slot(cx.vsp)
      local d = ins.label
      if d >= #ctrl then
        emit("if " .. cond .. " ~= 0 then " .. return_stmt(cx.vsp) .. " end")
      else
        local fr = ctrl[#ctrl - d]
        if yield and fr.kind == "loop" then emit(ref("__tick") .. "()") end
        emit("if " .. cond .. " ~= 0 then " .. branch_stmt(fr, d) .. " end")
      end
    elseif op == "br_table" then
      cx.setv(cx.vsp - 1)
      local idx = slot(cx.vsp)
      local parts = {}
      for i = 1, #ins.targets do
        local d = ins.targets[i]
        local stmt = (d >= #ctrl) and return_stmt(cx.vsp) or branch_stmt(ctrl[#ctrl - d], d)
        parts[#parts + 1] = ((i == 1) and "if " or "elseif ") .. idx .. " == " .. (i - 1) .. " then " .. stmt
      end
      local dd = ins.default
      local dstmt = (dd >= #ctrl) and return_stmt(cx.vsp) or branch_stmt(ctrl[#ctrl - dd], dd)
      if #parts == 0 then emit(dstmt)
      else emit(concat(parts, "\n") .. "\nelse " .. dstmt .. "\nend") end
      go_dead()
    elseif op == "return" then
      emit(return_stmt(cx.vsp)); go_dead()
    elseif op == "unreachable" then
      emit(ref("__unreachable") .. "()"); go_dead()
    else
      error("transpiler: unhandled op " .. op)
    end
  end
  if not dead then emit(return_stmt(cx.vsp)) end

  if maxslot > MAX_SLOTS then error("transpiler: operand stack too deep (" .. maxslot .. ")") end
  if nparams + maxslot + 4 > 150 then error("transpiler: too many locals") end

  -- assemble chunk
  local out = { "local E = ..." }
  hoist_lines(out, hlist)
  local params = {}
  for i = 0, nparams - 1 do params[i + 1] = "a" .. i end
  out[#out + 1] = "return function(" .. concat(params, ", ") .. ")"
  if nparams > 0 then
    out[#out + 1] = "local L = {[0] = " .. concat(params, ", ") .. "}"
  else
    out[#out + 1] = "local L = {}"
  end
  emit_local_init(function(s) out[#out + 1] = s end, ref, nparams, nlocals, locals_types)
  do
    local i = 0
    while i < maxslot do
      local j = math.min(i + 15, maxslot - 1)
      local t = {}
      for k = i, j do t[#t + 1] = "s" .. k end
      out[#out + 1] = "local " .. concat(t, ", ")
      i = j + 1
    end
  end
  out[#out + 1] = "local __br"
  out[#out + 1] = concat(lines, "\n")
  out[#out + 1] = "end"
  return concat(out, "\n")
end

-- =============================================================================
-- Flattened emission for oversized functions: resolve all structured control to
-- pc-indexed basic blocks; operand stack is a table S with compile-time-constant
-- indices; code is split into segment functions, each a while-true dispatcher
-- with a binary if-tree over its labels. Cross-segment jumps return the pc.
-- =============================================================================
local SEGSIZE = 4000

function M.transpile_oversized(mod, fidx)
  local ftype = mod.types[mod.funcTypeIdx[fidx] + 1]
  local code = mod.codes[fidx]
  local body = code.body
  local n = #body
  local nparams = #ftype.params
  local nres = #ftype.results
  if nparams > 100 then error("transpiler: too many params") end
  local yield = yield_enabled()

  local locals_types = {}
  for i = 1, nparams do locals_types[i - 1] = ftype.params[i] end
  for i = 1, #code.locals do locals_types[nparams + i - 1] = code.locals[i] end
  local nlocals = nparams + #code.locals

  local counts = scan_uses(code, yield)
  if yield then counts.__tick = (counts.__tick or 0) + 1 end
  local hoisted, hlist = pick_hoist(counts, 40)
  local function ref(nm) if hoisted[nm] then return nm end return "E." .. nm end

  local nsegs = floor((n + 1) / SEGSIZE) + 1

  -- leaves: ordered list of { pc, seg, lines }
  local leaves = {}
  local cur, leaf_term
  local function newleaf(pc)
    cur = { pc = pc, seg = floor(pc / SEGSIZE), lines = {} }
    leaves[#leaves + 1] = cur
    leaf_term = false
  end
  local function emit(s) cur.lines[#cur.lines + 1] = s end

  local function slot(i) return "S[" .. (i + 1) .. "]" end
  local cx = { emit = emit, slot = slot, ref = ref, vsp = 0 }
  function cx.setv(v) cx.vsp = v end

  -- unconditional/embedded control transfer to pc T from the current leaf
  local function transfer(T)
    if floor(T / SEGSIZE) == cur.seg then return "pc = " .. T .. " break" end
    return "return " .. T
  end

  local exit_height = nil -- stack height at the function-exit label (n+1), if used
  local labels = { [1] = true }
  local need_exit = false

  local function return_lines(h)
    local t = {}
    for i = 1, nres do
      local srci = h - nres + i
      if srci ~= i then t[#t + 1] = "S[" .. i .. "] = S[" .. srci .. "]" end
    end
    t[#t + 1] = "return -1"
    return t
  end

  -- Resolve a branch depth d to { pc, height, keep, kind } or "ret" (function level)
  local ctrl = {}
  local function resolve(d)
    if d >= #ctrl then return nil end
    return ctrl[#ctrl - d]
  end
  local function target_pc(fr)
    if fr.target == n + 1 then
      need_exit = true
      labels[n + 1] = true
      exit_height = fr.height + fr.results
    end
    return fr.target
  end

  -- moves for taking a branch to fr with current height v
  local function move_lines(fr, v)
    local t = {}
    local keep = fr.br_arity
    local dst, src = fr.height, v - keep
    if dst ~= src then
      for i = 0, keep - 1 do t[#t + 1] = slot(dst + i) .. " = " .. slot(src + i) end
    end
    return t
  end

  local jts = {} -- collected jump tables: { {map={[i]=pc}, default=pc} }

  local dead, dead_depth = false, 0
  local function go_dead() dead = true; dead_depth = #ctrl end

  newleaf(1)

  for pc = 1, n do
    local ins = body[pc]
    local op = ins.op
    if not dead and cur.pc ~= pc and (labels[pc] or leaf_term or floor(pc / SEGSIZE) ~= cur.seg) then
      if not leaf_term then emit(transfer(pc)) end
      newleaf(pc)
    end
    if dead then
      if (op == "end" or op == "else") and #ctrl == dead_depth then
        if op == "end" then
          local fr = ctrl[#ctrl]; ctrl[#ctrl] = nil
          cx.setv(fr.height + fr.results)
        else
          local fr = ctrl[#ctrl]
          cx.setv(fr.height)
        end
        dead = false
        -- leaf_term is necessarily true here (go_dead only follows terminators),
        -- so the next emitted instruction opens a fresh leaf.
      elseif op == "block" or op == "loop" or op == "if" then
        ctrl[#ctrl + 1] = { kind = "dead", height = cx.vsp, results = 0, br_arity = 0, target = 0 }
      elseif op == "end" then
        ctrl[#ctrl] = nil
      end
    elseif core_step(mod, cx, ins) then
      -- handled
    elseif op == "block" then
      local p, r = bt_arity(mod, ins.bt); assert(p == 0, "block with params")
      ctrl[#ctrl + 1] = { kind = "block", height = cx.vsp, results = r, br_arity = r, target = ins.end_pc + 1 }
      if ins.end_pc + 1 <= n then labels[ins.end_pc + 1] = true end
    elseif op == "loop" then
      local p, r = bt_arity(mod, ins.bt); assert(p == 0, "loop with params")
      ctrl[#ctrl + 1] = { kind = "loop", height = cx.vsp, results = r, br_arity = 0, target = pc + 1 }
      labels[pc + 1] = true
    elseif op == "if" then
      local p, r = bt_arity(mod, ins.bt); assert(p == 0, "if with params")
      cx.setv(cx.vsp - 1)
      local cond = slot(cx.vsp)
      local fr = { kind = "if", height = cx.vsp, results = r, br_arity = r, target = ins.end_pc + 1 }
      ctrl[#ctrl + 1] = fr
      local F = ins.else_pc and (ins.else_pc + 1) or (ins.end_pc + 1)
      if F <= n then labels[F] = true end
      if ins.end_pc + 1 <= n then labels[ins.end_pc + 1] = true end
      if F == n + 1 then -- if at very end of body with no else: route via exit label
        need_exit = true; labels[n + 1] = true; exit_height = fr.height + fr.results
      end
      emit("if " .. cond .. " == 0 then " .. transfer(F) .. " end")
    elseif op == "else" then
      local fr = ctrl[#ctrl]
      emit(transfer(target_pc(fr)))
      leaf_term = true
      cx.setv(fr.height)
    elseif op == "end" then
      local fr = ctrl[#ctrl]; ctrl[#ctrl] = nil
      cx.setv(fr.height + fr.results)
    elseif op == "br" then
      local fr = resolve(ins.label)
      if not fr then
        for _, l in ipairs(return_lines(cx.vsp)) do emit(l) end
      else
        if yield and fr.kind == "loop" then emit(ref("__tick") .. "()") end
        for _, l in ipairs(move_lines(fr, cx.vsp)) do emit(l) end
        emit(transfer(target_pc(fr)))
      end
      leaf_term = true
      go_dead()
    elseif op == "br_if" then
      cx.setv(cx.vsp - 1)
      local cond = slot(cx.vsp)
      local fr = resolve(ins.label)
      if not fr then
        emit("if " .. cond .. " ~= 0 then " .. concat(return_lines(cx.vsp), " ") .. " end")
      else
        if yield and fr.kind == "loop" then emit(ref("__tick") .. "()") end
        local mv = move_lines(fr, cx.vsp)
        mv[#mv + 1] = transfer(target_pc(fr))
        emit("if " .. cond .. " ~= 0 then " .. concat(mv, " ") .. " end")
      end
    elseif op == "br_table" then
      cx.setv(cx.vsp - 1)
      local idx = slot(cx.vsp)
      -- determine arity: all targets must share it (wasm validation)
      local fr0 = resolve(ins.default)
      local keep = fr0 and fr0.br_arity or nres
      local anyret = not fr0
      for i = 1, #ins.targets do if not resolve(ins.targets[i]) then anyret = true end end
      if keep == 0 and not anyret and #ins.targets >= 8 then
        -- constant-time jump table
        local map = {}
        for i = 1, #ins.targets do map[i - 1] = target_pc(resolve(ins.targets[i])) end
        local def = target_pc(fr0)
        jts[#jts + 1] = { map = map, default = def, count = #ins.targets }
        local k = #jts
        emit("pc = JT[" .. k .. "][" .. idx .. "] or " .. def)
        local lo, hi = cur.seg * SEGSIZE, (cur.seg + 1) * SEGSIZE
        emit("if pc < " .. lo .. " or pc >= " .. hi .. " then return pc end")
        emit("break")
      else
        local parts = {}
        local function armstmt(d)
          local fr = resolve(d)
          if not fr then return concat(return_lines(cx.vsp), " ") end
          local mv = move_lines(fr, cx.vsp)
          mv[#mv + 1] = transfer(target_pc(fr))
          return concat(mv, " ")
        end
        for i = 1, #ins.targets do
          parts[#parts + 1] = ((i == 1) and "if " or "elseif ") .. idx .. " == " .. (i - 1) .. " then " .. armstmt(ins.targets[i])
        end
        if #parts == 0 then emit(armstmt(ins.default))
        else emit(concat(parts, "\n") .. "\nelse " .. armstmt(ins.default) .. "\nend") end
      end
      leaf_term = true
      go_dead()
    elseif op == "return" then
      for _, l in ipairs(return_lines(cx.vsp)) do emit(l) end
      leaf_term = true
      go_dead()
    elseif op == "unreachable" then
      emit(ref("__unreachable") .. "()")
      leaf_term = true
      go_dead()
    else
      error("transpiler: unhandled op " .. op)
    end
  end
  if not dead and not leaf_term then
    for _, l in ipairs(return_lines(cx.vsp)) do emit(l) end
  end
  if need_exit then
    newleaf(n + 1)
    for _, l in ipairs(return_lines(exit_height)) do emit(l) end
  end

  -- ---- assemble segments ----------------------------------------------------
  local segleaves = {}
  for s = 0, nsegs - 1 do segleaves[s] = {} end
  for _, lf in ipairs(leaves) do
    local t = segleaves[lf.seg]
    t[#t + 1] = lf
  end

  local out = { "local E = ..." }
  out[#out + 1] = "local mfloor = math.floor"
  hoist_lines(out, hlist)
  if #jts > 0 then
    out[#out + 1] = "local JT = {}"
    for k, jt in ipairs(jts) do
      local items = {}
      for i = 0, jt.count - 1 do items[#items + 1] = "[" .. i .. "]=" .. jt.map[i] end
      out[#out + 1] = "JT[" .. k .. "] = {" .. concat(items, ",") .. "}"
    end
  end

  local function build_tree(lst, lo, hi, push)
    if lo == hi then
      push(concat(lst[lo].lines, "\n"))
      return
    end
    local mid = floor((lo + hi + 1) / 2)
    push("if pc < " .. lst[mid].pc .. " then")
    build_tree(lst, lo, mid - 1, push)
    push("else")
    build_tree(lst, mid, hi, push)
    push("end")
  end

  for s = 0, nsegs - 1 do
    local lst = segleaves[s]
    if #lst == 0 then
      out[#out + 1] = "local seg" .. s .. " = function() return -1 end"
    else
      out[#out + 1] = "local seg" .. s .. " = function(pc, L, S)"
      out[#out + 1] = "while true do"
      if yield then out[#out + 1] = ref("__tick") .. "()" end
      out[#out + 1] = "repeat"
      build_tree(lst, 1, #lst, function(x) out[#out + 1] = x end)
      out[#out + 1] = "until true"
      out[#out + 1] = "end"
      out[#out + 1] = "end"
    end
  end
  do
    local t = {}
    for s = 0, nsegs - 1 do t[#t + 1] = "seg" .. s end
    out[#out + 1] = "local segt = {" .. concat(t, ", ") .. "}"
  end

  local params = {}
  for i = 0, nparams - 1 do params[i + 1] = "a" .. i end
  out[#out + 1] = "return function(" .. concat(params, ", ") .. ")"
  if nparams > 0 then
    out[#out + 1] = "local L = {[0] = " .. concat(params, ", ") .. "}"
  else
    out[#out + 1] = "local L = {}"
  end
  emit_local_init(function(x) out[#out + 1] = x end, ref, nparams, nlocals, locals_types)
  out[#out + 1] = "local S = {}"
  out[#out + 1] = "local pc = 1"
  out[#out + 1] = "while pc > 0 do"
  out[#out + 1] = "pc = segt[mfloor(pc / " .. SEGSIZE .. ") + 1](pc, L, S)"
  out[#out + 1] = "end"
  if nres > 0 then
    local t = {}
    for i = 1, nres do t[#t + 1] = "S[" .. i .. "]" end
    out[#out + 1] = "return " .. concat(t, ", ")
  end
  out[#out + 1] = "end"
  return concat(out, "\n")
end

-- =============================================================================
-- instantiation (mirrors compiler.instantiate; per-function: transpile_func,
-- else transpile_oversized, else interpreter fallback)
-- =============================================================================
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

-- M._force_transpile: never fall back to the interpreter (error loudly instead).
-- M._force_oversized: route everything through the flattened dispatcher path.
M._force_transpile = false
M._force_oversized = false

-- opts.chunk_cache: gi -> source string (or the marker "interp"), reused across
-- instances of the same module.
function M.instantiate(module, imports, opts)
  imports = imports or {}
  local chunk_cache = opts and opts.chunk_cache
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
  inst.fallbacks = {} -- gi -> true for functions that fell back to the interpreter

  local interp = require("interp")
  local iinst = { module = module, memory = inst.memory, globals = inst.globals,
                  tables = inst.tables, functions = {} }
  local function delegate(gi)
    return { type = functype_of(module, gi),
             host = function(a) return { inst.funcs[gi]((table.unpack or unpack)(a)) } end }
  end

  for i = 1, module.numImportedFuncs do
    local imp = module.importedFuncs[i]
    local host = imports[imp.module] and imports[imp.module][imp.name]
    if not host then error("missing import: " .. imp.module .. "." .. imp.name) end
    local gi = i - 1
    inst.funcs[gi] = function(...) return (table.unpack or unpack)(host({ ... }, inst) or {}) end
    iinst.functions[gi] = delegate(gi)
  end

  for j = 1, #module.funcTypeIdx do
    local gi = module.numImportedFuncs + (j - 1)
    iinst.functions[gi] = delegate(gi)
    inst.funcs[gi] = function(...)
      local function set_interp(why)
        if M._force_transpile then
          error("transpiler: fn#" .. gi .. " could not be transpiled: " .. tostring(why))
        end
        inst.fallbacks[gi] = true
        iinst.functions[gi] = { type = functype_of(module, gi), code = module.codes[j] }
        inst.funcs[gi] = function(...) return (table.unpack or unpack)(interp.run(iinst, gi, { ... })) end
      end
      local cached = chunk_cache and chunk_cache[gi]
      if cached == "interp" then
        set_interp("cached interp marker")
      elseif cached then
        inst.funcs[gi] = assert(loader(cached, "wasmfn#" .. gi))(ENV)
      else
        local src, why
        if M._force_oversized then
          local ok, c = pcall(M.transpile_oversized, module, j)
          if ok then src = c else why = c end
        else
          local ok, c = pcall(M.transpile_func, module, j)
          if ok then src = c else
            local ok2, c2 = pcall(M.transpile_oversized, module, j)
            if ok2 then src = c2 else why = tostring(c) .. " / " .. tostring(c2) end
          end
        end
        local fn
        if src then
          local okl, f = pcall(loader, src, "wasmfn#" .. gi)
          if okl and f then
            local okr, made = pcall(f, ENV)
            if okr then fn = made else why = made end
          else
            why = f
          end
        end
        if fn then
          if chunk_cache then chunk_cache[gi] = src end
          inst.funcs[gi] = fn
        else
          if chunk_cache then chunk_cache[gi] = "interp" end
          set_interp(why)
        end
      end
      return inst.funcs[gi](...)
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
