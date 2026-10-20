local model = require("overlai.model")

local eq = MiniTest.expect.equality
local err = MiniTest.expect.error
local T = MiniTest.new_set()

local anc = { quote = "x", prefix = "", suffix = "", line = 1 }

local function doc_with_thread()
  local doc = model.new_doc("a.md")
  local t = model.add_thread(doc, { anchor = anc, author = "todd", role = "human", body = "Too terse?" })
  return doc, t
end

T["add_thread assigns sequential ids"] = function()
  local doc = model.new_doc("a.md")
  local t1 = model.add_thread(doc, { anchor = anc, role = "human", body = "one" })
  local t2 = model.add_thread(doc, { anchor = anc, role = "human", body = "two" })
  eq({ t1.id, t2.id, doc.next_id }, { "t1", "t2", 3 })
  model.delete(doc, "t1")
  eq(model.add_thread(doc, { anchor = anc, role = "human", body = "three" }).id, "t3")
end

T["add_thread needs an anchor and a body or suggestion"] = function()
  local doc = model.new_doc("a.md")
  err(function()
    model.add_thread(doc, { anchor = { quote = "" }, role = "human", body = "x" })
  end, "passage")
  err(function()
    model.add_thread(doc, { anchor = anc, role = "human", body = "  " })
  end, "body or a suggestion")
  local t = model.add_thread(doc, { anchor = anc, role = "human", suggestion = { text = "y" } })
  eq(t.messages[1].body, "")
end

T["roles are validated"] = function()
  local _, t = doc_with_thread()
  err(function()
    model.add_message(t, { role = "robot", body = "hi" })
  end, "role")
end

T["awaiting tracks whose turn it is"] = function()
  local _, t = doc_with_thread()
  eq(model.awaiting(t), "agent")
  model.add_message(t, { author = "claude", role = "agent", body = "Which part?" })
  eq(model.awaiting(t), "human")
  model.resolve(t, "todd")
  eq(model.awaiting(t), nil)
end

T["a new suggestion supersedes the pending one"] = function()
  local _, t = doc_with_thread()
  model.add_message(t, { role = "agent", suggestion = { text = "v1" } })
  model.add_message(t, { role = "agent", suggestion = { text = "v2" } })
  eq(t.messages[2].suggestion.status, "superseded")
  local msg = model.pending(t)
  eq(msg.suggestion.text, "v2")
end

T["accept marks the suggestion and resolves"] = function()
  local _, t = doc_with_thread()
  model.add_message(t, { role = "agent", suggestion = { text = "v1" } })
  local s = model.accept(t, "todd")
  eq(s.status, "accepted")
  eq(t.status, "resolved")
  eq(t.resolved_by, "todd")
  eq(model.pending(t), nil)
  err(function()
    model.accept(t)
  end, "no pending suggestion")
end

T["reject keeps the thread open"] = function()
  local _, t = doc_with_thread()
  model.add_message(t, { role = "agent", suggestion = { text = "v1" } })
  model.reject(t)
  eq(t.status, "open")
  eq(t.messages[2].suggestion.status, "rejected")
end

T["resolve rejects a pending suggestion; reopen clears resolution"] = function()
  local _, t = doc_with_thread()
  model.add_message(t, { role = "agent", suggestion = { text = "v1" } })
  model.resolve(t, "todd")
  eq(t.messages[2].suggestion.status, "rejected")
  model.reopen(t)
  eq({ t.status, t.resolved_by, t.resolved_at }, { "open", nil, nil })
end

T["a message on a resolved thread reopens it"] = function()
  local _, t = doc_with_thread()
  model.resolve(t, "todd")
  model.add_message(t, { role = "human", body = "Actually, one more thing" })
  eq(t.status, "open")
end

T["check_doc refuses newer versions and fills defaults"] = function()
  err(function()
    model.check_doc({ version = 99, threads = {} })
  end, "newer")
  local doc = model.check_doc({ version = 1, threads = { { id = "t1" } } })
  eq(doc.next_id, 2)
  eq(doc.threads[1].messages, {})
  err(function()
    model.check_doc({})
  end, "not a overlai")
end

T["get and delete report unknown ids"] = function()
  local doc = doc_with_thread()
  err(function()
    model.get(doc, "t9")
  end, "no thread t9")
  err(function()
    model.delete(doc, "t9")
  end, "no thread t9")
end

return T
