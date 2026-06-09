-- WebAssembly binary module decoder.
-- https://webassembly.github.io/spec/core/bikeshed/#binary-format
local Reader = require("leb")

local M = {}

local VALTYPE = {
  [0x7f] = "i32", [0x7e] = "i64", [0x7d] = "f32", [0x7c] = "f64",
  [0x7b] = "v128", [0x70] = "funcref", [0x6f] = "externref",
}

local function valtype(r)
  local b = r:byte()
  local t = VALTYPE[b]
  if not t then error(string.format("unknown valtype 0x%02x", b)) end
  return t
end

local function vec(r, f)
  local n = r:u_leb()
  local out = {}
  for i = 1, n do out[i] = f(r) end
  return out
end

-- block type: empty / single valtype / type index (s33)
local BT = { [-64] = "empty", [-1] = "i32", [-2] = "i64", [-3] = "f32", [-4] = "f64",
             [-5] = "v128", [-16] = "funcref", [-17] = "externref" }
local function blocktype(r)
  local v = r:s_leb()
  if v < 0 then
    local t = BT[v]
    if not t then error("bad blocktype " .. v) end
    if t == "empty" then return { params = {}, results = {} } end
    return { params = {}, results = { t } }
  end
  return { typeidx = v } -- resolved against module.types at runtime
end

local function memarg(r)
  local align = r:u_leb()
  local offset = r:u_leb()
  return align, offset
end

-- ---- instruction decoding ------------------------------------------------

local function simple(name) return function() return { op = name } end end
local function lebop(name, field)
  field = field or "x"
  return function(r) local t = { op = name }; t[field] = r:u_leb(); return t end
end
local function loadop(name) return function(r) local a, o = memarg(r); return { op = name, offset = o } end end
local storeop = loadop

local OPS = {}
M.OPS = OPS

-- control
OPS[0x00] = simple("unreachable")
OPS[0x01] = simple("nop")
OPS[0x02] = function(r) return { op = "block", bt = blocktype(r) } end
OPS[0x03] = function(r) return { op = "loop", bt = blocktype(r) } end
OPS[0x04] = function(r) return { op = "if", bt = blocktype(r) } end
OPS[0x05] = simple("else")
OPS[0x0c] = lebop("br", "label")
OPS[0x0d] = lebop("br_if", "label")
OPS[0x0e] = function(r)
  local targets = vec(r, function(rr) return rr:u_leb() end)
  local default = r:u_leb()
  return { op = "br_table", targets = targets, default = default }
end
OPS[0x0f] = simple("return")
OPS[0x10] = lebop("call", "func")
OPS[0x11] = function(r)
  local typeidx = r:u_leb()
  local tableidx = r:u_leb()
  return { op = "call_indirect", typeidx = typeidx, table = tableidx }
end

-- parametric
OPS[0x1a] = simple("drop")
OPS[0x1b] = simple("select")
OPS[0x1c] = function(r) vec(r, valtype); return { op = "select" } end -- typed select

-- variable
OPS[0x20] = lebop("local.get")
OPS[0x21] = lebop("local.set")
OPS[0x22] = lebop("local.tee")
OPS[0x23] = lebop("global.get")
OPS[0x24] = lebop("global.set")

-- memory loads/stores
local LOADS = {
  [0x28] = "i32.load", [0x29] = "i64.load", [0x2a] = "f32.load", [0x2b] = "f64.load",
  [0x2c] = "i32.load8_s", [0x2d] = "i32.load8_u", [0x2e] = "i32.load16_s", [0x2f] = "i32.load16_u",
  [0x30] = "i64.load8_s", [0x31] = "i64.load8_u", [0x32] = "i64.load16_s", [0x33] = "i64.load16_u",
  [0x34] = "i64.load32_s", [0x35] = "i64.load32_u",
}
local STORES = {
  [0x36] = "i32.store", [0x37] = "i64.store", [0x38] = "f32.store", [0x39] = "f64.store",
  [0x3a] = "i32.store8", [0x3b] = "i32.store16",
  [0x3c] = "i64.store8", [0x3d] = "i64.store16", [0x3e] = "i64.store32",
}
for code, name in pairs(LOADS) do OPS[code] = loadop(name) end
for code, name in pairs(STORES) do OPS[code] = storeop(name) end
OPS[0x3f] = function(r) r:byte(); return { op = "memory.size" } end
OPS[0x40] = function(r) r:byte(); return { op = "memory.grow" } end

