-- What the commands and keys do. Every action takes the source buffer and,
-- where it applies, a thread id (default: the thread under the cursor).

local anchor = require("overlai.anchor")
local buffer = require("overlai.buffer")
local compose = require("overlai.compose")
local config = require("overlai.config")
local model = require("overlai.model")
local text = require("overlai.text")

local M = {}

local function notify(msg, level)
  vim.notify("overlai: " .. msg, level or vim.log.levels.INFO)
end

local function source_buf(buf)
  if buf and buf ~= 0 then
    return buf
  end
  local cur = vim.api.nvim_get_current_buf()
  local panel = require("overlai.panel")
  if vim.bo[cur].filetype == "overlai" and panel.source() then
    return panel.source()
  end
  return cur
end

local function me()
  return { author = config.author(), role = "human" }
end

--- The thread to act on: the given id, the panel's line, or the thread under
--- the cursor. Notifies and returns nil when there is none.
local function pick(buf, id)
  local st = buffer.get(buf)
  if not st then
    notify("no review on this buffer", vim.log.levels.WARN)
    return nil
  end
  if not id and vim.bo[vim.api.nvim_get_current_buf()].filetype == "overlai" then
    id = require("overlai.panel").id_at_cursor()
  end
  if not id and vim.api.nvim_get_current_buf() == buf then
    local cur = vim.api.nvim_win_get_cursor(0)
    local t = buffer.thread_at(buf, cur[1] - 1, cur[2], { resolved = true })
    id = t and t.id
  end
  local t = id and model.find(st.doc, id)
  if not t then
    notify(id and ("no thread " .. id) or "no thread under the cursor", vim.log.levels.WARN)
    return nil
  end
  return t
end

