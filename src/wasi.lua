-- Minimal WASI preview1 host. Two tiers:
--   * stdout/clock/args/etc. — enough to boot a wasi-libc "command" module.
--   * a real filesystem (preopened dir + path_open/fd_read/fd_write/fd_seek/
--     filestat/unlink/...) backed by host files, so SQLite persists an on-disk
--     .db through WASI. Each fd keeps an in-memory image (random read/write/seek);
--     the host file is read whole on open and written whole on sync/close, which
--     is all CC's fs API supports.
local spack, sunpack = string.pack, string.unpack
local schar = string.char
local floor = math.floor

local M = {}
M.EXIT = {} -- unique marker table for proc_exit unwinding

-- ---- little-endian struct writers/readers over linear memory --------------
local function ru32(mem, a) return (sunpack("<I4", mem:loadstr(a, 4))) end
local function wu32(mem, a, v) mem:storestr(a, spack("<I4", v % 4294967296)) end
local function wu64(mem, a, v)
  v = floor(v)
  mem:storestr(a, spack("<I4", v % 4294967296))
  mem:storestr(a + 4, spack("<I4", floor(v / 4294967296) % 4294967296))
end
local function i64num(v) -- interpreter passes i64 as {h,l}
  if type(v) == "table" then
    local n = v.h * 4294967296 + v.l
    if v.h >= 0x80000000 then n = n - 2 ^ 64 end
    return n
  end
  return v
end
local function hasflag(x, f) return floor(x / f) % 2 == 1 end

-- ---- in-memory file image (random access; flushed whole) ------------------
local FileImage = {}
FileImage.__index = FileImage

