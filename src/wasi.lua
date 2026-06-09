-- Minimal WASI preview1 host, enough to boot a wasi-libc "command" module
-- (one that writes to stdout/stderr and exits). Host functions receive the
-- interpreter's internal arg array (i32 = number, i64 = {h,l}) and the instance,
-- and return an array of results. Memory is reached via inst.memory.
local spack, sunpack = string.pack, string.unpack

local M = {}
M.EXIT = {} -- unique marker table for proc_exit unwinding

local function ru32(mem, a) return (sunpack("<I4", mem:loadstr(a, 4))) end
local function wu32(mem, a, v) mem:storestr(a, spack("<I4", v % 4294967296)) end
local function wu64(mem, a, v) mem:storestr(a, spack("<I4", v % 4294967296)); mem:storestr(a + 4, spack("<I4", 0)) end

-- opts: { write = function(str), writeerr = function(str), args = {..}, env = {..} }
function M.make(opts)
  opts = opts or {}
  local write = opts.write or io.write
  local writeerr = opts.writeerr or write
  local argv = opts.args or {}
  local env = opts.env or {}

  local W = {}

  -- fd_write(fd, iovs, iovs_len, nwritten) -> errno
  W.fd_write = function(a, inst)
    local mem = inst.memory
    local fd, iovs, iovs_len, nwritten = a[1], a[2], a[3], a[4]
    local parts, total = {}, 0
    for k = 0, iovs_len - 1 do
      local base = iovs + k * 8
      local ptr = ru32(mem, base)
      local len = ru32(mem, base + 4)
      parts[#parts + 1] = mem:loadstr(ptr, len)
      total = total + len
    end
    local s = table.concat(parts)
    if fd == 2 then writeerr(s) else write(s) end
    wu32(mem, nwritten, total)
    return { 0 }
  end

  W.fd_read = function(a, inst) wu32(inst.memory, a[4], 0); return { 0 } end -- EOF
  W.fd_close = function() return { 0 } end
  W.fd_datasync = function() return { 0 } end
  W.fd_sync = function() return { 0 } end

  -- fd_seek(fd, offset:i64, whence, newoffset) -> errno; report position 0
  W.fd_seek = function(a, inst) wu64(inst.memory, a[4], 0); return { 0 } end
  W.fd_tell = function(a, inst) wu64(inst.memory, a[2], 0); return { 0 } end

  -- fd_fdstat_get(fd, buf) -> errno; report a character device so libc fully buffers
  W.fd_fdstat_get = function(a, inst)
    local mem, buf = inst.memory, a[2]
    for i = 0, 23 do mem:set8(buf + i, 0) end
    mem:set8(buf, 2) -- fs_filetype = CHARACTER_DEVICE
    return { 0 }
  end
  W.fd_fdstat_set_flags = function() return { 0 } end
  W.fd_prestat_get = function() return { 8 } end       -- EBADF: no preopened dirs
  W.fd_prestat_dir_name = function() return { 8 } end

  -- args_sizes_get(argc_ptr, argv_buf_size_ptr)
  W.args_sizes_get = function(a, inst)
    local mem = inst.memory
    local nbytes = 0
    for _, s in ipairs(argv) do nbytes = nbytes + #s + 1 end
    wu32(mem, a[1], #argv)
    wu32(mem, a[2], nbytes)
    return { 0 }
  end
  W.args_get = function(a, inst)
    local mem = inst.memory
    local argv_ptr, buf = a[1], a[2]
    for i, s in ipairs(argv) do
      wu32(mem, argv_ptr + (i - 1) * 4, buf)
      mem:storestr(buf, s); mem:set8(buf + #s, 0)
      buf = buf + #s + 1
    end
    return { 0 }
  end
  W.environ_sizes_get = function(a, inst)
    wu32(inst.memory, a[1], 0); wu32(inst.memory, a[2], 0); return { 0 }
  end
  W.environ_get = function() return { 0 } end

  -- clock_time_get(id, precision:i64, time_ptr) -> errno; coarse time via os.time
  W.clock_time_get = function(a, inst)
    local secs = (os.time and os.time()) or 0
    -- nanoseconds as i64 low/high (seconds * 1e9 truncated to 64-bit low word range)
    local ns = secs * 1000000000
    inst.memory:storestr(a[3], spack("<I4", ns % 4294967296))
    inst.memory:storestr(a[3] + 4, spack("<I4", math.floor(ns / 4294967296) % 4294967296))
    return { 0 }
  end
  W.clock_res_get = function(a, inst) wu64(inst.memory, a[2], 1000); return { 0 } end

  W.random_get = function(a, inst)
    local mem, buf, len = inst.memory, a[1], a[2]
    for i = 0, len - 1 do mem:set8(buf + i, (i * 1103515245 + 12345) % 256) end
    return { 0 }
  end

  W.poll_oneoff = function() return { 0 } end
  W.sched_yield = function() return { 0 } end
  W.proc_exit = function(a) error({ [M.EXIT] = true, code = a[1] or 0 }) end

  -- Unknown imports: a stub that returns errno 52 (ENOSYS).
  return setmetatable(W, { __index = function(_, k)
    return function() return { 52 } end
  end })
end

return M
