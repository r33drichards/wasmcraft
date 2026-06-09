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
    maxstack = nparams, jumps = {}, anchors = {},
  }, FB)
end

-- Mark a trampoline-insertion point: the position right AFTER an unconditional
-- control transfer (br/br_table/return/unreachable). Code there is never reached
-- by fall-through, so build_relaxed() may splice trampoline JMPs in. No-op for
-- the normal (single-function) build path.
function FB:anchor() self.anchors[#self.anchors + 1] = #self.code + 1 end

function FB:use(r) if r + 1 > self.maxstack then self.maxstack = r + 1 end end
-- track a register operand that may be an RK-encoded constant (>=256 -> ignore)
function FB:usek(r) if r < 256 and r + 1 > self.maxstack then self.maxstack = r + 1 end end

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
function FB:GETTABLE(a, b, c) self:use(a); self:use(b); self:usek(c); return self:_emit(iABC(OP.GETTABLE, a, b, c)) end
function FB:SETTABLE(a, b, c) self:use(a); self:usek(b); self:usek(c); return self:_emit(iABC(OP.SETTABLE, a, b, c)) end
function FB:NEWTABLE(a, b, c) self:use(a); return self:_emit(iABC(OP.NEWTABLE, a, b, c)) end
function FB:ARITH(op, a, b, c) self:use(a); self:usek(b); self:usek(c); return self:_emit(iABC(op, a, b, c)) end
function FB:UNM(a, b) self:use(a); self:use(b); return self:_emit(iABC(OP.UNM, a, b, 0)) end
function FB:CALL(a, b, c) self:use(a); return self:_emit(iABC(OP.CALL, a, b, c)) end
function FB:RETURN(a, b) return self:_emit(iABC(OP.RETURN, a, b, 0)) end
function FB:CLOSURE(a, bx) self:use(a); return self:_emit(iABx(OP.CLOSURE, a, bx)) end
function FB:EQ(a, b, c) self:usek(b); self:usek(c); return self:_emit(iABC(OP.EQ, a, b, c)) end
function FB:LT(a, b, c) self:usek(b); self:usek(c); return self:_emit(iABC(OP.LT, a, b, c)) end
function FB:LE(a, b, c) self:usek(b); self:usek(c); return self:_emit(iABC(OP.LE, a, b, c)) end
function FB:TEST(a, c) return self:_emit(iABC(OP.TEST, a, 0, c)) end

-- labels & jumps
function FB:label() return { target = nil } end
function FB:place(L) L.target = #self.code + 1 end
function FB:jmp(L) local pos = self:_emit(iAsBx(OP.JMP, 0, 0)); self.jumps[#self.jumps + 1] = { pos = pos, label = L }; return pos end

function FB:add_child(bytes) self.children[#self.children + 1] = bytes; return #self.children - 1 end

function FB:build()
  -- resolve jumps; bail if any exceeds Lua's 18-bit sBx range (the function is
  -- too large to compile to a single Lua function -> caller falls back to interp)
  for _, j in ipairs(self.jumps) do
    assert(j.label.target, "unresolved jump label")
    local sbx = j.label.target - j.pos - 1
    if sbx > 131071 or sbx < -131071 then error("function too large: jump out of range") end
    self.code[j.pos] = iAsBx(OP.JMP, 0, sbx)
  end
  local p = { lstr(nil), u32(0), u32(0), u8(self.nups), u8(self.nparams), u8(0), u8(self.maxstack), u32(#self.code) }
  for _, c in ipairs(self.code) do p[#p + 1] = c end
  p[#p + 1] = u32(#self.consts); for _, k in ipairs(self.consts) do p[#p + 1] = k end
  p[#p + 1] = u32(#self.children); for _, ch in ipairs(self.children) do p[#p + 1] = ch end
  p[#p + 1] = u32(0); p[#p + 1] = u32(0); p[#p + 1] = u32(0) -- lineInfo, locals, upvalNames
  return table.concat(p)
end

-- ---- branch relaxation (trampolines) ------------------------------------
-- For functions whose jumps exceed Lua's 18-bit sBx range, reroute the too-far
-- jumps through trampoline JMPs spliced into dead-code anchor slots. Positions
-- shift as trampolines are inserted, so we iterate to a fixed point. The result
-- is the same proto as build(), only with relaxed jumps; semantics identical.
function FB:build_relaxed()
  local code = self.code
  local N = #code
  local MAX = M.RELAX_MAX or 130000 -- safe jump magnitude (limit 131071; margin)

  -- jumps[].pos = original index of a JMP word; jumps[].label.target = original
  -- index it targets. Map pos -> jump record for fast lookup during emission.
  local jumpByPos = {}
  for _, j in ipairs(self.jumps) do
    assert(j.label.target, "unresolved jump label")
    jumpByPos[j.pos] = j
  end

  -- anchors: original positions (ascending) where trampolines may be inserted
  -- (just before the original instruction at that index).
  local anchors = self.anchors
  local nanch = #anchors

  -- per-anchor trampoline bookkeeping
  local counts = {}                 -- counts[k] = #trampolines at anchor k
  local trampAt = {}                -- trampAt[k][labelobj] = tramp record
  local perAnchorTramps = {}        -- perAnchorTramps[k] = ordered list
  local allTramps = {}              -- all tramp records (creation order)
  for k = 1, nanch do counts[k] = 0; trampAt[k] = {}; perAnchorTramps[k] = {} end

  local cumc = {}                   -- cumc[k] = sum counts[1..k]; cumc[0]=0
  local effArr = {}                 -- effArr[k] = position of anchor k's first slot
  local function recompute()
    local s = 0; cumc[0] = 0
    for k = 1, nanch do s = s + counts[k]; cumc[k] = s; effArr[k] = anchors[k] + cumc[k - 1] end
  end

  -- number of anchors with anchors[k] <= t  (anchors ascending)
  local function anchors_le(t)
    if nanch == 0 or anchors[1] > t then return 0 end
    local l, r, res = 1, nanch, 0
    while l <= r do
      local mid = math.floor((l + r) / 2)
      if anchors[mid] <= t then res = mid; l = mid + 1 else r = mid - 1 end
    end
    return res
  end
  local function newpos(t) return t + cumc[anchors_le(t)] end
  local function trampPos(rec) return anchors[rec.k] + cumc[rec.k - 1] + rec.j end
  local function tpos(T)
    if T.label then return newpos(T.label.target) else return trampPos(T.tramp) end
  end

  -- choose an anchor (effArr ascending in k) toward target position q
  local added
  local function choose_anchor(srcpos, q)
    if q > srcpos then
      local hi = q - 1; if srcpos + MAX < hi then hi = srcpos + MAX end
      -- largest k with effArr[k] <= hi and effArr[k] > srcpos
      local l, r, res = 1, nanch, nil
      while l <= r do
        local mid = math.floor((l + r) / 2)
        if effArr[mid] <= hi then res = mid; l = mid + 1 else r = mid - 1 end
      end
      if res and effArr[res] > srcpos then return res end
      return nil
    else
      local lo = q + 1; if srcpos - MAX > lo then lo = srcpos - MAX end
      -- smallest k with effArr[k] >= lo and effArr[k] < srcpos
      local l, r, res = 1, nanch, nil
      while l <= r do
        local mid = math.floor((l + r) / 2)
        if effArr[mid] >= lo then res = mid; r = mid - 1 else l = mid + 1 end
      end
      if res and effArr[res] < srcpos then return res end
      return nil
    end
  end

  -- immediate target for a jump at srcpos whose ultimate destination is finalT
  -- ({label=L}); returns an in-range target object, creating trampolines as
  -- needed (memoized per (anchor, label)).
  local function route1(srcpos, finalT)
    local q = newpos(finalT.label.target)
    local d = q - srcpos - 1
    if d >= -MAX and d <= MAX then return finalT end
    local k = choose_anchor(srcpos, q)
    if not k then error("relax: no trampoline anchor in range") end
    local L = finalT.label
    local rec = trampAt[k][L]
    if not rec then
      counts[k] = counts[k] + 1
      rec = { k = k, j = counts[k] - 1, finalT = finalT, imm = finalT }
      trampAt[k][L] = rec
      perAnchorTramps[k][#perAnchorTramps[k] + 1] = rec
      allTramps[#allTramps + 1] = rec
      added = true
    end
    return { tramp = rec }
  end

  -- stickiness: keep an existing immediate target while it stays in range
  local function ok_range(srcpos, imm)
    local d = tpos(imm) - srcpos - 1
    return d >= -MAX and d <= MAX
  end

  -- iterate to fixed point
  for pass = 1, 500 do
    recompute()
    added = false
    for _, j in ipairs(self.jumps) do
      local srcpos = newpos(j.pos)
      if not (j.imm and ok_range(srcpos, j.imm)) then
        j.imm = route1(srcpos, { label = j.label })
      end
    end
    for _, rec in ipairs(allTramps) do
      local srcpos = trampPos(rec)
      if not ok_range(srcpos, rec.imm) then
        rec.imm = route1(srcpos, rec.finalT)
      end
    end
    if not added then break end
  end
  recompute()

  -- materialize the final code array, splicing trampolines at anchors
  local function jmpword(sp, T)
    local sbx = tpos(T) - sp - 1
    if sbx > 131071 or sbx < -131071 then error("relax: jump still out of range") end
    return iAsBx(OP.JMP, 0, sbx)
  end
  local out = {}
  local ai = 1
  local function flush_anchors_at(idx)
    while ai <= nanch and anchors[ai] == idx do
      for _, rec in ipairs(perAnchorTramps[ai]) do out[#out + 1] = jmpword(trampPos(rec), rec.imm) end
      ai = ai + 1
    end
  end
  for i = 1, N do
    flush_anchors_at(i)
    local j = jumpByPos[i]
    if j then out[#out + 1] = jmpword(newpos(i), j.imm) else out[#out + 1] = code[i] end
  end
  flush_anchors_at(N + 1)

  local p = { lstr(nil), u32(0), u32(0), u8(self.nups), u8(self.nparams), u8(0), u8(self.maxstack), u32(#out) }
  for _, c in ipairs(out) do p[#p + 1] = c end
  p[#p + 1] = u32(#self.consts); for _, k in ipairs(self.consts) do p[#p + 1] = k end
  p[#p + 1] = u32(#self.children); for _, ch in ipairs(self.children) do p[#p + 1] = ch end
  p[#p + 1] = u32(0); p[#p + 1] = u32(0); p[#p + 1] = u32(0)
  return table.concat(p)
end

-- Like M.loadable but relaxes the wasm function's jumps via trampolines.
function M.loadable_relaxed(wasmfn)
  local child = wasmfn:build_relaxed()
  local fac = M.func(1, 0)
  local idx = fac:add_child(child)
  fac:CLOSURE(1, idx)
  fac:_emit(iABC(OP.MOVE, 0, 0, 0))
  fac:RETURN(1, 2)
  fac:RETURN(0, 1)
  return HEADER .. fac:build()
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
