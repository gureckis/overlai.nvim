-- The review document: threads of messages anchored to passages, some carrying
-- a suggested replacement. Pure data operations; no I/O.
--
--   doc     = { version, file, next_id, threads = { thread... } }
--   thread  = { id, status = "open"|"resolved", anchor, created_at,
--               resolved_at?, resolved_by?, messages = { message... } }
--   message = { author, role = "human"|"agent", body, created_at,
--               suggestion? }
--   suggestion = { text, status = "pending"|"accepted"|"rejected"|"superseded",
--                  anchor? }   -- anchor only when it targets other text
--                               -- than the thread's own anchor

local util = require("overlai.util")

local M = {}

M.VERSION = 1

local function fail(msg, ...)
  error("overlai: " .. msg:format(...), 0)
end

function M.new_doc(rel)
  return { version = M.VERSION, file = rel, next_id = 1, threads = {} }
end

function M.check_doc(doc)
  if type(doc) ~= "table" or type(doc.threads) ~= "table" then
    fail("not a overlai review file")
  end
  if (doc.version or 0) > M.VERSION then
    fail("review file version %s is newer than this plugin (%d); update overlai", doc.version, M.VERSION)
  end
  doc.next_id = doc.next_id or (#doc.threads + 1)
  for _, t in ipairs(doc.threads) do
    t.messages = t.messages or {}
  end
  return doc
end

function M.find(doc, id)
  for i, t in ipairs(doc.threads) do
    if t.id == id then
      return t, i
    end
  end
end

function M.get(doc, id)
  local t = M.find(doc, id)
  if not t then
    fail("no thread %s", tostring(id))
  end
  return t
end

function M.last_message(thread)
  return thread.messages[#thread.messages]
end

--- The message carrying the thread's live suggestion, if any.
function M.pending(thread)
  for i = #thread.messages, 1, -1 do
    local s = thread.messages[i].suggestion
    if s and s.status == "pending" then
      return thread.messages[i], i
    end
  end
end

--- Whose turn it is on an open thread: "agent" when a human spoke last,
--- "human" when an agent did.
function M.awaiting(thread)
  if thread.status ~= "open" then
    return nil
  end
  local last = M.last_message(thread)
  if not last then
    return nil
  end
  return last.role == "human" and "agent" or "human"
end

--- The author who started the thread.
function M.opener(thread)
  return thread.messages[1]
end

local function check_role(role)
  if role ~= "human" and role ~= "agent" then
    fail("role must be human or agent, not %s", tostring(role))
  end
end

--- Append a message. `opts` = { author, role, body?, suggestion? } where
--- suggestion = { text, anchor? }. A new suggestion supersedes an older
--- pending one.
function M.add_message(thread, opts)
  check_role(opts.role)
  local body = opts.body and vim.trim(opts.body) or ""
  if body == "" and not opts.suggestion then
    fail("a message needs a body or a suggestion")
  end
  local msg = {
    author = opts.author or opts.role,
    role = opts.role,
    body = body,
    created_at = opts.created_at or util.now(),
  }
  if opts.suggestion then
    local old = M.pending(thread)
    if old then
      old.suggestion.status = "superseded"
    end
    msg.suggestion = {
      text = opts.suggestion.text,
      status = "pending",
      anchor = opts.suggestion.anchor,
    }
  end
  thread.messages[#thread.messages + 1] = msg
  if thread.status == "resolved" then
    thread.status = "open"
    thread.resolved_at, thread.resolved_by = nil, nil
  end
  return msg
end

--- Start a thread. `opts` = { anchor, author, role, body?, suggestion? }.
function M.add_thread(doc, opts)
  if not opts.anchor or (opts.anchor.quote or "") == "" then
    fail("a thread needs a passage to anchor to")
  end
  local thread = {
    id = "t" .. doc.next_id,
    status = "open",
    anchor = opts.anchor,
    created_at = opts.created_at or util.now(),
    messages = {},
  }
  doc.next_id = doc.next_id + 1
  M.add_message(thread, opts)
  doc.threads[#doc.threads + 1] = thread
  return thread
end

function M.resolve(thread, by)
  local msg = M.pending(thread)
  if msg then
    msg.suggestion.status = "rejected"
  end
  thread.status = "resolved"
  thread.resolved_at = util.now()
  thread.resolved_by = by
end

function M.reopen(thread)
  thread.status = "open"
  thread.resolved_at, thread.resolved_by = nil, nil
end

--- Mark the pending suggestion accepted and resolve the thread. The caller
--- applies the text change. Returns the suggestion.
function M.accept(thread, by)
  local msg = M.pending(thread)
  if not msg then
    fail("thread %s has no pending suggestion", thread.id)
  end
  msg.suggestion.status = "accepted"
  thread.status = "resolved"
  thread.resolved_at = util.now()
  thread.resolved_by = by
  return msg.suggestion
end

--- Mark the pending suggestion rejected. The thread stays open so the
--- discussion can go on.
function M.reject(thread)
  local msg = M.pending(thread)
  if not msg then
    fail("thread %s has no pending suggestion", thread.id)
  end
  msg.suggestion.status = "rejected"
  return msg.suggestion
end

function M.delete(doc, id)
  local _, i = M.find(doc, id)
  if not i then
    fail("no thread %s", tostring(id))
  end
  table.remove(doc.threads, i)
end

--- The anchor a suggestion replaces: its own, or its thread's.
function M.suggestion_anchor(thread, suggestion)
  return suggestion.anchor or thread.anchor
end

return M
