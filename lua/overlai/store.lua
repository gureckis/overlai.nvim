-- Where review files live and how they are read and written.
--
-- A document's review file sits under a `.review/` directory at the project
-- root, mirroring the document's path:
--
--   readings/bayes.md  ->  .review/readings/bayes.md.json
--
-- The root is the nearest ancestor holding a `.review/` directory, else the
-- git root, else the document's own directory. The plugin and the CLI both
-- write these files, so every change is a locked read-modify-write.

local model = require("overlai.model")
local util = require("overlai.util")

local uv = vim.uv or vim.loop

local M = {}

M.dir_name = ".review"

function M.root_for(file)
  local dir = vim.fs.dirname(file)
  local found = vim.fs.find(M.dir_name, { path = dir, upward = true, type = "directory", limit = 1 })[1]
  if found then
    return vim.fs.dirname(found)
  end
  local git = vim.fs.find(".git", { path = dir, upward = true, limit = 1 })[1]
  if git then
    return vim.fs.dirname(git)
  end
  return dir
end

--- Paths for a document: { file, root, rel, sidecar }.
function M.paths(file)
  file = util.abspath(file)
  local root = M.root_for(file)
  local rel = file:sub(#root + 2)
  return {
    file = file,
    root = root,
    rel = rel,
    sidecar = vim.fs.joinpath(root, M.dir_name, rel .. ".json"),
  }
end

function M.exists(sidecar)
  return uv.fs_stat(sidecar) ~= nil
end

--- Read a review file. Returns a fresh document when there is none.
function M.load(sidecar, rel)
  local data = util.read_file(sidecar)
  if not data or data == "" then
    return model.new_doc(rel)
  end
  local ok, doc = pcall(util.json_decode, data)
  if not ok then
    error(("overlai: %s is not valid JSON: %s"):format(sidecar, doc), 0)
  end
  return model.check_doc(doc)
end

function M.encode(doc)
  return util.json_encode(doc)
end

function M.save(sidecar, doc)
  local data = M.encode(doc)
  util.write_file_atomic(sidecar, data)
  return data
end

M.lock_timeout_ms = 3000
M.stale_lock_s = 10

--- Run `fn` holding a lock on `sidecar` (an mkdir lock, which is atomic on
--- every filesystem we care about).
function M.with_lock(sidecar, fn)
  local lock = sidecar .. ".lock"
  util.mkdirp(vim.fs.dirname(sidecar))
  local waited = 0
  while not uv.fs_mkdir(lock, 448) do
    local st = uv.fs_stat(lock)
    if st and os.time() - st.mtime.sec > M.stale_lock_s then
      uv.fs_rmdir(lock)
    elseif waited >= M.lock_timeout_ms then
      error("overlai: timed out waiting for " .. lock, 0)
    else
      uv.sleep(10)
      waited = waited + 10
    end
  end
  local res = { pcall(fn) }
  uv.fs_rmdir(lock)
  if not res[1] then
    error(res[2], 0)
  end
  return unpack(res, 2)
end

--- Locked read-modify-write. `fn(doc)` changes the document in place and may
--- return a value. Returns `doc, value, data` (data is the written JSON).
function M.update(paths, fn)
  return M.with_lock(paths.sidecar, function()
    local doc = M.load(paths.sidecar, paths.rel)
    local value = fn(doc)
    local data = M.save(paths.sidecar, doc)
    return doc, value, data
  end)
end

return M