--- Range of the last visual selection: { srow, scol, erow, ecol }, 0-based
--- with an exclusive end.
function M.visual_range(buf)
  local s = vim.api.nvim_buf_get_mark(buf, "<")
  local e = vim.api.nvim_buf_get_mark(buf, ">")
  if s[1] == 0 or e[1] == 0 then
    return nil
  end
  local mode = vim.fn.visualmode()
  local sr, sc, er, ec = s[1] - 1, s[2], e[1] - 1, e[2]
  local last = vim.api.nvim_buf_get_lines(buf, er, er + 1, false)[1] or ""
  if mode == "V" then
    sc = 0
    ec = #last
  else
    ec = math.min(ec, #last - 1)
    if #last == 0 then
      ec = 0
    else
      -- Include the whole of the selection's last character.
      ec = ec + vim.str_utf_end(last, ec + 1) + 1
    end
  end
  if sr == er and sc >= ec then
    return nil
  end
  return { sr, sc, er, ec }
end

--- The current line, without its leading and trailing whitespace.
function M.line_range(buf)
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  local _, s = line:find("^%s*")
  local e = #(line:gsub("%s+$", ""))
  if s >= e then
    return nil
  end
  return { row, s, row, e }
end

--- Range for a command given one: the visual selection, or whole lines for
--- a typed range. Nil without a range.
local function command_range(buf, cmd_opts)
  if cmd_opts and cmd_opts.range and cmd_opts.range > 0 then
    local r = M.visual_range(buf)
    -- A typed :10,12Overlai has no matching visual marks; use whole lines.
    if r and r[1] + 1 == cmd_opts.line1 and r[3] + 1 == cmd_opts.line2 then
      return r
    end
    local last = vim.api.nvim_buf_get_lines(buf, cmd_opts.line2 - 1, cmd_opts.line2, false)[1] or ""
    return { cmd_opts.line1 - 1, 0, cmd_opts.line2 - 1, #last }
  end
  return nil
end

local function anchor_for_range(buf, r)
  local content = buffer.content(buf)
  local starts = text.line_starts(content)
  local a, b = buffer.range_to_offsets(starts, #content, r)
  return anchor.from_range(content, a, b), content:sub(a, b - 1)
end

local function range_text(buf, r)
  return table.concat(vim.api.nvim_buf_get_text(buf, r[1], r[2], r[3], r[4], {}), "\n")
end

-- A new thread is anchored against the buffer, which may have unsaved edits;
-- its anchor is rewritten from the tracker when the buffer is written.
function M.comment(buf, cmd_opts)
  buf = source_buf(buf)
  local r = command_range(buf, cmd_opts) or M.line_range(buf)
  if not r then
    return notify("select the passage to comment on", vim.log.levels.WARN)
  end
  buffer.attach(buf, true)
  local anc = anchor_for_range(buf, r)
  compose.open({
    title = "Comment",
    on_submit = function(body)
      buffer.update(buf, function(doc)
        return model.add_thread(doc, vim.tbl_extend("force", me(), { anchor = anc, body = body }))
      end)
    end,
  })
end

function M.suggest(buf, cmd_opts)
  buf = source_buf(buf)
  local r = command_range(buf, cmd_opts)
  if r then
    buffer.attach(buf, true)
    local anc, current = anchor_for_range(buf, r)
    return compose.open({
      title = "Suggest replacement text",
      initial = current,
      on_submit = function(new)
        if new == current then
          return notify("the suggestion is identical to the current text", vim.log.levels.WARN)
        end
        buffer.update(buf, function(doc)
          return model.add_thread(doc, vim.tbl_extend("force", me(), {
            anchor = anc,
            suggestion = { text = new },
          }))
        end)
      end,
    })
  end
  -- No selection: suggest a new wording for the thread under the cursor.
  local t = pick(buf)
  if not t then
    return
  end
  local sr = buffer.thread_range(buf, t.id)
  if not sr then
    return notify("this thread's passage is detached; reanchor it first", vim.log.levels.WARN)
  end
  local current = range_text(buf, sr)
  local id = t.id
  compose.open({
    title = "Suggest replacement for " .. id,
    initial = current,
    on_submit = function(new)
      buffer.update(buf, function(doc)
        model.add_message(model.get(doc, id), vim.tbl_extend("force", me(), { suggestion = { text = new } }))
      end)
    end,
  })
end

function M.reply(buf, id)
  buf = source_buf(buf)
  local t = pick(buf, id)
  if not t then
    return
  end
  id = t.id
  compose.open({
    title = "Reply to " .. id,
    on_submit = function(body)
      buffer.update(buf, function(doc)
        model.add_message(model.get(doc, id), vim.tbl_extend("force", me(), { body = body }))
      end)
    end,
  })
end

function M.accept(buf, id)
  buf = source_buf(buf)
  local t = pick(buf, id)
  if not t then
    return
  end
  local msg = model.pending(t)
  if not msg then
    return notify(t.id .. " has no suggested edit to accept; reply to it, or resolve it if it's settled", vim.log.levels.WARN)
  end
  local r = buffer.suggestion_range(buf, t)
  if not r then
    return notify("the text this suggestion replaces is no longer in the buffer", vim.log.levels.WARN)
  end
  vim.api.nvim_buf_set_text(buf, r[1], r[2], r[3], r[4], vim.split(msg.suggestion.text, "\n", { plain = true }))
  id = t.id
  buffer.update(buf, function(doc)
    model.accept(model.get(doc, id), config.author())
  end)
  notify("accepted the suggestion on " .. id)
end

function M.reject(buf, id)
  buf = source_buf(buf)
  local t = pick(buf, id)
  if not t then
    return
  end
  if not model.pending(t) then
    return notify(t.id .. " has no suggested edit to reject", vim.log.levels.WARN)
  end
  id = t.id
  buffer.update(buf, function(doc)
    model.reject(model.get(doc, id))
  end)
end

function M.resolve(buf, id)
  buf = source_buf(buf)
  local t = pick(buf, id)
  if t then
    id = t.id
    buffer.update(buf, function(doc)
      model.resolve(model.get(doc, id), config.author())
    end)
    notify("resolved " .. id)
  end
end

function M.reopen(buf, id)
  buf = source_buf(buf)
  local t = pick(buf, id)
  if t then
    id = t.id
    buffer.update(buf, function(doc)
      model.reopen(model.get(doc, id))
    end)
    notify("reopened " .. id)
  end
end

function M.toggle_resolved(buf, id)
  buf = source_buf(buf)
  local t = pick(buf, id)
  if not t then
    return
  end
  if t.status == "open" then
    M.resolve(buf, t.id)
  else
    M.reopen(buf, t.id)
  end
end

function M.delete(buf, id)
  buf = source_buf(buf)
  local t = pick(buf, id)
  if not t then
    return
  end
  local choice = vim.fn.confirm(("Delete thread %s (%d messages)?"):format(t.id, #t.messages), "&Yes\n&No", 2)
  if choice ~= 1 then
    return
  end
  id = t.id
  buffer.update(buf, function(doc)
    model.delete(doc, id)
  end)
end

--- Move the cursor to a thread's passage.
function M.jump(buf, id, opts)
  buf = source_buf(buf)
  local r = buffer.thread_range(buf, id)
  if not r then
    return notify(id .. " is detached from the text", vim.log.levels.WARN)
  end
  local win = require("overlai.panel")._source_win()
  if opts and opts.focus and win then
    vim.api.nvim_set_current_win(win)
  end
  if vim.api.nvim_get_current_buf() == buf then
    vim.api.nvim_win_set_cursor(0, { r[1] + 1, r[2] })
  end
end

function M.show(buf, id)
  buf = source_buf(buf)
  local t = pick(buf, id)
  if t then
    require("overlai.view").open(buf, t.id)
  end
end

--- Jump to the next (dir = 1) or previous (dir = -1) open thread.
function M.goto(buf, dir)
  buf = source_buf(buf)
  local items = vim.tbl_filter(function(i)
    return i.range ~= nil
  end, buffer.threads(buf))
  if #items == 0 then
    return notify("no open threads")
  end
  local cur = vim.api.nvim_win_get_cursor(0)
  local row, col = cur[1] - 1, cur[2]
  local function after(r)
    return r[1] > row or (r[1] == row and r[2] > col)
  end
  local target
  if dir > 0 then
    for _, i in ipairs(items) do
      if after(i.range) then
        target = i
        break
      end
    end
    target = target or items[1]
  else
    for k = #items, 1, -1 do
      local r = items[k].range
      if r[1] < row or (r[1] == row and r[2] < col) then
        target = items[k]
        break
      end
    end
    target = target or items[#items]
  end
  vim.cmd("normal! m'")
  vim.api.nvim_win_set_cursor(0, { target.range[1] + 1, target.range[2] })
end

--- Attach a detached thread to the selected text.
function M.reanchor(buf, cmd_opts, id)
  buf = source_buf(buf)
  local st = buffer.get(buf)
  if not st then
    return notify("no review on this buffer", vim.log.levels.WARN)
  end
  local r = command_range(buf, cmd_opts) or M.line_range(buf)
  if not r then
    return notify("select the passage to attach the thread to", vim.log.levels.WARN)
  end
  local anc = anchor_for_range(buf, r)
  local function apply(tid)
    -- Drop the old tracker so the new anchor is placed fresh.
    local mark = st.trackers[tid]
    if mark then
      pcall(vim.api.nvim_buf_del_extmark, buf, buffer.ns, mark)
      st.trackers[tid] = nil
    end
    buffer.update(buf, function(doc)
      model.get(doc, tid).anchor = anc
    end)
  end
  if id then
    return apply(id)
  end
  local detached = vim.tbl_filter(function(i)
    return i.range == nil
  end, buffer.threads(buf, { resolved = true }))
  if #detached == 0 then
    return notify("no detached threads")
  end
  vim.ui.select(detached, {
    prompt = "Attach which thread?",
    format_item = function(i)
      return ('%s "%s"'):format(i.thread.id, require("overlai.util").truncate(i.thread.anchor.quote, 50))
    end,
  }, function(choice)
    if choice then
      apply(choice.thread.id)
    end
  end)
end

function M.ask(buf, agent_name, instructions)
  buf = source_buf(buf)
  require("overlai.agent").run(buf, { agent = agent_name, instructions = instructions })
end

function M.cancel(buf)
  require("overlai.agent").cancel(source_buf(buf))
end

return M