local function bytes_to_string(b, from, to) -- [from,to) 0-indexed
  local parts, chunk, ci = {}, {}, 0
  for i = from, to - 1 do
    ci = ci + 1; chunk[ci] = b[i] or 0
    if ci == 4096 then parts[#parts + 1] = schar((table.unpack or unpack)(chunk)); ci = 0; chunk = {} end
  end
  if ci > 0 then
    local last = {}
    for k = 1, ci do last[k] = chunk[k] end
    parts[#parts + 1] = schar((table.unpack or unpack)(last))
  end
  return table.concat(parts)
end

function FileImage.new(s)
  local o = setmetatable({ b = {}, len = 0, dirty = false }, FileImage)
  if s and #s > 0 then o:write(0, s) end
  o.dirty = false
  return o
end
function FileImage:read(pos, n)
  local e = pos + n; if e > self.len then e = self.len end
  if e <= pos then return "" end
  return bytes_to_string(self.b, pos, e)
end
function FileImage:write(pos, s)
  local b = self.b
  for i = 1, #s do b[pos + i - 1] = string.byte(s, i) end
  local nend = pos + #s
  if nend > self.len then self.len = nend end
  self.dirty = true
end
function FileImage:truncate(n)
  if n < self.len then for i = n, self.len - 1 do self.b[i] = nil end end
  self.len = n; self.dirty = true
end
function FileImage:tostring() return bytes_to_string(self.b, 0, self.len) end

-- ---- default host filesystem backends ------------------------------------
-- A host fs is: { read(path)->str|nil, write(path,data), exists(path)->bool,
--                 unlink(path), size(path)->n|nil, mkdir(path) }
local function io_hostfs(root)
  root = root or "."
  local function full(p)
    if p:sub(1, 1) == "/" then return p end
    if p:sub(1, 2) == "./" then p = p:sub(3) end
    return root .. "/" .. p
  end
  return {
    read = function(p) local f = io.open(full(p), "rb"); if not f then return nil end local d = f:read("*a"); f:close(); return d end,
    write = function(p, d) local f = assert(io.open(full(p), "wb")); f:write(d); f:close() end,
    exists = function(p) local f = io.open(full(p), "rb"); if f then f:close(); return true end return false end,
    size = function(p) local f = io.open(full(p), "rb"); if not f then return nil end local n = f:seek("end"); f:close(); return n end,
    unlink = function(p) os.remove(full(p)) end,
    mkdir = function() end,
  }
end
M.io_hostfs = io_hostfs

-- ---- WASI errnos / constants ---------------------------------------------
local E = { SUCCESS = 0, BADF = 8, EXIST = 20, INVAL = 28, ISDIR = 31, NOENT = 44, NOSYS = 52, NOTDIR = 54 }
local FT = { unknown = 0, chardev = 2, dir = 3, file = 4 }

-- opts: { write, writeerr, args, env, fs = <hostfs>, root = "." }
function M.make(opts)
  opts = opts or {}
  local write = opts.write or io.write
  local writeerr = opts.writeerr or write
  local argv = opts.args or {}
  local hostfs = opts.fs
  if hostfs == nil and opts.root then hostfs = io_hostfs(opts.root) end

  local W = {}

  -- file descriptor table (0/1/2 std; 3 = preopened ".")
  local fds = {
    [0] = { kind = "stdin" }, [1] = { kind = "stdout" }, [2] = { kind = "stderr" },
  }
  if hostfs then fds[3] = { kind = "dir", name = "/" } end
  local next_fd = 4
  local PRENAME = "/" -- preopen the root; SQLite absolutizes paths via getcwd
  -- name -> entry, so path-based stat/unlink see files that are open (and only
  -- flushed to disk on sync/close) and directories created for dotfile locking.
  local byname = {}

  local function resolve(path) return path end -- wasi-libc already stripped the preopen prefix

  -- ---- streams + non-fs basics -------------------------------------------
  W.fd_write = function(a, inst)
    local mem = inst.memory
    local fd, iovs, iovs_len, nwritten = a[1], a[2], a[3], a[4]
    local parts, total = {}, 0
    for k = 0, iovs_len - 1 do
      local base = iovs + k * 8
      local ptr = ru32(mem, base); local len = ru32(mem, base + 4)
      parts[#parts + 1] = mem:loadstr(ptr, len); total = total + len
    end
    local s = table.concat(parts)
    local e = fds[fd]
    if e and e.kind == "file" then
      if e.append then e.pos = e.img.len end
      e.img:write(e.pos, s); e.pos = e.pos + #s
    elseif fd == 2 then writeerr(s) else write(s) end
    wu32(mem, nwritten, total)
    return { 0 }
  end

  W.fd_read = function(a, inst)
    local mem = inst.memory
    local fd, iovs, iovs_len, nread = a[1], a[2], a[3], a[4]
    local e = fds[fd]
    local total = 0
    if e and e.kind == "file" then
      for k = 0, iovs_len - 1 do
        local base = iovs + k * 8
        local ptr = ru32(mem, base); local len = ru32(mem, base + 4)
        local chunk = e.img:read(e.pos, len)
        mem:storestr(ptr, chunk); e.pos = e.pos + #chunk; total = total + #chunk
        if #chunk < len then break end
      end
    end
    wu32(mem, nread, total)
    return { 0 }
  end

  local function flush(e)
    if e.kind == "file" and e.img.dirty and hostfs then
      hostfs.write(e.hostpath, e.img:tostring()); e.img.dirty = false
    end
  end

  W.fd_close = function(a)
    local e = fds[a[1]]
    if e then flush(e); fds[a[1]] = nil; if e.hostpath then byname[e.hostpath] = nil end end
    return { 0 }
  end
  W.fd_sync = function(a) local e = fds[a[1]]; if e then flush(e) end return { 0 } end
  W.fd_datasync = W.fd_sync

  W.fd_seek = function(a, inst)
    local fd, off, whence, outp = a[1], i64num(a[2]), a[3], a[4]
    local e = fds[fd]
    if not e then return { E.BADF } end
    if e.kind == "file" then
      local base = (whence == 0 and 0) or (whence == 1 and e.pos) or e.img.len
      e.pos = base + off
      wu64(inst.memory, outp, e.pos)
      return { 0 }
    end
    wu64(inst.memory, outp, 0)
    return { 0 }
  end

  W.fd_fdstat_get = function(a, inst)
    local mem, fd, buf = inst.memory, a[1], a[2]
    for i = 0, 23 do mem:set8(buf + i, 0) end
    local e = fds[fd]
    local ft = FT.chardev
    if e then
      if e.kind == "file" then ft = FT.file elseif e.kind == "dir" then ft = FT.dir end
    end
    mem:set8(buf, ft)
    -- grant all rights so libc permits every op
    mem:storestr(buf + 8, spack("<I4", 0xFFFFFFFF) .. spack("<I4", 0xFFFFFFFF))
    mem:storestr(buf + 16, spack("<I4", 0xFFFFFFFF) .. spack("<I4", 0xFFFFFFFF))
    return { 0 }
  end
  W.fd_fdstat_set_flags = function(a) local e = fds[a[1]]; if e then e.append = hasflag(a[2], 1) end return { 0 } end

  local function write_filestat(mem, buf, filetype, size)
    for i = 0, 63 do mem:set8(buf + i, 0) end
    mem:set8(buf + 16, filetype)   -- filetype
    mem:storestr(buf + 24, spack("<I4", 1) .. spack("<I4", 0)) -- nlink = 1
    wu64(mem, buf + 32, size)      -- size
  end

  W.fd_filestat_get = function(a, inst)
    local e = fds[a[1]]
    if not e then return { E.BADF } end
    local ft = (e.kind == "file" and FT.file) or (e.kind == "dir" and FT.dir) or FT.chardev
    write_filestat(inst.memory, a[2], ft, e.img and e.img.len or 0)
    return { 0 }
  end
  W.fd_filestat_set_size = function(a)
    local e = fds[a[1]]; if not (e and e.img) then return { E.BADF } end
    e.img:truncate(i64num(a[2]))
    return { 0 }
  end

  W.fd_prestat_get = function(a, inst)
    if a[1] == 3 and hostfs then
      local mem, buf = inst.memory, a[2]
      mem:set8(buf, 0)               -- tag = dir
      wu32(mem, buf + 4, #PRENAME)   -- name length
      return { 0 }
    end
    return { E.BADF }
  end
  W.fd_prestat_dir_name = function(a, inst)
    if a[1] == 3 then inst.memory:storestr(a[2], PRENAME:sub(1, a[3])); return { 0 } end
    return { E.BADF }
  end

  -- path ops (dirfd is the preopen; we resolve names directly via hostfs)
  local function path_str(mem, ptr, len)
    local s = mem:loadstr(ptr, len)
    if opts.debug then (opts.debug == true and print or opts.debug)("  path='" .. s .. "'") end
    return s
  end

  W.path_open = function(a, inst)
    if not hostfs then return { E.NOSYS } end
    local mem = inst.memory
    local path = resolve(path_str(mem, a[3], a[4]))
    local oflags, fdflags, outp = a[5], a[8], a[9]
    local creat = hasflag(oflags, 1)
    local trunc = hasflag(oflags, 8)
    local excl = hasflag(oflags, 4)
    local exists = hostfs.exists(path)
    if not exists and not creat then return { E.NOENT } end
    if exists and creat and excl then return { E.EXIST } end
    local data = (exists and not trunc) and (hostfs.read(path) or "") or ""
    local fd = next_fd; next_fd = next_fd + 1
    local e = { kind = "file", hostpath = path, img = FileImage.new(data), pos = 0, append = hasflag(fdflags, 1) }
    if (trunc and exists) or not exists then e.img.dirty = true end
    fds[fd] = e
    byname[path] = e
    wu32(mem, outp, fd)
    return { 0 }
  end

  W.path_filestat_get = function(a, inst)
    if not hostfs then return { E.NOSYS } end
    local path = resolve(path_str(inst.memory, a[3], a[4]))
    local e = byname[path]
    if e then
      write_filestat(inst.memory, a[5], e.kind == "dir" and FT.dir or FT.file, e.img and e.img.len or 0)
      return { 0 }
    end
    local sz = hostfs.size(path)
    if sz == nil then return { E.NOENT } end
    write_filestat(inst.memory, a[5], FT.file, sz)
    return { 0 }
  end

  W.path_unlink_file = function(a, inst)
    if not hostfs then return { E.NOSYS } end
    local path = resolve(path_str(inst.memory, a[2], a[3]))
    byname[path] = nil
    hostfs.unlink(path)
    return { 0 }
  end
  W.path_create_directory = function(a, inst)
    local path = resolve(path_str(inst.memory, a[2], a[3]))
    byname[path] = { kind = "dir" }
    if hostfs then hostfs.mkdir(path) end
    return { 0 }
  end
  W.path_remove_directory = function(a, inst)
    byname[resolve(path_str(inst.memory, a[2], a[3]))] = nil
    return { 0 }
  end
  W.path_filestat_set_times = function() return { 0 } end
  W.path_readlink = function() return { E.INVAL } end
  W.path_rename = function() return { E.NOSYS } end

  -- ---- non-fs basics ------------------------------------------------------
  W.args_sizes_get = function(a, inst)
    local nbytes = 0; for _, s in ipairs(argv) do nbytes = nbytes + #s + 1 end
    wu32(inst.memory, a[1], #argv); wu32(inst.memory, a[2], nbytes); return { 0 }
  end
  W.args_get = function(a, inst)
    local mem, argv_ptr, buf = inst.memory, a[1], a[2]
    for i, s in ipairs(argv) do
      wu32(mem, argv_ptr + (i - 1) * 4, buf)
      mem:storestr(buf, s); mem:set8(buf + #s, 0); buf = buf + #s + 1
    end
    return { 0 }
  end
  W.environ_sizes_get = function(a, inst) wu32(inst.memory, a[1], 0); wu32(inst.memory, a[2], 0); return { 0 } end
  W.environ_get = function() return { 0 } end

  W.clock_time_get = function(a, inst)
    local secs = (os.time and os.time()) or 0
    wu64(inst.memory, a[3], secs * 1000000000)
    return { 0 }
  end
  W.clock_res_get = function(a, inst) wu64(inst.memory, a[2], 1000); return { 0 } end
  W.random_get = function(a, inst)
    local mem, buf, len = inst.memory, a[1], a[2]
    local seed = (os.time and os.time()) or 1
    for i = 0, len - 1 do seed = (seed * 1103515245 + 12345) % 4294967296; mem:set8(buf + i, floor(seed / 65536) % 256) end
    return { 0 }
  end
  W.poll_oneoff = function() return { 0 } end
  W.sched_yield = function() return { 0 } end
  W.proc_exit = function(a) error({ [M.EXIT] = true, code = a[1] or 0 }) end

  -- optional call tracing
  if opts.debug then
    local dbg = opts.debug == true and print or opts.debug
    local function av(x) if type(x) == "table" then return i64num(x) end return x end
    for k, fn in pairs(W) do
      W[k] = function(a, inst)
        local r = fn(a, inst)
        dbg(string.format("WASI %-22s args=%s,%s,%s,%s,%s -> %s", k,
          tostring(av(a[1])), tostring(av(a[2])), tostring(av(a[3])), tostring(av(a[4])), tostring(av(a[5])),
          tostring(r and r[1])))
        return r
      end
    end
    return setmetatable(W, { __index = function(_, name)
      return function() dbg("WASI " .. name .. " (stub) -> NOSYS"); return { E.NOSYS } end
    end })
  end

  -- unknown imports: stub returning ENOSYS (single i32 result)
  return setmetatable(W, { __index = function() return function() return { E.NOSYS } end end })
end

return M
