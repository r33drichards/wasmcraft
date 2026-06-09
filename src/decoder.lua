-- WebAssembly binary module decoder.
-- Decodes the binary format (https://webassembly.github.io/spec/core/bikeshed/#binary-format)
-- into Lua tables. Grows per milestone; currently: type/function/export/code sections plus
-- generic skipping of the rest.
local Reader = require("leb")

local M = {}

local VALTYPE = {
  [0x7f] = "i32", [0x7e] = "i64", [0x7d] = "f32", [0x7c] = "f64",
  [0x7b] = "v128",
  [0x70] = "funcref", [0x6f] = "externref",
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

-- ---- instruction (expression) decoding ----------------------------------
-- Emits a flat list of {op=name, ...operands}. Block-structured control is
-- represented with explicit block/loop/if/else/end markers for a later pass.

local decodeBody  -- fwd

-- operand readers keyed by opcode; returns an instruction table.
local OPS = {
  [0x00] = function() return { op = "unreachable" } end,
  [0x01] = function() return { op = "nop" } end,
  [0x0f] = function() return { op = "return" } end,
  [0x20] = function(r) return { op = "local.get", x = r:u_leb() } end,
  [0x21] = function(r) return { op = "local.set", x = r:u_leb() } end,
  [0x22] = function(r) return { op = "local.tee", x = r:u_leb() } end,
  [0x41] = function(r) return { op = "i32.const", v = r:s_leb() } end,
  [0x6a] = function() return { op = "i32.add" } end,
}

decodeBody = function(r)
  local instrs = {}
  while true do
    local op = r:byte()
    if op == 0x0b then break end -- end of this expression
    local f = OPS[op]
    if not f then error(string.format("unimplemented opcode 0x%02x at byte %d", op, r.pos - 1)) end
    instrs[#instrs + 1] = f(r)
  end
  return instrs
end

M.decodeBody = decodeBody
M.OPS = OPS

-- ---- section decoders ----------------------------------------------------

local function decodeTypes(r)
  return vec(r, function(rr)
    local form = rr:byte()
    if form ~= 0x60 then error(string.format("expected functype 0x60, got 0x%02x", form)) end
    local params = vec(rr, valtype)
    local results = vec(rr, valtype)
    return { params = params, results = results }
  end)
end

local function decodeFunctions(r)
  return vec(r, function(rr) return rr:u_leb() end) -- type indices (0-based)
end

local EXPORT_KIND = { [0] = "func", [1] = "table", [2] = "mem", [3] = "global" }

local function decodeExports(r)
  local out = {}
  local n = r:u_leb()
  for _ = 1, n do
    local nameLen = r:u_leb()
    local name = r:bytes(nameLen)
    local kind = EXPORT_KIND[r:byte()]
    local index = r:u_leb()
    out[name] = { kind = kind, index = index }
  end
  return out
end

local function decodeCode(r)
  return vec(r, function(rr)
    local size = rr:u_leb()
    local endPos = rr.pos + size
    -- locals: vec of (count, valtype), expanded into a flat list
    local locals = {}
    local nDecl = rr:u_leb()
    for _ = 1, nDecl do
      local count = rr:u_leb()
      local t = valtype(rr)
      for _ = 1, count do locals[#locals + 1] = t end
    end
    local body = decodeBody(rr)
    rr.pos = endPos -- be robust to trailing bytes
    return { locals = locals, body = body }
  end)
end

-- ---- top-level -----------------------------------------------------------

function M.load(bytes)
  local r = Reader.new(bytes)
  local magic = r:bytes(4)
  if magic ~= "\0asm" then error("bad magic: not a wasm module") end
  local version = r:u32()
  if version ~= 1 then error("unsupported wasm version " .. version) end

  local mod = {
    types = {}, funcTypeIdx = {}, exports = {}, codes = {},
    numImportedFuncs = 0,
  }

  while not r:eof() do
    local id = r:byte()
    local len = r:u_leb()
    local secEnd = r.pos + len
    if id == 1 then
      mod.types = decodeTypes(r)
    elseif id == 3 then
      mod.funcTypeIdx = decodeFunctions(r)
    elseif id == 7 then
      mod.exports = decodeExports(r)
    elseif id == 10 then
      mod.codes = decodeCode(r)
    else
      -- custom(0) and not-yet-handled sections: skip by length
    end
    r.pos = secEnd
  end

  return mod
end

return M
