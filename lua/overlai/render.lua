-- Decorations in the document: a highlight over each commented passage, signs
-- beside it, a preview of the latest message, and pending suggestions drawn
-- as tracked changes (old text struck through, new text beside it).

local buffer = require("overlai.buffer")
local config = require("overlai.config")
local model = require("overlai.model")
local util = require("overlai.util")

local M = {}

M.ns = vim.api.nvim_create_namespace("overlai.render")
M.ns_current = vim.api.nvim_create_namespace("overlai.current")

local function fg(name)
  local hl = vim.api.nvim_get_hl(0, { name = name, link = false })
  return hl.fg
end

function M.highlights()
  local set = function(name, val)
    val.default = true
    vim.api.nvim_set_hl(0, name, val)
  end
  set("OverlaiRange", { underline = true, sp = fg("DiagnosticInfo") })
  set("OverlaiRangeAgent", { underline = true, sp = fg("DiagnosticWarn") })
  set("OverlaiRangeResolved", { underdotted = true, sp = fg("Comment") })
  set("OverlaiCurrent", { link = "Visual" })
  set("OverlaiSign", { link = "DiagnosticInfo" })
  set("OverlaiSignAgent", { link = "DiagnosticWarn" })
  set("OverlaiSignResolved", { link = "Comment" })
  set("OverlaiPreview", { link = "Comment" })
  set("OverlaiDelete", { strikethrough = true, fg = fg("DiagnosticError") })
  set("OverlaiAdd", { fg = fg("DiagnosticOk") or fg("String"), bold = true })
  set("OverlaiAuthorHuman", { link = "DiagnosticInfo" })
  set("OverlaiAuthorAgent", { link = "DiagnosticWarn" })
  set("OverlaiTitle", { link = "Title" })
  set("OverlaiMuted", { link = "Comment" })
  set("OverlaiId", { link = "Identifier" })
end

local function opener_role(thread)
  local first = model.opener(thread)
  return first and first.role or "human"
end

local function preview(thread)
  local o = config.options
  local last = model.last_message(thread)
  if not last then
    return nil
  end
  local icon = last.role == "agent" and o.icons.agent or o.icons.human
  local body = util.first_line(last.body)
  if body == "" and last.suggestion then
    body = "suggested an edit"
  end
  local s = ("%s%s: %s"):format(icon, last.author, body)
  local extra = #thread.messages > 1 and (" (%d)"):format(#thread.messages) or ""
  return util.truncate(s, o.virt_text_width) .. extra, last.role
end

local function draw_suggestion(buf, item)
  local msg = model.pending(item.thread)
  if not msg or item.thread.status ~= "open" then
    return
  end
  local r = buffer.suggestion_range(buf, item.thread)
  if not r then
    return
  end
  vim.api.nvim_buf_set_extmark(buf, M.ns, r[1], r[2], {
    end_row = r[3],
    end_col = r[4],
    hl_group = "OverlaiDelete",
    priority = 210,
  })
  local new_lines = vim.split(msg.suggestion.text, "\n", { plain = true })
  if #new_lines == 1 then
    vim.api.nvim_buf_set_extmark(buf, M.ns, r[3], r[4], {
      virt_text = { { new_lines[1], "OverlaiAdd" } },
      virt_text_pos = "inline",
      priority = 210,
    })
  else
    local virt = {}
    for _, l in ipairs(new_lines) do
      virt[#virt + 1] = { { "+ " .. l, "OverlaiAdd" } }
    end
    vim.api.nvim_buf_set_extmark(buf, M.ns, r[3], 0, { virt_lines = virt, priority = 210 })
  end
end

function M.render(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  if not buffer.get(buf) then
    vim.api.nvim_buf_clear_namespace(buf, M.ns_current, 0, -1)
    return
  end
  local o = config.options
  local line_count = vim.api.nvim_buf_line_count(buf)
  for _, item in ipairs(buffer.threads(buf)) do
    local r = item.range
    if r then
      local t = item.thread
      local resolved = t.status ~= "open"
      local agent = opener_role(t) == "agent"
      local range_hl = resolved and "OverlaiRangeResolved" or (agent and "OverlaiRangeAgent" or "OverlaiRange")
      local sign_hl = resolved and "OverlaiSignResolved" or (agent and "OverlaiSignAgent" or "OverlaiSign")
      vim.api.nvim_buf_set_extmark(buf, M.ns, r[1], r[2], {
        end_row = r[3],
        end_col = r[4],
        hl_group = range_hl,
        hl_mode = "combine",
        priority = 200,
      })
      if o.signs then
        local last_row = (r[4] == 0 and r[3] > r[1]) and r[3] - 1 or r[3]
        for row = r[1], math.min(last_row, line_count - 1) do
          vim.api.nvim_buf_set_extmark(buf, M.ns, row, 0, {
            sign_text = o.sign_text,
            sign_hl_group = sign_hl,
            priority = 20,
          })
        end
      end
      if o.virt_text and not resolved then
        local s, role = preview(t)
        if s then
          vim.api.nvim_buf_set_extmark(buf, M.ns, r[1], 0, {
            virt_text = { { "  " .. s, role == "agent" and "OverlaiAuthorAgent" or "OverlaiPreview" } },
            virt_text_pos = "eol",
            hl_mode = "combine",
          })
        end
      end
      draw_suggestion(buf, item)
    end
  end
  M.render_current(buf)
end

--- Highlight the thread under the cursor.
--- Highlight the thread under the cursor of `win` (default: the current
--- window, if it shows `buf`).
function M.render_current(buf, win)
  vim.api.nvim_buf_clear_namespace(buf, M.ns_current, 0, -1)
  win = win or vim.api.nvim_get_current_win()
  if not buffer.get(buf) or vim.api.nvim_win_get_buf(win) ~= buf then
    return
  end
  local cur = vim.api.nvim_win_get_cursor(win)
  local t = buffer.thread_at(buf, cur[1] - 1, cur[2])
  M.current = t and t.id or nil
  if t then
    local r = buffer.thread_range(buf, t.id)
    vim.api.nvim_buf_set_extmark(buf, M.ns_current, r[1], r[2], {
      end_row = r[3],
      end_col = r[4],
      hl_group = "OverlaiCurrent",
      priority = 190,
    })
  end
end

return M
