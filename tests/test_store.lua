local H = require("tests.helpers")
local model = require("overlai.model")
local store = require("overlai.store")
local util = require("overlai.util")

local eq = MiniTest.expect.equality
local err = MiniTest.expect.error
local T = MiniTest.new_set()

T["paths mirror the file under .review at the git root"] = function()
  local dir = H.project({ ["readings/bayes.md"] = "x" })
  local p = store.paths(dir .. "/readings/bayes.md")
  eq(p.root, dir)
  eq(p.rel, "readings/bayes.md")
  eq(p.sidecar, dir .. "/.review/readings/bayes.md.json")
end

T["an existing .review directory wins over the git root"] = function()
  local dir = H.project({ ["book/ch1.md"] = "x" })
  vim.fn.mkdir(dir .. "/book/.review", "p")
  local p = store.paths(dir .. "/book/ch1.md")
  eq(p.root, dir .. "/book")
  eq(p.rel, "ch1.md")
end

T["without git or .review the file's directory is the root"] = function()
  local dir = vim.uv.fs_realpath(vim.fn.tempname() .. "") or vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  dir = vim.uv.fs_realpath(dir)
  H.write(dir .. "/note.txt", "x")
  local p = store.paths(dir .. "/note.txt")
  -- The temp dir may sit inside some git checkout; only check when it doesn't.
  if not vim.fs.find(".git", { path = dir, upward = true })[1] then
    eq(p.root, dir)
  end
  eq(vim.endswith(p.sidecar, "note.txt.json"), true)
end

T["load returns a new document when there is no file"] = function()
  local dir = H.project()
  local doc = store.load(dir .. "/.review/a.md.json", "a.md")
  eq(doc, model.new_doc("a.md"))
end

T["save and load round-trip, with stable formatting"] = function()
  local dir = H.project({ ["a.md"] = "hello" })
  local p = store.paths(dir .. "/a.md")
  local doc = model.new_doc("a.md")
  model.add_thread(doc, {
    anchor = { quote = "hello", prefix = "", suffix = "", line = 1 },
    author = "todd",
    role = "human",
    body = 'Quote "this" and\nnewlines',
  })
  local data = store.save(p.sidecar, doc)
  eq(store.load(p.sidecar, p.rel), doc)
  -- Re-encoding is byte-identical, so committed review files diff cleanly.
  eq(store.encode(store.load(p.sidecar, p.rel)), data)
  eq(data:find('"version": 1', 1, true) ~= nil, true)
  eq(data:find('"threads": [', 1, true) ~= nil, true)
end

T["empty lists encode as arrays"] = function()
  local s = util.json_encode(model.new_doc("a.md"))
  eq(s:find('"threads": []', 1, true) ~= nil, true)
end

T["load reports invalid JSON"] = function()
  local dir = H.project()
  local path = dir .. "/.review/a.md.json"
  vim.fn.mkdir(dir .. "/.review", "p")
  H.write(path, "{ not json")
  err(function()
    store.load(path, "a.md")
  end, "not valid JSON")
end

T["update is a locked read-modify-write"] = function()
  local dir = H.project({ ["a.md"] = "hello" })
  local p = store.paths(dir .. "/a.md")
  local doc, value = store.update(p, function(d)
    d.extra = 1
    return "ok"
  end)
  eq(value, "ok")
  eq(doc.extra, 1)
  eq(vim.uv.fs_stat(p.sidecar .. ".lock"), nil)
end

T["update releases the lock when fn fails"] = function()
  local dir = H.project({ ["a.md"] = "hello" })
  local p = store.paths(dir .. "/a.md")
  err(function()
    store.update(p, function()
      error("boom", 0)
    end)
  end, "boom")
  eq(vim.uv.fs_stat(p.sidecar .. ".lock"), nil)
end

T["a held lock times out; a stale one is broken"] = function()
  local dir = H.project({ ["a.md"] = "hello" })
  local p = store.paths(dir .. "/a.md")
  vim.fn.mkdir(p.sidecar .. ".lock", "p")
  local timeout = store.lock_timeout_ms
  store.lock_timeout_ms = 50
  err(function()
    store.update(p, function() end)
  end, "timed out")
  store.lock_timeout_ms = timeout
  -- Age the lock past the stale limit.
  local old = os.time() - store.stale_lock_s - 5
  vim.uv.fs_utime(p.sidecar .. ".lock", old, old)
  store.update(p, function() end)
  eq(store.exists(p.sidecar), true)
end

return T
