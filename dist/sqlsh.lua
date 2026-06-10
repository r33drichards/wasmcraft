-- sqlsh — a tiny interactive SQLite shell running on the pure-Lua wasm
-- interpreter. Persists to a real file via the WASI filesystem.
--
--   Usage:  sqlsh [dbfile]        (default: data.db)
--   Type SQL statements; results print as a table. Commands: .tables .schema
--   .help .exit  . Data is saved to the db file as you go.
--
-- In CC:Tweaked it downloads its two dependencies (the interpreter bundle and
-- the SQLite reactor) on first run. Standalone it looks for them on disk.
local BUNDLE_URL = "https://github.com/r33drichards/wasmcraft/releases/latest/download/wasmcraft.lua"
local WQ_URL     = "https://github.com/r33drichards/wasmcraft/releases/latest/download/wq.wasm"

local function ensure(file, url)
  if type(fs) == "table" and fs.open then
    if not fs.exists(file) then
      io.write("fetching " .. file .. " ... ")
      local r = assert(http.get(url), "http.get failed for " .. url)
      local h = fs.open(file, "wb"); h.write(r.readAll()); h.close(); r.close()
      print("ok")
    end
    return file
  end
  return nil -- standalone: rely on the search paths below
end

-- locate the interpreter bundle and wq.wasm (download in CC, else find on disk)
ensure("wasmcraft", BUNDLE_URL)
ensure("wq.wasm", WQ_URL)

local function find(cands)
  for _, p in ipairs(cands) do
    local f = io.open(p, "rb"); if f then f:close(); return p end
  end
end
local bundlePath = find({ "wasmcraft", "dist/wasmcraft.lua", "wasmcraft.lua" })
local wqPath     = find({ "wq.wasm", "wasm/wq.wasm" })
assert(bundlePath, "interpreter bundle not found")
assert(wqPath, "wq.wasm not found")

local wasmcraft = assert(loadfile(bundlePath))()

local args = { ... }
-- --mode interp|jit|transpile|auto (explicit; default interp)
local mode = "interp"
for i = #args - 1, 1, -1 do
  if args[i] == "--mode" then mode = args[i + 1]; table.remove(args, i + 1); table.remove(args, i) end
end
local dbfile = args[1] or "data.db"
local db = wasmcraft.opendb{ modulePath = wqPath, path = dbfile, mode = mode }

print("sqlsh — SQLite " .. db:version() .. " on a pure-Lua wasm interpreter")
print("db: " .. dbfile .. "   (.help for commands, .exit to quit)")

local function print_table(res)
  if #res.columns == 0 then print("OK (" .. db:changes() .. " changes)"); return end
  print(table.concat(res.columns, " | "))
  local sep = {}; for i = 1, #res.columns do sep[i] = string.rep("-", #res.columns[i]) end
  print(table.concat(sep, "-+-"))
  for _, row in ipairs(res.rows) do
    local cells = {}
    for i = 1, #res.columns do
      local v = row[i]
      cells[i] = (v == wasmcraft.sql.NULL) and "NULL" or tostring(v)
    end
    print(table.concat(cells, " | "))
  end
  print("(" .. #res.rows .. " row" .. (#res.rows == 1 and "" or "s") .. ")")
end

local function run(line)
  if line == ".tables" then
    line = "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
  elseif line:sub(1, 7) == ".schema" then
    local t = line:match("^%.schema%s+(%S+)")
    line = "SELECT sql FROM sqlite_master WHERE type='table'" .. (t and (" AND name='" .. t .. "'") or "")
  end
  local ok, res = pcall(function() return db:query(line) end)
  if not ok then print(tostring(res)) else print_table(res) end
end

while true do
  io.write("sql> ")
  local line = io.read("*l")
  if line == nil or line == ".exit" or line == ".quit" then break end
  if line == ".help" then
    print(".tables          list tables")
    print(".schema [table]  show CREATE statements")
    print(".exit            quit (data is saved)")
    print("…or any SQL statement (CREATE/INSERT/SELECT/...)")
  elseif line ~= "" then
    run(line)
  end
end

db:close()
print("bye (saved to " .. dbfile .. ")")