-- consts
OPS[0x41] = function(r) return { op = "i32.const", v = r:s_leb() } end
OPS[0x42] = function(r) return { op = "i64.const", raw = r } end -- placeholder; replaced below
OPS[0x43] = function(r) return { op = "f32.const", v = r:f32() } end
OPS[0x44] = function(r) return { op = "f64.const", v = r:f64() } end

-- numeric ops with no immediates
local NULLARY = {
  -- i32 comparisons
  [0x45] = "i32.eqz", [0x46] = "i32.eq", [0x47] = "i32.ne",
  [0x48] = "i32.lt_s", [0x49] = "i32.lt_u", [0x4a] = "i32.gt_s", [0x4b] = "i32.gt_u",
  [0x4c] = "i32.le_s", [0x4d] = "i32.le_u", [0x4e] = "i32.ge_s", [0x4f] = "i32.ge_u",
  -- i64 comparisons
  [0x50] = "i64.eqz", [0x51] = "i64.eq", [0x52] = "i64.ne",
  [0x53] = "i64.lt_s", [0x54] = "i64.lt_u", [0x55] = "i64.gt_s", [0x56] = "i64.gt_u",
  [0x57] = "i64.le_s", [0x58] = "i64.le_u", [0x59] = "i64.ge_s", [0x5a] = "i64.ge_u",
  -- f32 comparisons
  [0x5b] = "f32.eq", [0x5c] = "f32.ne", [0x5d] = "f32.lt", [0x5e] = "f32.gt", [0x5f] = "f32.le", [0x60] = "f32.ge",
  -- f64 comparisons
  [0x61] = "f64.eq", [0x62] = "f64.ne", [0x63] = "f64.lt", [0x64] = "f64.gt", [0x65] = "f64.le", [0x66] = "f64.ge",
  -- i32 arithmetic
  [0x67] = "i32.clz", [0x68] = "i32.ctz", [0x69] = "i32.popcnt",
  [0x6a] = "i32.add", [0x6b] = "i32.sub", [0x6c] = "i32.mul",
  [0x6d] = "i32.div_s", [0x6e] = "i32.div_u", [0x6f] = "i32.rem_s", [0x70] = "i32.rem_u",
  [0x71] = "i32.and", [0x72] = "i32.or", [0x73] = "i32.xor",
  [0x74] = "i32.shl", [0x75] = "i32.shr_s", [0x76] = "i32.shr_u", [0x77] = "i32.rotl", [0x78] = "i32.rotr",
  -- i64 arithmetic
  [0x79] = "i64.clz", [0x7a] = "i64.ctz", [0x7b] = "i64.popcnt",
  [0x7c] = "i64.add", [0x7d] = "i64.sub", [0x7e] = "i64.mul",
  [0x7f] = "i64.div_s", [0x80] = "i64.div_u", [0x81] = "i64.rem_s", [0x82] = "i64.rem_u",
  [0x83] = "i64.and", [0x84] = "i64.or", [0x85] = "i64.xor",
  [0x86] = "i64.shl", [0x87] = "i64.shr_s", [0x88] = "i64.shr_u", [0x89] = "i64.rotl", [0x8a] = "i64.rotr",
  -- f32 arithmetic
  [0x8b] = "f32.abs", [0x8c] = "f32.neg", [0x8d] = "f32.ceil", [0x8e] = "f32.floor", [0x8f] = "f32.trunc",
  [0x90] = "f32.nearest", [0x91] = "f32.sqrt", [0x92] = "f32.add", [0x93] = "f32.sub", [0x94] = "f32.mul",
  [0x95] = "f32.div", [0x96] = "f32.min", [0x97] = "f32.max", [0x98] = "f32.copysign",
  -- f64 arithmetic
  [0x99] = "f64.abs", [0x9a] = "f64.neg", [0x9b] = "f64.ceil", [0x9c] = "f64.floor", [0x9d] = "f64.trunc",
  [0x9e] = "f64.nearest", [0x9f] = "f64.sqrt", [0xa0] = "f64.add", [0xa1] = "f64.sub", [0xa2] = "f64.mul",
  [0xa3] = "f64.div", [0xa4] = "f64.min", [0xa5] = "f64.max", [0xa6] = "f64.copysign",
  -- conversions
  [0xa7] = "i32.wrap_i64",
  [0xa8] = "i32.trunc_f32_s", [0xa9] = "i32.trunc_f32_u", [0xaa] = "i32.trunc_f64_s", [0xab] = "i32.trunc_f64_u",
  [0xac] = "i64.extend_i32_s", [0xad] = "i64.extend_i32_u",
  [0xae] = "i64.trunc_f32_s", [0xaf] = "i64.trunc_f32_u", [0xb0] = "i64.trunc_f64_s", [0xb1] = "i64.trunc_f64_u",
  [0xb2] = "f32.convert_i32_s", [0xb3] = "f32.convert_i32_u", [0xb4] = "f32.convert_i64_s", [0xb5] = "f32.convert_i64_u",
  [0xb6] = "f32.demote_f64",
  [0xb7] = "f64.convert_i32_s", [0xb8] = "f64.convert_i32_u", [0xb9] = "f64.convert_i64_s", [0xba] = "f64.convert_i64_u",
  [0xbb] = "f64.promote_f32",
  [0xbc] = "i32.reinterpret_f32", [0xbd] = "i64.reinterpret_f64",
  [0xbe] = "f32.reinterpret_i32", [0xbf] = "f64.reinterpret_i64",
  -- sign extension
  [0xc0] = "i32.extend8_s", [0xc1] = "i32.extend16_s",
  [0xc2] = "i64.extend8_s", [0xc3] = "i64.extend16_s", [0xc4] = "i64.extend32_s",
}
for code, name in pairs(NULLARY) do OPS[code] = simple(name) end

