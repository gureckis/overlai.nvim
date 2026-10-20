-- Notice when a review file changes on disk (an agent replying, another
-- Neovim, a git checkout). Watches the containing directory, since writes
-- replace the file by renaming over it.

local util = require("overlai.util")

local uv = vim.uv or vim.loop

local M = {}

M.debounce_ms = 60

-- dir -> { handle, files = { [basename] = { [key] = callback } }, timer }
local dirs = {}

local function fire(entry, name)
  local cbs = entry.files[name]
  if not cbs then
    return
  end
  for _, cb in pairs(cbs) do
    cb()
  end
end

local function start(dir)
  local entry = { files = {}, pending = {} }
  local handle = uv.new_fs_event()
  if not handle then
    return entry
  end
  entry.handle = handle
  local ok = handle:start(dir, {}, function(err, filename)
    if err or not filename then
      return
    end
    local name = vim.fs.basename(filename)
    if not entry.files[name] or entry.pending[name] then
      return
    end
    entry.pending[name] = true
    vim.defer_fn(function()
      entry.pending[name] = nil
      fire(entry, name)
    end, M.debounce_ms)
  end)
  if not ok then
    handle:close()
    entry.handle = nil
  end
  return entry
end

--- Call `cb` (on the main loop) when `path` changes. `key` identifies the
--- watcher for unwatch.
function M.watch(path, key, cb)
  local dir, name = vim.fs.dirname(path), vim.fs.basename(path)
  util.mkdirp(dir)
  dirs[dir] = dirs[dir] or start(dir)
  local files = dirs[dir].files
  files[name] = files[name] or {}
  files[name][key] = cb
end

function M.unwatch(path, key)
  local dir, name = vim.fs.dirname(path), vim.fs.basename(path)
  local entry = dirs[dir]
  if not entry or not entry.files[name] then
    return
  end
  entry.files[name][key] = nil
  if next(entry.files[name]) == nil then
    entry.files[name] = nil
  end
  if next(entry.files) == nil then
    if entry.handle then
      entry.handle:stop()
      entry.handle:close()
    end
    dirs[dir] = nil
  end
end

return M
