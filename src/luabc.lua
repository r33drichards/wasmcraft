-- Lua 5.1 bytecode emitter (pure Lua). Builds a binary chunk that Cobalt's
-- BytecodeLoader accepts: little-endian, sizeof int/size_t/instruction = 4,
-- numbers = 8-byte doubles. See docs/plans/2026-06-09-wasm-to-cobalt-bytecode-*.
local spack = string.pack
local M = {}

local function u8(n) return string.char(n % 256) end
local function u32(n) return spack("<I4", n % 4294967296) end
local function dbl(x) return spack("<d", x) end
local function lstr(s) if s == nil then return u32(0) end return u32(#s + 1) .. s .. "\0" end

-- instruction layout: op[0:6] A[6:14] C[14:23] B[23:32]; Bx[14:32]; sBx biased +131071
local function iABC(op, a, b, c) return u32(op + a * 64 + c * 16384 + b * 8388608) end
local function iABx(op, a, bx) return u32(op + a * 64 + bx * 16384) end
local function iAsBx(op, a, sbx) return iABx(op, a, sbx + 131071) end

local OP = {
  MOVE = 0, LOADK = 1, LOADBOOL = 2, LOADNIL = 3, GETUPVAL = 4, GETGLOBAL = 5,
  GETTABLE = 6, SETGLOBAL = 7, SETUPVAL = 8, SETTABLE = 9, NEWTABLE = 10,
  ADD = 12, SUB = 13, MUL = 14, DIV = 15, MOD = 16, POW = 17, UNM = 18, NOT = 19,
  JMP = 22, EQ = 23, LT = 24, LE = 25, TEST = 26, CALL = 28, RETURN = 30,
  CLOSURE = 36,
}
M.OP = OP

local function RK(k) return k + 256 end -- constant operand encoding
M.RK = RK

local HEADER = string.char(0x1b, 0x4c, 0x75, 0x61, 0x51, 0, 1, 4, 4, 4, 8, 0)
M.HEADER = HEADER

-- ---- function builder ----------------------------------------------------
local FB = {}
FB.__index = FB

function M.func(nparams, nups)
  return setmetatable({
    nparams = nparams, nups = nups or 0,
    code = {}, consts = {}, kmap = {}, children = {},
    maxstack = nparams, jumps = {},
  }, FB)
end

function FB:use(r) if r + 1 > self.maxstack then self.maxstack = r + 1 end end

function FB:knum(x)
  local key = "n:" .. tostring(x)
  local i = self.kmap[key]; if i then return i end
  self.consts[#self.consts + 1] = u8(3) .. dbl(x); i = #self.consts - 1; self.kmap[key] = i; return i
end
function FB:kstr(s)
  local key = "s:" .. s
  local i = self.kmap[key]; if i then return i end
  self.consts[#self.consts + 1] = u8(4) .. lstr(s); i = #self.consts - 1; self.kmap[key] = i; return i
end
function FB:kbool(b)
  local key = "b:" .. tostring(b)
  local i = self.kmap[key]; if i then return i end
  self.consts[#self.consts + 1] = u8(1) .. u8(b and 1 or 0); i = #self.consts - 1; self.kmap[key] = i; return i
end

function FB:_emit(word) self.code[#self.code + 1] = word; return #self.code end

-- instruction emitters (track maxstack on destination/source registers)
function FB:MOVE(a, b) self:use(a); self:use(b); return self:_emit(iABC(OP.MOVE, a, b, 0)) end
function FB:LOADK(a, k) self:use(a); return self:_emit(iABx(OP.LOADK, a, k)) end
function FB:LOADBOOL(a, b, c) self:use(a); return self:_emit(iABC(OP.LOADBOOL, a, b, c)) end
function FB:LOADNIL(a, b) self:use(a); self:use(b); return self:_emit(iABC(OP.LOADNIL, a, b, 0)) end
function FB:GETUPVAL(a, b) self:use(a); return self:_emit(iABC(OP.GETUPVAL, a, b, 0)) end
function FB:GETGLOBAL(a, k) self:use(a); return self:_emit(iABx(OP.GETGLOBAL, a, k)) end
function FB:GETTABLE(a, b, c) self:use(a); self:use(b); return self:_emit(iABC(OP.GETTABLE, a, b, c)) end
function FB:SETTABLE(a, b, c) self:use(a); return self:_emit(iABC(OP.SETTABLE, a, b, c)) end
function FB:NEWTABLE(a, b, c) self:use(a); return self:_emit(iABC(OP.NEWTABLE, a, b, c)) end
function FB:ARITH(op, a, b, c) self:use(a); return self:_emit(iABC(op, a, b, c)) end
function FB:UNM(a, b) self:use(a); self:use(b); return self:_emit(iABC(OP.UNM, a, b, 0)) end
function FB:CALL(a, b, c) self:use(a); return self:_emit(iABC(OP.CALL, a, b, c)) end
function FB:RETURN(a, b) return self:_emit(iABC(OP.RETURN, a, b, 0)) end
function FB:CLOSURE(a, bx) self:use(a); return self:_emit(iABx(OP.CLOSURE, a, bx)) end
function FB:EQ(a, b, c) return self:_emit(iABC(OP.EQ, a, b, c)) end
function FB:LT(a, b, c) return self:_emit(iABC(OP.LT, a, b, c)) end
function FB:LE(a, b, c) return self:_emit(iABC(OP.LE, a, b, c)) end
function FB:TEST(a, c) return self:_emit(iABC(OP.TEST, a, 0, c)) end

-- labels & jumps
function FB:label() return { target = nil } end
function FB:place(L) L.target = #self.code + 1 end
function FB:jmp(L) local pos = self:_emit(iAsBx(OP.JMP, 0, 0)); self.jumps[#self.jumps + 1] = { pos = pos, label = L }; return pos end

function FB:add_child(bytes) self.children[#self.children + 1] = bytes; return #self.children - 1 end

function FB:build()
  -- resolve jumps
  for _, j in ipairs(self.jumps) do
    assert(j.label.target, "unresolved jump label")
    self.code[j.pos] = iAsBx(OP.JMP, 0, j.label.target - j.pos - 1)
  end
  local p = { lstr(nil), u32(0), u32(0), u8(self.nups), u8(self.nparams), u8(0), u8(self.maxstack), u32(#self.code) }
  for _, c in ipairs(self.code) do p[#p + 1] = c end
  p[#p + 1] = u32(#self.consts); for _, k in ipairs(self.consts) do p[#p + 1] = k end
  p[#p + 1] = u32(#self.children); for _, ch in ipairs(self.children) do p[#p + 1] = ch end
  p[#p + 1] = u32(0); p[#p + 1] = u32(0); p[#p + 1] = u32(0) -- lineInfo, locals, upvalNames
  return table.concat(p)
end

-- Wrap a wasm-function builder (which uses exactly 1 upvalue = ENV) in a factory
-- proto: function(ENV) return <closure of wasmfn capturing ENV> end.
-- Returns the full loadable chunk. loadstring(chunk)(ENV) -> the wasm function.
function M.loadable(wasmfn)
  local child = wasmfn:build()
  local fac = M.func(1, 0) -- param0 = ENV
  local idx = fac:add_child(child)
  fac:CLOSURE(1, idx)              -- R1 = closure(child)
  fac:_emit(iABC(OP.MOVE, 0, 0, 0)) -- upvalue binding: upval0 := parent R0 (ENV)
  fac:RETURN(1, 2)                 -- return R1
  fac:RETURN(0, 1)
  return HEADER .. fac:build()
end

return M
