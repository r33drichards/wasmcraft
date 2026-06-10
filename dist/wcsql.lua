-- wcsql — load this to get a SQLite library backed by the pure-Lua wasm
-- interpreter, with real on-disk persistence via the WASI filesystem.
--
--   local sql = require("wcsql")          -- (or: local sql = dofile("wcsql.lua"))
--   local db  = sql.open("data.db")       -- path persists to the computer's disk
--   db:exec("CREATE TABLE IF NOT EXISTS t(id INTEGER PRIMARY KEY, name TEXT)")
--   db:exec("INSERT INTO t(name) VALUES('alice')")
--   local r = db:query("SELECT id, name FROM t")   -- { columns = {...}, rows = {...} }
--   for _, row in ipairs(r.rows) do print(row.id, row.name) end   -- keyed by name OR index
--   db:close()                            -- flush
--
-- In CC:Tweaked it downloads the interpreter bundle + SQLite reactor on first
-- use; standalone it finds them on disk.
local BUNDLE_URL = "https://github.com/r33drichards/wasmcraft/releases/latest/download/wasmcraft.lua"
local WQ_URL     = "https://github.com/r33drichards/wasmcraft/releases/latest/download/wq.wasm"

local function ensure(file, url)
  if type(fs) == "table" and fs.open and not fs.exists(file) then
    local r = assert(http.get(url), "http.get failed: " .. url)
    local h = fs.open(file, "wb"); h.write(r.readAll()); h.close(); r.close()
  end
end

local function find(cands)
  for _, p in ipairs(cands) do
    local f = io.open(p, "rb"); if f then f:close(); return p end
  end
end

ensure("wasmcraft", BUNDLE_URL)
ensure("wq.wasm", WQ_URL)
local bundlePath = assert(find({ "wasmcraft", "dist/wasmcraft.lua", "wasmcraft.lua" }), "interpreter bundle not found")
local wqPath     = assert(find({ "wq.wasm", "wasm/wq.wasm" }), "wq.wasm not found")

local wasmcraft = assert(loadfile(bundlePath))()

local M = { NULL = wasmcraft.sql.NULL, _engine = wasmcraft }

-- Open (or create) a database file and return a handle:
--   db:exec(sql) / db:query(sql) -> {columns,rows} / db:changes() / db:version() / db:close()
function M.open(path, opts)
  opts = opts or {}
  return wasmcraft.opendb({
    modulePath = wqPath, module = opts.module, mode = opts.mode,
    path = path or "data.db", root = opts.root, fs = opts.fs,
  })
end

return M
