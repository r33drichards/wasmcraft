-- Generic SQLite query API for the wasm interpreter.
-- Drives the wq.wasm reactor (exports wq_open/wq_exec/...) and persists to a
-- real file through the WASI filesystem in wasi.lua.
--
--   local sql = require("sql")
--   local db  = sql.open{ module = wqBytes, path = "test.db", root = "/tmp/db" }
--   db:exec("CREATE TABLE t(a,b)")
--   db:exec("INSERT INTO t VALUES(1,'x')")
--   local r = db:query("SELECT * FROM t")   -- { columns = {...}, rows = {...} }
--   db:close()                              -- flushes the file
local wasm = require("wasm")
local wasi = require("wasi")

local M = {}
M.NULL = setmetatable({}, { __tostring = function() return "NULL" end })

local RS, US, NULM = "\30", "\31", "\29"

local function read_cstr(mem, ptr)
  local parts, i = {}, ptr
  while true do
    local chunk = mem:loadstr(i, 1024)
    local z = chunk:find("\0", 1, true)
    if z then parts[#parts + 1] = chunk:sub(1, z - 1); break end
    parts[#parts + 1] = chunk
    i = i + 1024
  end
  return table.concat(parts)
end

local function split(s, sep)
  local out, start = {}, 1
  while true do
    local p = s:find(sep, start, true)
    if not p then out[#out + 1] = s:sub(start); break end
    out[#out + 1] = s:sub(start, p - 1); start = p + 1
  end
  return out
end

local Db = {}
Db.__index = Db

local function wstr(db, s)
  local ptr = db.inst:call("wq_malloc", #s + 1)
  db.inst.memory:storestr(ptr, s)
  db.inst.memory:set8(ptr + #s, 0)
  return ptr
end

function Db:exec(sql)
  local p = wstr(self, sql)
  local rc = self.inst:call("wq_exec", p)
  self.inst:call("wq_free", p)
  if rc ~= 0 then
    error("sqlite error: " .. read_cstr(self.inst.memory, self.inst:call("wq_errmsg")), 2)
  end
  return self
end

-- Run SQL and return { columns = {names...}, rows = { row, ... } }.
-- Each row is keyed by both column index and column name; NULL is M.NULL.
function Db:query(sql)
  self:exec(sql)
  local res = read_cstr(self.inst.memory, self.inst:call("wq_result"))
  local out = { columns = {}, rows = {} }
  if #res == 0 then return out end
  local records = {}
  for _, r in ipairs(split(res, RS)) do if #r > 0 then records[#records + 1] = r end end
  if #records == 0 then return out end
  out.columns = split(records[1], US)
  for i = 2, #records do
    local fields = split(records[i], US)
    local row = {}
    for j = 1, #out.columns do
      local v = fields[j]
      if v == NULM then v = M.NULL end
      row[j] = v
      row[out.columns[j]] = v
    end
    out.rows[#out.rows + 1] = row
  end
  return out
end

function Db:changes() return self.inst:call("wq_changes") end
function Db:version() return read_cstr(self.inst.memory, self.inst:call("wq_version")) end
function Db:close() self.inst:call("wq_close"); return self end

-- opts: { module = <wq.wasm bytes>, path = "db.sqlite", fs = <hostfs> | root = dir, write }
function M.open(opts)
  assert(opts and opts.module, "sql.open requires opts.module (wq.wasm bytes)")
  local module = wasm.load(opts.module)
  local host = wasi.make({
    fs = opts.fs,
    root = opts.root or ".",
    write = opts.write or io.write,
  })
  local inst = wasm.instantiate(module, { wasi_snapshot_preview1 = host })
  inst:call("_initialize")
  local db = setmetatable({ inst = inst }, Db)
  if opts.path then
    local p = wstr(db, opts.path)
    local rc = inst:call("wq_open", p)
    inst:call("wq_free", p)
    if rc ~= 0 then error("sqlite open failed: " .. read_cstr(inst.memory, inst:call("wq_errmsg"))) end
  end
  return db
end

return M
