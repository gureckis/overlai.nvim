-- Small helpers shared by the plugin and the command-line tool. Nothing here
-- may touch the UI: the CLI runs under `nvim -l` with no windows.

local M = {}

local uv = vim.uv or vim.loop

function M.now()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

function M.read_file(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local data = f:read("*a")
  f:close()
  return data
end

function M.mkdirp(dir)
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
end

--- Write through a temp file and rename, so a reader never sees half a file.
function M.write_file_atomic(path, data)
  M.mkdirp(vim.fs.dirname(path))
  local tmp = ("%s.tmp.%d"):format(path, uv.os_getpid())
  local f = assert(io.open(tmp, "wb"))
  f:write(data)
  f:close()
  local ok, err = os.rename(tmp, path)
  if not ok then
    os.remove(tmp)
    error(("overlai: could not write %s: %s"):format(path, err), 0)
  end
end

--- Absolute, symlink-free path (falls back to the plain absolute path for files
--- that do not exist yet).
function M.abspath(path)
  local abs = vim.fn.fnamemodify(path, ":p")
  return uv.fs_realpath(abs) or abs
end

function M.sha256(data)
  return vim.fn.sha256(data or "")
end

--- Truncate to `width` display cells, adding an ellipsis.
function M.truncate(s, width)
  s = s:gsub("%s+", " ")
  if vim.fn.strdisplaywidth(s) <= width then
    return s
  end
  local out = vim.fn.strcharpart(s, 0, math.max(width - 1, 0))
  while vim.fn.strdisplaywidth(out) > width - 1 do
    out = vim.fn.strcharpart(out, 0, vim.fn.strchars(out) - 1)
  end
  return out .. "…"
end

--- Truncate to `n` characters without the Vimscript API, so it is safe in
--- fast events (job and timer callbacks).
function M.truncate_chars(s, n)
  s = s:gsub("%s+", " ")
  local count, cut = 0, nil
  for pos in s:gmatch("()[^\128-\191][\128-\191]*") do
    count = count + 1
    if count == n then
      cut = pos
    end
  end
  if count <= n then
    return s
  end
  return s:sub(1, cut - 1) .. "…"
end

function M.first_line(s)
  return (s or ""):match("^[^\n]*")
end

---------------------------------------------------------------------------
-- JSON with stable key order and indentation, so sidecar files diff cleanly
-- when they are committed.

local KEY_ORDER = {
  "version",
  "file",
  "next_id",
  "threads",
  "id",
  "status",
  "anchor",
  "quote",
  "prefix",
  "suffix",
  "line",
  "author",
  "role",
  "body",
  "suggestion",
  "text",
  "messages",
  "created_at",
  "resolved_at",
  "resolved_by",
}
local KEY_RANK = {}
for i, k in ipairs(KEY_ORDER) do
  KEY_RANK[k] = i
end

-- Fields that are lists even when empty.
local ARRAY_KEYS = { threads = true, messages = true }

local function sorted_keys(t)
  local keys = vim.tbl_keys(t)
  table.sort(keys, function(a, b)
    local ra, rb = KEY_RANK[a] or math.huge, KEY_RANK[b] or math.huge
    if ra ~= rb then
      return ra < rb
    end
    return tostring(a) < tostring(b)
  end)
  return keys
end

local function encode(value, indent, key)
  local t = type(value)
  if t ~= "table" then
    if value == nil or value == vim.NIL then
      return "null"
    end
    return vim.json.encode(value)
  end
  local pad = string.rep("  ", indent + 1)
  local close = string.rep("  ", indent)
  if next(value) == nil then
    return ARRAY_KEYS[key] and "[]" or "{}"
  end
  local parts = {}
  if vim.islist(value) then
    for _, v in ipairs(value) do
      parts[#parts + 1] = pad .. encode(v, indent + 1)
    end
    return "[\n" .. table.concat(parts, ",\n") .. "\n" .. close .. "]"
  end
  for _, k in ipairs(sorted_keys(value)) do
    parts[#parts + 1] = pad .. vim.json.encode(tostring(k)) .. ": " .. encode(value[k], indent + 1, k)
  end
  return "{\n" .. table.concat(parts, ",\n") .. "\n" .. close .. "}"
end

function M.json_encode(value)
  return encode(value, 0) .. "\n"
end

function M.json_decode(s)
  return vim.json.decode(s, { luanil = { object = true, array = true } })
end

return M
