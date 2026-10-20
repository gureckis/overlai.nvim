-- Per-buffer state: the review document, plus an invisible "tracker" extmark
-- for each thread (and each suggestion with its own anchor). Trackers follow
-- the text while it is edited; on write their ranges become the anchors saved
-- in the review file.

local anchor = require("overlai.anchor")
local config = require("overlai.config")
local model = require("overlai.model")
local store = require("overlai.store")
local text = require("overlai.text")

local M = {}

M.ns = vim.api.nvim_create_namespace("overlai.track")

---@type table<integer, table>
M.state = setmetatable({}, {
  -- Buffer 0 means the current buffer, as in the API.
  __index = function(t, buf)
    if buf == 0 then
      return rawget(t, vim.api.nvim_get_current_buf())
    end
  end,
})

local listeners = {}

--- Call `fn(buf)` whenever a buffer's review state changes.
function M.on_change(fn)
  listeners[#listeners + 1] = fn
end

local function changed(buf)
  for _, fn in ipairs(listeners) do
    fn(buf)
  end
end

function M.get(buf)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  return M.state[buf]
end

function M.content(buf)
  return text.join(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
end

--- A buffer's range as 0-based positions -> half-open byte offsets.
function M.range_to_offsets(starts, len, r)
  return text.pos_to_offset(starts, len, r[1], r[2]), text.pos_to_offset(starts, len, r[3], r[4])
end

local function suggestion_key(thread)
  local msg, i = model.pending(thread)
  if msg and msg.suggestion.anchor then
    return thread.id .. ":" .. i
  end
end

local function set_tracker(buf, idx, anc, old_id)
  local a, b = anchor.resolve(idx, anc)
  if not a then
    if old_id then
      pcall(vim.api.nvim_buf_del_extmark, buf, M.ns, old_id)
    end
    return nil
  end
  local sr, sc = text.offset_to_pos(idx.lines, a)
  local er, ec = text.offset_to_pos(idx.lines, b)
  return vim.api.nvim_buf_set_extmark(buf, M.ns, sr, sc, {
    id = old_id,
    end_row = er,
    end_col = ec,
    right_gravity = false,
    end_right_gravity = true,
  })
end

--- Range of a tracker as { srow, scol, erow, ecol } (0-based, end exclusive),
--- or nil if the tracker is gone or its text was deleted.
function M.tracker_range(buf, id)
  if not id then
    return nil
  end
  local m = vim.api.nvim_buf_get_extmark_by_id(buf, M.ns, id, { details = true })
  if not m or not m[1] then
    return nil
  end
  local d = m[3]
  local r = { m[1], m[2], d.end_row or m[1], d.end_col or m[2] }
  if r[1] == r[3] and r[2] == r[4] then
    return nil
  end
  return r
end

--- Bring trackers in line with the document: place them for new threads,
--- drop them for deleted ones. Existing trackers keep their live positions.
local function place_trackers(buf, st)
  local idx
  local function index()
    idx = idx or anchor.index(M.content(buf))
    return idx
  end
  local seen, seen_s = {}, {}
  for _, t in ipairs(st.doc.threads) do
    seen[t.id] = true
    if not st.trackers[t.id] or not M.tracker_range(buf, st.trackers[t.id]) then
      st.trackers[t.id] = set_tracker(buf, index(), t.anchor, st.trackers[t.id])
    end
    local key = suggestion_key(t)
    if key then
      seen_s[key] = true
      if not st.suggestion_trackers[key] then
        local msg = model.pending(t)
        st.suggestion_trackers[key] = set_tracker(buf, index(), msg.suggestion.anchor)
      end
    end
  end
  for id, mark in pairs(st.trackers) do
    if not seen[id] then
      pcall(vim.api.nvim_buf_del_extmark, buf, M.ns, mark)
      st.trackers[id] = nil
    end
  end
  for key, mark in pairs(st.suggestion_trackers) do
    if not seen_s[key] then
      pcall(vim.api.nvim_buf_del_extmark, buf, M.ns, mark)
      st.suggestion_trackers[key] = nil
    end
  end
end

--- The range a thread covers now (nil when detached).
function M.thread_range(buf, id)
  local st = M.state[buf]
  return st and M.tracker_range(buf, st.trackers[id])
end

--- The range a thread's pending suggestion would replace.
function M.suggestion_range(buf, thread)
  local st = M.state[buf]
  local key = suggestion_key(thread)
  if key then
    return M.tracker_range(buf, st.suggestion_trackers[key])
  end
  return M.thread_range(buf, thread.id)
end

--- Take a newly read review file into a buffer's state.
local function take(buf, st, doc, data)
  st.doc, st.data = doc, data
  place_trackers(buf, st)
  changed(buf)
end

--- Re-read the review file if it changed on disk.
function M.reload(buf, force)
  local st = M.state[buf]
  if not st or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local data = require("overlai.util").read_file(st.paths.sidecar) or ""
  if data == st.data and not force then
    return
  end
  local ok, doc = pcall(store.load, st.paths.sidecar, st.paths.rel)
  if not ok then
    vim.notify(doc, vim.log.levels.WARN)
    return
  end
  take(buf, st, doc, data)
end

--- Apply a change to the review file: a locked read-modify-write, after which
--- the buffer's state is refreshed. Returns fn's value.
function M.update(buf, fn)
  local st = M.state[buf]
  local doc, value, data = store.update(st.paths, fn)
  take(buf, st, doc, data)
  return value
end

--- Rewrite anchors from the trackers. Called after the buffer is written, so
--- the anchors describe the file as it is on disk.
function M.sync_anchors(buf)
  local st = M.state[buf]
  if not st or #st.doc.threads == 0 then
    return
  end
  local content = M.content(buf)
  local starts = text.line_starts(content)
  local fresh, fresh_s = {}, {}
  local function anchor_for(r)
    local a, b = M.range_to_offsets(starts, #content, r)
    return anchor.from_range(content, a, b)
  end
  local function same(x, y)
    return x.quote == y.quote and x.prefix == y.prefix and x.suffix == y.suffix and x.line == y.line
  end
  local dirty = false
  for _, t in ipairs(st.doc.threads) do
    local r = M.thread_range(buf, t.id)
    if r then
      local anc = anchor_for(r)
      if not same(anc, t.anchor) then
        fresh[t.id], dirty = anc, true
      end
    end
    local key = suggestion_key(t)
    if key then
      local sr = M.tracker_range(buf, st.suggestion_trackers[key])
      if sr then
        local anc = anchor_for(sr)
        if not same(anc, model.pending(t).suggestion.anchor) then
          fresh_s[t.id], dirty = anc, true
        end
      end
    end
  end
  if not dirty then
    return
  end
  M.update(buf, function(doc)
    for _, t in ipairs(doc.threads) do
      if fresh[t.id] then
        t.anchor = fresh[t.id]
      end
      local msg = model.pending(t)
      if fresh_s[t.id] and msg and msg.suggestion.anchor then
        msg.suggestion.anchor = fresh_s[t.id]
      end
    end
  end)
end

local function is_file_buffer(buf)
  return vim.bo[buf].buftype == "" and vim.api.nvim_buf_get_name(buf) ~= ""
end

--- Start tracking a buffer. Without `create`, only buffers that already have a
--- review file are attached. Returns the state, or nil.
function M.attach(buf, create)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  if M.state[buf] then
    return M.state[buf]
  end
  if not is_file_buffer(buf) then
    if create then
      error("overlai: this buffer is not a file", 0)
    end
    return nil
  end
  local paths = store.paths(vim.api.nvim_buf_get_name(buf))
  if not create and not store.exists(paths.sidecar) then
    return nil
  end
  local st = { paths = paths, trackers = {}, suggestion_trackers = {}, data = nil }
  M.state[buf] = st

  local group = vim.api.nvim_create_augroup("overlai.buffer." .. buf, { clear = true })
  st.group = group
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    buffer = buf,
    callback = function()
      M.sync_anchors(buf)
    end,
  })
  vim.api.nvim_create_autocmd({ "BufEnter", "FocusGained" }, {
    group = group,
    buffer = buf,
    callback = function()
      M.reload(buf)
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = buf,
    callback = function()
      changed(buf)
    end,
  })
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufFilePost" }, {
    group = group,
    buffer = buf,
    callback = function()
      M.detach(buf)
    end,
  })
  require("overlai.watch").watch(paths.sidecar, buf, function()
    M.reload(buf)
  end)

  local data = require("overlai.util").read_file(paths.sidecar) or ""
  local ok, doc = pcall(store.load, paths.sidecar, paths.rel)
  if not ok then
    vim.notify(doc, vim.log.levels.WARN)
    doc = model.new_doc(paths.rel)
  end
  take(buf, st, doc, data)
  return st
