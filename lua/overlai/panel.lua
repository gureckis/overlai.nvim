-- The side panel: every thread on the current document, in document order.
-- It follows the window you are editing in, and its cursor follows yours.

local buffer = require("overlai.buffer")
local config = require("overlai.config")
local format = require("overlai.format")
local model = require("overlai.model")

local M = {}

M.ns = vim.api.nvim_create_namespace("overlai.panel")

local P = { win = nil, buf = nil, source = nil, rows = {}, heads = {}, show_resolved = nil, previewed = nil }

function M.is_open()
  return P.win ~= nil and vim.api.nvim_win_is_valid(P.win)
end

function M.source()
  return P.source
end

local function show_resolved()
  if P.show_resolved == nil then
    return config.options.show_resolved
  end
  return P.show_resolved
end

--- Thread id for the panel line under the cursor.
function M.id_at_cursor()
  if not M.is_open() then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(P.win)[1]
  return P.rows[row]
end

local function source_win()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == P.source then
      return win
    end
  end
end

function M.render()
  if not M.is_open() then
    return
  end
  local width = vim.api.nvim_win_get_width(P.win)
  local b = format.builder()
  P.rows, P.heads = {}, {}
  local st = P.source and buffer.get(P.source)
  if not st then
    b.add({ { " overlai", "OverlaiTitle" } })
    b.add({ { "" } })
    b.add({ { " No review on this buffer.", "OverlaiMuted" } })
    b.add({ { " Select text and :Overlai comment to start.", "OverlaiMuted" } })
  else
    local open, mine, resolved = 0, 0, 0
    for _, t in ipairs(st.doc.threads) do
      if t.status == "open" then
        open = open + 1
        if model.awaiting(t) == "human" then
          mine = mine + 1
        end
      else
        resolved = resolved + 1
      end
    end
    b.add({ { " " .. vim.fs.basename(st.paths.rel), "OverlaiTitle" } })
    b.add({
      { (" %d open · %d your turn · %d resolved"):format(open, mine, resolved), "OverlaiMuted" },
    })
    local status = require("overlai.agent").status(P.source)
    if status then
      b.add({ { " " .. status, "OverlaiAuthorAgent" } })
    end
    b.add({ { "" } })
    local items = buffer.threads(P.source, { resolved = show_resolved() })
    if #items == 0 then
      b.add({ { " No open threads.", "OverlaiMuted" } })
    end
    for _, item in ipairs(items) do
      local first = #b.lines + 1
      local head = format.entry(b, item.thread, {
        width = width,
        line = item.range and (item.range[1] + 1),
        detached = item.range == nil,
      })
      for row = first, #b.lines do
        P.rows[row] = item.thread.id
      end
      P.heads[item.thread.id] = head + 1
      b.add({ { "" } })
    end
  end
  vim.bo[P.buf].modifiable = true
  vim.api.nvim_buf_set_lines(P.buf, 0, -1, false, b.lines)
  vim.bo[P.buf].modifiable = false
  b.apply(P.buf, M.ns)
end

--- Put the panel's cursor on a thread.
function M.focus_thread(id)
  if not M.is_open() or not id or not P.heads[id] then
    return
  end
  pcall(vim.api.nvim_win_set_cursor, P.win, { P.heads[id], 0 })
end

--- Show a thread's passage in the source window, leaving focus in the panel.
function M.preview(id)
  local win = source_win()
  local r = win and id and buffer.thread_range(P.source, id)
  if not r then
    return
  end
  local cur = vim.api.nvim_win_get_cursor(win)
  local here = buffer.thread_at(P.source, cur[1] - 1, cur[2], { resolved = show_resolved() })
  if not (here and here.id == id) then
    local row = r[1] + 1
    local visible = vim.api.nvim_win_call(win, function()
      return row >= vim.fn.line("w0") and row <= vim.fn.line("w$")
    end)
    vim.api.nvim_win_set_cursor(win, { row, r[2] })
    if not visible then
      vim.api.nvim_win_call(win, function()
        vim.cmd("normal! zz")
      end)
    end
  end
  require("overlai.render").render_current(P.source, win)
end

--- Move the panel cursor to the next (dir = 1) or previous (dir = -1) entry.
function M.step(dir)
  if not M.is_open() then
    return
  end
  local rows = vim.tbl_values(P.heads)
  table.sort(rows)
  local cur = vim.api.nvim_win_get_cursor(P.win)[1]
  local target
  for i = dir > 0 and 1 or #rows, dir > 0 and #rows or 1, dir do
    if (dir > 0 and rows[i] > cur) or (dir < 0 and rows[i] < cur) then
      target = rows[i]
      break
    end
  end
  if target then
    vim.api.nvim_win_set_cursor(P.win, { target, 0 })
  end
