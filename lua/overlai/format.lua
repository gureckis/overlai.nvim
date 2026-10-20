-- Turning threads into lines (with highlights) for the panel and the thread
-- window.

local config = require("overlai.config")
local model = require("overlai.model")
local util = require("overlai.util")

local M = {}

--- "3m ago", "2h ago", "Oct 4".
function M.ago(iso, now)
  if not iso then
    return ""
  end
  local y, mo, d, h, mi, s = iso:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)Z$")
  if not y then
    return iso
  end
  local t = os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = s, isdst = false })
  -- os.time reads the table as local time; shift it back to UTC.
  local offset = os.time() - os.time(os.date("!*t") --[[@as osdate]])
  local delta = (now or os.time()) - (t + offset)
  if delta < 60 then
    return "just now"
  elseif delta < 3600 then
    return ("%dm ago"):format(math.floor(delta / 60))
  elseif delta < 86400 then
    return ("%dh ago"):format(math.floor(delta / 3600))
  elseif delta < 86400 * 7 then
    return ("%dd ago"):format(math.floor(delta / 86400))
  end
  return os.date("%b %-d", t + offset)
end

--- Status marker and its highlight for a thread.
function M.marker(thread, detached)
  local i = config.options.icons
  if thread.status ~= "open" then
    return i.resolved, "OverlaiMuted"
  end
  if detached then
    return i.detached, "DiagnosticError"
  end
  if model.awaiting(thread) == "human" then
    return i.your_turn, "OverlaiAuthorAgent"
  end
  return i.their_turn, "OverlaiMuted"
end

--- A line builder that records highlight spans.
function M.builder()
  local b = { lines = {}, hls = {} }
  --- Add a line from chunks { {text, hl?}, ... }.
  function b.add(chunks)
    local parts, col = {}, 0
    local row = #b.lines
    for _, c in ipairs(chunks) do
      parts[#parts + 1] = c[1]
      if c[2] then
        b.hls[#b.hls + 1] = { row, col, col + #c[1], c[2] }
      end
      col = col + #c[1]
    end
    b.lines[#b.lines + 1] = table.concat(parts)
    return row
  end
  function b.apply(buf, ns)
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for _, h in ipairs(b.hls) do
      vim.api.nvim_buf_set_extmark(buf, ns, h[1], h[2], { end_col = h[3], hl_group = h[4] })
    end
  end
  return b
end

local function author_hl(role)
  return role == "agent" and "OverlaiAuthorAgent" or "OverlaiAuthorHuman"
end

local function wrap(s, width)
  local out = {}
  for _, para in ipairs(vim.split(s, "\n", { plain = true })) do
    if para == "" then
      out[#out + 1] = ""
    else
      local line = ""
      for word in para:gmatch("%S+") do
        if line ~= "" and vim.fn.strdisplaywidth(line .. " " .. word) > width then
          out[#out + 1] = line
          line = word
        else
          line = line == "" and word or (line .. " " .. word)
        end
      end
      out[#out + 1] = line
    end
  end
  return out
end
M.wrap = wrap

--- Full thread for the thread window. `current` is the passage's text now.
function M.thread(b, thread, opts)
  local width = opts.width
  local status = thread.status
  local turn = model.awaiting(thread)
  if turn then
    status = turn == "human" and "your turn" or "waiting on agent"
  end
  b.add({
    { thread.id, "OverlaiId" },
    { "  " .. status, "OverlaiMuted" },
    { opts.line and ("  line " .. opts.line) or "  detached", "OverlaiMuted" },
  })
  for _, l in ipairs(wrap(opts.current or thread.anchor.quote, width - 2)) do
    b.add({ { "│ ", "OverlaiMuted" }, { l, "OverlaiMuted" } })
  end
  for _, m in ipairs(thread.messages) do
    b.add({ { "" } })
    b.add({ { m.author, author_hl(m.role) }, { "  " .. M.ago(m.created_at), "OverlaiMuted" } })
    if m.body ~= "" then
      for _, l in ipairs(wrap(m.body, width)) do
        b.add({ { l } })
      end
    end
    if m.suggestion then
      local s = m.suggestion
      local label = s.status == "pending" and "suggested edit" or ("suggested edit (" .. s.status .. ")")
      b.add({ { label, s.status == "pending" and "OverlaiTitle" or "OverlaiMuted" } })
      if s.status == "pending" then
        local old = opts.suggestion_current or (s.anchor and s.anchor.quote) or opts.current or thread.anchor.quote
        for _, l in ipairs(wrap(old, width - 2)) do
          b.add({ { "- " .. l, "OverlaiDelete" } })
        end
        for _, l in ipairs(wrap(s.text, width - 2)) do
          b.add({ { "+ " .. l, "OverlaiAdd" } })
        end
      else
        for _, l in ipairs(wrap(s.text, width - 2)) do
          b.add({ { "  " .. l, "OverlaiMuted" } })
        end
      end
    end
  end
end

--- Compact entry for the panel. Returns the header row.
function M.entry(b, thread, opts)
  local width = opts.width
  local o = config.options
  local icon, icon_hl = M.marker(thread, opts.detached)
  local where = opts.detached and "detached" or ("L" .. opts.line)
  local head = b.add({
    { " " .. icon, icon_hl },
    { thread.id, "OverlaiId" },
    { " " .. where .. " ", "OverlaiMuted" },
    { util.truncate("“" .. thread.anchor.quote .. "”", width - #thread.id - #where - 8) },
    { model.pending(thread) and (" " .. vim.trim(o.icons.suggestion)) or "", "OverlaiAdd" },
  })
  local n = o.panel.preview_messages
  local first = math.max(1, #thread.messages - n + 1)
  if first > 1 then
    b.add({ { ("    … %d earlier"):format(first - 1), "OverlaiMuted" } })
  end
  for i = first, #thread.messages do
    local m = thread.messages[i]
    local body = util.first_line(m.body)
    if body == "" and m.suggestion then
      body = "suggested an edit"
    end
    b.add({
      { "    " },
      { m.author, author_hl(m.role) },
      { " " .. util.truncate(body, width - #m.author - 6) },
    })
  end
  return head
end

return M