-- reference types
OPS[0xd0] = function(r) valtype(r); return { op = "ref.null" } end
OPS[0xd1] = simple("ref.is_null")
OPS[0xd2] = lebop("ref.func", "func")

-- 0xfc prefix: bulk memory + saturating truncation
local FC = {
  [0] = "i32.trunc_sat_f32_s", [1] = "i32.trunc_sat_f32_u",
  [2] = "i32.trunc_sat_f64_s", [3] = "i32.trunc_sat_f64_u",
  [4] = "i64.trunc_sat_f32_s", [5] = "i64.trunc_sat_f32_u",
  [6] = "i64.trunc_sat_f64_s", [7] = "i64.trunc_sat_f64_u",
}
OPS[0xfc] = function(r)
  local sub = r:u_leb()
  local name = FC[sub]
  if name then return { op = name } end
  if sub == 8 then local d = r:u_leb(); r:byte(); return { op = "memory.init", data = d } end
  if sub == 9 then return { op = "data.drop", data = r:u_leb() } end
  if sub == 10 then r:byte(); r:byte(); return { op = "memory.copy" } end
  if sub == 11 then r:byte(); return { op = "memory.fill" } end
  if sub == 12 then local e = r:u_leb(); local t = r:u_leb(); return { op = "table.init", elem = e, table = t } end
  if sub == 13 then return { op = "elem.drop", elem = r:u_leb() } end
  if sub == 14 then local a = r:u_leb(); local b = r:u_leb(); return { op = "table.copy", dst = a, src = b } end
  if sub == 15 then return { op = "table.grow", table = r:u_leb() } end
  if sub == 16 then return { op = "table.size", table = r:u_leb() } end
  if sub == 17 then return { op = "table.fill", table = r:u_leb() } end
  error("unimplemented 0xfc subop " .. sub)
end

-- i64.const needs an i64 value; decode raw little-endian via signed LEB into {h,l}.
-- We import int64 lazily to avoid a cycle at module load.
local int64
OPS[0x42] = function(r)
  int64 = int64 or require("int64")
  return { op = "i64.const", v = int64.read_sleb(r) }
end

