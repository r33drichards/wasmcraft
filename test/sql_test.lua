-- Generic query API + real file persistence through the WASI filesystem.
-- Creates a DB, queries it, closes (flush), reopens the SAME file, and confirms
-- the data persisted. Runs on lua5.4 and Cobalt.
package.path = "src/?.lua;test/?.lua;" .. package.path
local T = require("harness")
local sql = require("sql")
T.start("sql")

local f = assert(io.open("wasm/wq.wasm", "rb"))
local wq = f:read("*a"); f:close()

local DBFILE = ".wasmcraft_sqltest.db"

-- first session: create + insert + query
local db = sql.open{ module = wq, path = DBFILE, root = "." }
T.ok(db:version():find("3%.") ~= nil, "sqlite version reported: " .. db:version())
db:exec("DROP TABLE IF EXISTS people")
db:exec("CREATE TABLE people(id INTEGER PRIMARY KEY, name TEXT, score REAL)")
db:exec("INSERT INTO people(name,score) VALUES('alice',9.5),('bob',7.25),('carol',8.0)")
T.eq(db:changes(), 3, "3 rows inserted")

local r = db:query("SELECT name, score FROM people WHERE score > 7.5 ORDER BY score DESC")
T.eq(#r.rows, 2, "2 rows match score>7.5")
T.eq(r.columns[1], "name", "column name")
T.eq(r.rows[1].name, "alice", "row 1 name")
T.eq(r.rows[1].score, "9.5", "row 1 score")
T.eq(r.rows[2].name, "carol", "row 2 name")
db:close() -- flushes the file to disk

-- second session: reopen the SAME file; data must persist
local db2 = sql.open{ module = wq, path = DBFILE, root = "." }
local agg = db2:query("SELECT count(*) AS n, printf('%.2f', avg(score)) AS a FROM people")
T.eq(agg.rows[1].n, "3", "3 rows persisted across close/reopen")
T.eq(agg.rows[1].a, "8.25", "avg score persisted")

-- NULL handling
db2:exec("INSERT INTO people(name,score) VALUES('dave', NULL)")
local n = db2:query("SELECT name, score FROM people WHERE name='dave'")
T.eq(n.rows[1].score, sql.NULL, "NULL field decoded as sql.NULL")
db2:close()

-- cleanup (best effort)
pcall(os.remove, DBFILE)

T.done()