end

--- Point the panel at another buffer.
function M.set_source(buf)
  if P.source == buf then
    return
  end
  P.source, P.previewed = buf, nil
  M.render()
end

local HELP = {
  { "jump", "go to the passage" },
  { "next", "next thread" },
  { "prev", "previous thread" },
  { "show", "open the thread" },
  { "reply", "reply" },
  { "accept", "accept the suggestion" },
  { "reject", "reject the suggestion" },
  { "toggle_resolved", "resolve / reopen" },
  { "delete", "delete the thread" },
  { "toggle_show_resolved", "show / hide resolved" },
  { "refresh", "re-read the review file" },
  { "close", "close the panel" },
}

local function help()
  local keys = config.options.mappings.panel
  local lines = {}
  for _, h in ipairs(HELP) do
    if keys[h[1]] then
      lines[#lines + 1] = ("%-8s %s"):format(keys[h[1]], h[2])
    end
  end
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "overlai panel" })
end

local function setup_buffer(buf)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "overlai"
  pcall(vim.api.nvim_buf_set_name, buf, "overlai://panel")

  local actions = require("overlai.actions")
  local keys = config.options.mappings.panel
  local function on_thread(fn)
    return function()
      local id = M.id_at_cursor()
      if id and P.source then
        fn(P.source, id)
      end
    end
  end
  local map = function(lhs, fn, desc)
    if lhs then
      vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
    end
  end
  map(keys.jump, on_thread(function(src, id)
    actions.jump(src, id, { focus = true })
  end), "Go to passage")
  map(keys.show, on_thread(function(src, id)
    actions.jump(src, id, { focus = true })
    actions.show(src, id)
  end), "Open thread")
  map(keys.reply, on_thread(function(src, id)
    actions.jump(src, id, { focus = true })
    actions.reply(src, id)
  end), "Reply")
  map(keys.accept, on_thread(actions.accept), "Accept suggestion")
  map(keys.reject, on_thread(actions.reject), "Reject suggestion")
  map(keys.toggle_resolved, on_thread(actions.toggle_resolved), "Resolve / reopen")
  map(keys.delete, on_thread(actions.delete), "Delete thread")
  map(keys.toggle_show_resolved, function()
    P.show_resolved = not show_resolved()
    M.render()
  end, "Show / hide resolved")
  map(keys.refresh, function()
    if P.source then
      buffer.reload(P.source, true)
    end
  end, "Refresh")
  map(keys.next, function()
    M.step(1)
  end, "Next thread")
  map(keys.prev, function()
    M.step(-1)
  end, "Previous thread")
  map(keys.close, M.close, "Close")

  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = buf,
    callback = function()
      local id = M.id_at_cursor()
      if id ~= P.previewed then
        P.previewed = id
        if config.options.panel.auto_preview then
          M.preview(id)
        end
      end
    end,
  })
  map(keys.help, help, "Help")
end

function M.open(source)
  if M.is_open() then
    M.set_source(source)
    return
  end
  local cur = vim.api.nvim_get_current_win()
  P.source = source
  if not (P.buf and vim.api.nvim_buf_is_valid(P.buf)) then
    P.buf = vim.api.nvim_create_buf(false, true)
    setup_buffer(P.buf)
  end
  local o = config.options.panel
  vim.cmd((o.position == "left" and "topleft" or "botright") .. " vertical " .. o.width .. "split")
  P.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(P.win, P.buf)
  local wo = vim.wo[P.win]
  wo.number, wo.relativenumber, wo.signcolumn = false, false, "no"
  wo.wrap, wo.cursorline, wo.winfixwidth = false, true, true
  wo.foldcolumn, wo.spell, wo.list = "0", false, false
  wo.fillchars = "eob: "
  M.render()
  vim.api.nvim_set_current_win(cur)
  M.follow()
end

function M.close()
  if M.is_open() then
    vim.api.nvim_win_close(P.win, true)
  end
  P.win = nil
end

function M.toggle(source)
  if M.is_open() then
    M.close()
  else
    M.open(source)
  end
end

--- Move the panel cursor to the thread under the source window's cursor.
function M.follow()
  if not M.is_open() or vim.api.nvim_get_current_buf() ~= P.source then
    return
  end
  local cur = vim.api.nvim_win_get_cursor(0)
  local t = buffer.thread_at(P.source, cur[1] - 1, cur[2], { resolved = show_resolved() })
  if t then
    M.focus_thread(t.id)
  end
end

M._source_win = source_win

return M