-- Decode an expression body into a flat instruction list, linking block/loop/if
-- to their matching else/end so branches resolve in O(1).
local function decodeBody(r)
  local instrs = {}
  local depth = 0
  while true do
    local op = r:byte()
    if op == 0x0b then -- end
      if depth == 0 then break end
      depth = depth - 1
      instrs[#instrs + 1] = { op = "end" }
    else
      local f = OPS[op]
      if not f then error(string.format("unimplemented opcode 0x%02x at byte %d", op, r.pos - 1)) end
      local ins = f(r)
      if ins.op == "block" or ins.op == "loop" or ins.op == "if" then depth = depth + 1 end
      instrs[#instrs + 1] = ins
    end
  end
  -- link control structures
  local stack = {}
  for i = 1, #instrs do
    local o = instrs[i].op
    if o == "block" or o == "loop" or o == "if" then
      stack[#stack + 1] = i
    elseif o == "else" then
      instrs[stack[#stack]].else_pc = i
      instrs[i].opener = stack[#stack]
    elseif o == "end" then
      local j = stack[#stack]; stack[#stack] = nil
      instrs[j].end_pc = i
      instrs[i].opener = j
    end
  end
  -- resolve else markers' end_pc (jump target when then-branch falls through)
  for i = 1, #instrs do
    if instrs[i].op == "else" then
      instrs[i].end_pc = instrs[instrs[i].opener].end_pc
    end
  end
  return instrs
end
M.decodeBody = decodeBody

-- A constant expression (used by globals/elem/data offsets): same decoder.
local function decodeConstExpr(r) return decodeBody(r) end

-- ---- sections ------------------------------------------------------------

local function decodeTypes(r)
  return vec(r, function(rr)
    local form = rr:byte()
    if form ~= 0x60 then error(string.format("expected functype 0x60, got 0x%02x", form)) end
    return { params = vec(rr, valtype), results = vec(rr, valtype) }
  end)
end

local function limits(r)
  local flag = r:byte()
  local min = r:u_leb()
  local max = nil
  if flag == 1 then max = r:u_leb() end
  return min, max
end

local function decodeImports(r, mod)
  return vec(r, function(rr)
    local mlen = rr:u_leb(); local module = rr:bytes(mlen)
    local nlen = rr:u_leb(); local name = rr:bytes(nlen)
    local kind = rr:byte()
    local imp = { module = module, name = name }
    if kind == 0 then
      imp.kind = "func"; imp.typeidx = rr:u_leb(); mod.numImportedFuncs = mod.numImportedFuncs + 1
      mod.importedFuncs[#mod.importedFuncs + 1] = imp
    elseif kind == 1 then
      imp.kind = "table"; local et = valtype(rr); local mn, mx = limits(rr); imp.min = mn; imp.max = mx
    elseif kind == 2 then
      imp.kind = "mem"; local mn, mx = limits(rr); imp.min = mn; imp.max = mx; mod.importedMem = imp
    elseif kind == 3 then
      imp.kind = "global"; imp.valtype = valtype(rr); imp.mut = rr:byte(); mod.numImportedGlobals = mod.numImportedGlobals + 1
    else error("bad import kind " .. kind) end
    return imp
  end)
end

local function decodeFunctions(r) return vec(r, function(rr) return rr:u_leb() end) end

local function decodeTables(r)
  return vec(r, function(rr)
    local et = valtype(rr)
    local mn, mx = limits(rr)
    return { elemtype = et, min = mn, max = mx }
  end)
end

local function decodeMemories(r)
  return vec(r, function(rr)
    local mn, mx = limits(rr)
    return { min = mn, max = mx }
  end)
end

local function decodeGlobals(r)
  return vec(r, function(rr)
    local vt = valtype(rr)
    local mut = rr:byte()
    local init = decodeConstExpr(rr)
    return { valtype = vt, mut = mut, init = init }
  end)
end

local EXPORT_KIND = { [0] = "func", [1] = "table", [2] = "mem", [3] = "global" }
local function decodeExports(r)
  local out = {}
  local n = r:u_leb()
  for _ = 1, n do
    local nameLen = r:u_leb()
    local name = r:bytes(nameLen)
    local kind = EXPORT_KIND[r:byte()]
    out[name] = { kind = kind, index = r:u_leb() }
  end
  return out
end

local function decodeElements(r)
  return vec(r, function(rr)
    local flag = rr:u_leb()
    -- Support the common encodings emitted by LLVM/wabt.
    if flag == 0 then
      -- active, table 0, offset expr, vec funcidx
      local offset = decodeConstExpr(rr)
      local funcs = vec(rr, function(x) return x:u_leb() end)
      return { mode = "active", table = 0, offset = offset, funcs = funcs }
    elseif flag == 1 then
      rr:byte() -- elemkind (0 = funcref)
      local funcs = vec(rr, function(x) return x:u_leb() end)
      return { mode = "passive", funcs = funcs }
    elseif flag == 2 then
      local tbl = rr:u_leb()
      local offset = decodeConstExpr(rr)
      rr:byte() -- elemkind
      local funcs = vec(rr, function(x) return x:u_leb() end)
      return { mode = "active", table = tbl, offset = offset, funcs = funcs }
    elseif flag == 3 then
      rr:byte()
      local funcs = vec(rr, function(x) return x:u_leb() end)
      return { mode = "declarative", funcs = funcs }
    else
      error("unsupported elem segment flag " .. flag)
    end
  end)
end

local function decodeData(r)
  return vec(r, function(rr)
    local flag = rr:u_leb()
    if flag == 0 then
      local offset = decodeConstExpr(rr)
      local len = rr:u_leb()
      return { mode = "active", memory = 0, offset = offset, bytes = rr:bytes(len) }
    elseif flag == 1 then
      local len = rr:u_leb()
      return { mode = "passive", bytes = rr:bytes(len) }
    elseif flag == 2 then
      local mem = rr:u_leb()
      local offset = decodeConstExpr(rr)
      local len = rr:u_leb()
      return { mode = "active", memory = mem, offset = offset, bytes = rr:bytes(len) }
    else
      error("unsupported data segment flag " .. flag)
    end
  end)
end

-- ---- top-level -----------------------------------------------------------

local function decodeCodeSection(r)
  return vec(r, function(rr)
    local size = rr:u_leb()
    local endPos = rr.pos + size
    local locals = {}
    local nDecl = rr:u_leb()
    for _ = 1, nDecl do
      local count = rr:u_leb()
      local t = valtype(rr)
      for _ = 1, count do locals[#locals + 1] = t end
    end
    local body = decodeBody(rr)
    rr.pos = endPos
    return { locals = locals, body = body }
  end)
end

function M.load(bytes)
  local r = Reader.new(bytes)
  if r:bytes(4) ~= "\0asm" then error("bad magic: not a wasm module") end
  local version = r:u32()
  if version ~= 1 then error("unsupported wasm version " .. version) end

  local mod = {
    types = {}, imports = {}, importedFuncs = {}, importedMem = nil,
    numImportedFuncs = 0, numImportedGlobals = 0,
    funcTypeIdx = {}, tables = {}, memories = {}, globals = {},
    exports = {}, elements = {}, datas = {}, codes = {}, start = nil,
  }

  while not r:eof() do
    local id = r:byte()
    local len = r:u_leb()
    local secEnd = r.pos + len
    if id == 1 then mod.types = decodeTypes(r)
    elseif id == 2 then mod.imports = decodeImports(r, mod)
    elseif id == 3 then mod.funcTypeIdx = decodeFunctions(r)
    elseif id == 4 then mod.tables = decodeTables(r)
    elseif id == 5 then mod.memories = decodeMemories(r)
    elseif id == 6 then mod.globals = decodeGlobals(r)
    elseif id == 7 then mod.exports = decodeExports(r)
    elseif id == 8 then mod.start = r:u_leb()
    elseif id == 9 then mod.elements = decodeElements(r)
    elseif id == 10 then mod.codes = decodeCodeSection(r)
    elseif id == 11 then mod.datas = decodeData(r)
    else
      -- custom(0), datacount(12), and anything else: skip by length
    end
    r.pos = secEnd
  end

  return mod
end

return M
