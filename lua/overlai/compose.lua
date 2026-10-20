-- A small floating buffer for writing a comment, reply, or suggestion.
-- Submit with <C-s> or :w; cancel with q or :q. Writing is markdown.

local config = require("overlai.config")

local M = {}

--- Open a compose window.
--- opts = { title, initial = string|nil, on_submit = function(text), filetype? }
function M.open(opts)
  local o = config.options
  local keys = o.mappings.compose
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_name(buf, ("overlai://compose/%d"):format(buf))
  vim.bo[buf].filetype = opts.filetype or "markdown"
  local initial = opts.initial and vim.split(opts.initial, "\n", { plain = true }) or { "" }
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, initial)
  vim.bo[buf].modified = false

  local width = math.min(o.float.max_width, math.max(40, vim.o.columns - 10))
  local height = math.min(math.max(#initial + 2, 6), o.float.max_height)
  local footer = {}
  if keys.submit then
    footer[#footer + 1] = keys.submit .. " submit"
  end
  if keys.cancel then
    footer[#footer + 1] = keys.cancel .. " cancel"
  end
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = o.float.border,
    title = " " .. (opts.title or "Comment") .. " ",
    title_pos = "left",
    footer = #footer > 0 and (" " .. table.concat(footer, " · ") .. " ") or nil,
    footer_pos = "right",
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true

  local done = false
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  local function submit()
    if done then
      return
    end
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local s = table.concat(lines, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" and not opts.allow_empty then
      vim.notify("overlai: nothing to submit", vim.log.levels.WARN)
      return
    end
    done = true
    vim.cmd("stopinsert")
    close()
    local ok, err = pcall(opts.on_submit, s)
    if not ok then
      vim.notify(tostring(err), vim.log.levels.ERROR)
    end
  end

  vim.api.nvim_create_autocmd("BufWriteCmd", { buffer = buf, callback = submit })
  local map = function(mode, lhs, fn)
    if lhs then
      vim.keymap.set(mode, lhs, fn, { buffer = buf, nowait = true, silent = true })
    end
  end
  map({ "n", "i" }, keys.submit, submit)
  map("n", keys.cancel, close)

  if not opts.initial then
    vim.cmd("startinsert")
  end
  return buf, win
end

return M