end

function M.detach(buf)
  local st = M.state[buf]
  if not st then
    return
  end
  M.state[buf] = nil
  pcall(vim.api.nvim_del_augroup_by_id, st.group)
  require("overlai.watch").unwatch(st.paths.sidecar, buf)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  end
  changed(buf)
end

--- Threads in document order, filtered by `opts.resolved` (include resolved).
--- Each item: { thread, range } (range nil when detached).
function M.threads(buf, opts)
  local st = M.state[buf]
  if not st then
    return {}
  end
  opts = opts or {}
  local show_resolved = opts.resolved
  if show_resolved == nil then
    show_resolved = config.options.show_resolved
  end
  local items = {}
  for _, t in ipairs(st.doc.threads) do
    if t.status == "open" or show_resolved then
      items[#items + 1] = { thread = t, range = M.thread_range(buf, t.id) }
    end
  end
  table.sort(items, function(x, y)
    local rx, ry = x.range, y.range
    if not rx or not ry then
      return rx ~= nil and ry == nil
    end
    if rx[1] ~= ry[1] then
      return rx[1] < ry[1]
    end
    return rx[2] < ry[2]
  end)
  return items
end

local function contains(r, row, col)
  local after_start = row > r[1] or (row == r[1] and col >= r[2])
  local before_end = row < r[3] or (row == r[3] and col < r[4])
  return after_start and before_end
end

--- The innermost thread whose passage contains (row, col) (0-based).
function M.thread_at(buf, row, col, opts)
  local best, best_size
  for _, item in ipairs(M.threads(buf, opts)) do
    local r = item.range
    if r and contains(r, row, col) then
      local size = (r[3] - r[1]) * 1e6 + (r[4] - r[2])
      if not best_size or size < best_size then
        best, best_size = item.thread, size
      end
    end
  end
  return best
end

return M
