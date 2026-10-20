-- The thread window: one thread in full, in a float by the passage.

local buffer = require("overlai.buffer")
local config = require("overlai.config")
local format = require("overlai.format")

local M = {}

M.ns = vim.api.nvim_create_namespace("overlai.view")

local current -- { win, buf, source, id }

function M.close()
  if current and vim.api.nvim_win_is_valid(current.win) then
    vim.api.nvim_win_close(current.win, true)
  end
  current = nil
end

local function text_of(source, r)
  if not r then
    return nil
  end
  return table.concat(vim.api.nvim_buf_get_text(source, r[1], r[2], r[3], r[4], {}), "\n")
end

local function fill(buf, source, thread, width)
  local r = buffer.thread_range(source, thread.id)
  local b = format.builder()
  format.thread(b, thread, {
    width = width,
    line = r and (r[1] + 1) or nil,
    current = text_of(source, r),
    suggestion_current = text_of(source, buffer.suggestion_range(source, thread)),
  })
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, b.lines)
  vim.bo[buf].modifiable = false
  b.apply(buf, M.ns)
  return #b.lines
end

--- Show a thread. `opts.enter` focuses the window.
function M.open(source, id, opts)
  opts = opts or {}
  local st = buffer.get(source)
  local thread = st and require("overlai.model").find(st.doc, id)
  if not thread then
    return
  end
  M.close()
  local o = config.options
  local width = math.min(o.float.max_width, vim.o.columns - 6)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "overlai-thread"
  local height = math.min(fill(buf, source, thread, width - 2), o.float.max_height)

  local keys = o.mappings.thread
  local hints = {}
  for _, k in ipairs({ { "reply", "reply" }, { "accept", "accept" }, { "reject", "reject" }, { "toggle_resolved", "resolve" } }) do
    if keys[k[1]] then
      hints[#hints + 1] = keys[k[1]] .. " " .. k[2]
    end
  end
  local win = vim.api.nvim_open_win(buf, opts.enter ~= false, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = o.float.border,
    title = " overlai ",
    footer = " " .. table.concat(hints, " · ") .. " ",
    footer_pos = "right",
  })
  vim.wo[win].wrap = true
  current = { win = win, buf = buf, source = source, id = id }

  local actions = require("overlai.actions")
  local function act(name)
    return function()
      local src, tid = source, id
      M.close()
      actions[name](src, tid)
    end
  end
  local map = function(lhs, fn)
    if lhs then
      vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
    end
  end
  map(keys.reply, act("reply"))
  map(keys.accept, act("accept"))
  map(keys.reject, act("reject"))
  map(keys.toggle_resolved, act("toggle_resolved"))
  map(keys.close, M.close)
  map("<Esc>", M.close)
  vim.api.nvim_create_autocmd("WinLeave", { buffer = buf, once = true, callback = M.close })
  return win
end

--- Redraw the open thread window after a change.
function M.refresh(source)
  if not current or current.source ~= source or not vim.api.nvim_win_is_valid(current.win) then
    return
  end
  local st = buffer.get(source)
  local thread = st and require("overlai.model").find(st.doc, current.id)
  if not thread then
    return M.close()
  end
  fill(current.buf, source, thread, vim.api.nvim_win_get_width(current.win) - 2)
end

function M.is_open()
  return current ~= nil and vim.api.nvim_win_is_valid(current.win)
end

return M
