local H = require("tests.helpers")

local eq = MiniTest.expect.equality
local child = H.child()

local DOC = table.concat({
  "# Bayes",
  "",
  "We multiply the prior by the likelihood and",
  "normalize to get the posterior. The likelihood",
  "is the key quantity.",
}, "\n") .. "\n"

local dir, file

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      dir = H.project({ ["doc.md"] = DOC })
      file = dir .. "/doc.md"
      child.setup()
      child.lua([[
        _G.notes = {}
        vim.notify = function(msg, level) table.insert(_G.notes, { msg = msg, level = level }) end
      ]])
    end,
    post_once = child.stop,
  },
})

local human = { env = { OVERLAI_AUTHOR = "todd", OVERLAI_ROLE = "human" } }

local function edit()
  child.cmd("edit " .. file)
end

local function lines()
  return child.api.nvim_buf_get_lines(0, 0, -1, false)
end

local function threads()
  return child.lua_get("#require('overlai.buffer').get(0).doc.threads")
end

local function render_marks()
  return child.lua_get("vim.api.nvim_buf_get_extmarks(0, require('overlai.render').ns, 0, -1, { details = true })")
end

local function notes()
  return child.lua_get("vim.tbl_map(function(n) return n.msg end, _G.notes)")
end

-- Select `n` characters starting at (line, col) (1-based line, 0-based col)
-- and leave visual mode, so '< and '> hold the selection.
local function select_chars(line, col, n)
  child.api.nvim_win_set_cursor(0, { line, col })
  child.type_keys("v", tostring(n - 1) .. "l", "<Esc>")
end

T["attaches to files that have a review file and draws them"] = function()
  H.cli({ "comment", file, "--quote", "the likelihood", "--line", "3", "--body", "Too terse?" }, human)
  edit()
  eq(child.lua_get("require('overlai.buffer').get(0) ~= nil"), true)
  local marks = render_marks()
  local kinds = {}
  for _, m in ipairs(marks) do
    local d = m[4]
    if d.hl_group == "OverlaiRange" then
      kinds.range = { m[2], m[3], d.end_row, d.end_col }
    elseif d.sign_text then
      kinds.sign = m[2]
    elseif d.virt_text then
      kinds.preview = d.virt_text[1][1]
    end
  end
  eq(kinds.range, { 2, 25, 2, 39 })
  eq(kinds.sign, 2)
  eq(kinds.preview:find("todd: Too terse?", 1, true) ~= nil, true)
end

T["does not attach to files without one"] = function()
  edit()
  eq(child.lua_get("require('overlai.buffer').get(0) == nil"), true)
  eq(vim.uv.fs_stat(dir .. "/.review"), nil)
end

T["comments on a visual selection through the compose window"] = function()
  edit()
  select_chars(3, 25, 14) -- "the likelihood"
  child.cmd("'<,'>Overlai comment")
  eq(child.bo.filetype, "markdown")
  eq(child.fn.mode(), "i")
  child.type_keys("Too terse?", "<C-s>")
  local doc = H.doc(dir, "doc.md")
  eq(#doc.threads, 1)
  eq(doc.threads[1].anchor.quote, "the likelihood")
  eq(doc.threads[1].messages[1], {
    author = "todd",
    role = "human",
    body = "Too terse?",
    created_at = doc.threads[1].messages[1].created_at,
  })
end

T["comments on the current line without a selection"] = function()
  edit()
  child.api.nvim_win_set_cursor(0, { 5, 0 })
  child.cmd("Overlai comment")
  child.type_keys("Whole line", "<C-s>")
  eq(H.doc(dir, "doc.md").threads[1].anchor.quote, "is the key quantity.")
end

T["linewise selections cover whole lines"] = function()
  edit()
  child.api.nvim_win_set_cursor(0, { 3, 4 })
  child.type_keys("Vj", "<Esc>")
  child.cmd("'<,'>Overlai comment")
  child.type_keys("Para", "<C-s>")
  eq(H.doc(dir, "doc.md").threads[1].anchor.quote, "We multiply the prior by the likelihood and\nnormalize to get the posterior. The likelihood")
end

T["compose can be cancelled"] = function()
  edit()
  select_chars(3, 25, 14)
  child.cmd("'<,'>Overlai comment")
  child.type_keys("never mind", "<Esc>", "q")
  eq(H.read(H.sidecar(dir, "doc.md")) == nil or #H.doc(dir, "doc.md").threads == 0, true)
end

T["suggests a replacement for a selection"] = function()
  edit()
  select_chars(5, 3, 16) -- "the key quantity"
  child.cmd("'<,'>Overlai suggest")
  -- The compose window starts with the selected text.
  eq(lines(), { "the key quantity" })
  child.type_keys("$", "ciw", "matters", "<Esc>", "<C-s>")
  local t = H.doc(dir, "doc.md").threads[1]
  eq(t.messages[1].suggestion.text, "the key matters")
end

T["anchors follow edits and are saved on write"] = function()
  H.cli({ "comment", file, "--quote", "the key quantity", "--body", "Vague" }, human)
  edit()
  child.api.nvim_buf_set_lines(0, 0, 0, false, { "New first line", "" })
  child.cmd("write")
  local anc = H.doc(dir, "doc.md").threads[1].anchor
  eq(anc.line, 7)
  eq(anc.quote, "the key quantity")
end

T["edits inside a passage update its quote on write"] = function()
  H.cli({ "comment", file, "--quote", "the key quantity", "--body", "Vague" }, human)
  edit()
  child.api.nvim_buf_set_text(0, 4, 7, 4, 10, { "central" })
  child.cmd("write")
  eq(H.doc(dir, "doc.md").threads[1].anchor.quote, "the central quantity")
end

T["accepts a suggestion into the buffer"] = function()
  H.cli({ "comment", file, "--quote", "the key quantity", "--body", "Vague" }, human)
  H.cli({ "reply", file, "t1", "--body", "Sharper", "--suggest", "what carries\nthe evidence" })
  edit()
  -- Pending suggestions are drawn as tracked changes.
  local struck, virt = false, false
  for _, m in ipairs(render_marks()) do
    struck = struck or m[4].hl_group == "OverlaiDelete"
    virt = virt or m[4].virt_lines ~= nil
  end
  eq({ struck, virt }, { true, true })
  child.api.nvim_win_set_cursor(0, { 5, 5 })
  child.cmd("Overlai accept")
  eq(lines()[5], "is what carries")
  eq(lines()[6], "the evidence.")
  local t = H.doc(dir, "doc.md").threads[1]
  eq(t.status, "resolved")
  eq(t.messages[2].suggestion.status, "accepted")
end

T["accepts a suggestion that targets other text"] = function()
  H.cli({ "comment", file, "--quote", "the key quantity", "--body", "Rework" }, human)
  H.cli({ "reply", file, "t1", "--suggest", "We combine prior and likelihood.", "--quote", "We multiply the prior by" })
  edit()
  child.lua("require('overlai.actions').accept(0, 't1')")
  eq(lines()[3], "We combine prior and likelihood. the likelihood and")
end

T["rejects a suggestion and keeps the thread open"] = function()
  H.cli({ "comment", file, "--quote", "the key quantity", "--body", "Vague" }, human)
  H.cli({ "reply", file, "t1", "--suggest", "the crux" })
  edit()
  child.lua("require('overlai.actions').reject(0, 't1')")
  eq(lines()[5], "is the key quantity.")
  local t = H.doc(dir, "doc.md").threads[1]
  eq({ t.status, t.messages[2].suggestion.status }, { "open", "rejected" })
end

T["replies, resolves and reopens"] = function()
  H.cli({ "comment", file, "--quote", "the key quantity", "--body", "Which?" })
  edit()
  child.api.nvim_win_set_cursor(0, { 5, 5 })
  child.cmd("Overlai reply")
  child.type_keys("The likelihood.", "<C-s>")
  child.cmd("Overlai resolve")
  local t = H.doc(dir, "doc.md").threads[1]
  eq(t.messages[2].body, "The likelihood.")
  eq({ t.status, t.resolved_by }, { "resolved", "todd" })
  -- Resolved threads are hidden.
  eq(#render_marks(), 0)
  child.lua("require('overlai.actions').reopen(0, 't1')")
  eq(H.doc(dir, "doc.md").threads[1].status, "open")
end

T["deletes a thread after confirmation"] = function()
  H.cli({ "comment", file, "--quote", "the key quantity", "--body", "x" }, human)
  edit()
  child.lua("vim.fn.confirm = function() return 1 end")
  child.lua("require('overlai.actions').delete(0, 't1')")
  eq(#H.doc(dir, "doc.md").threads, 0)
end

T["reloads when the review file changes on disk"] = function()
  H.cli({ "comment", file, "--quote", "the key quantity", "--body", "x" }, human)
  edit()
  eq(threads(), 1)
  H.cli({ "comment", file, "--quote", "# Bayes", "--body", "Title?" })
  H.wait(child, "#require('overlai.buffer').get(0).doc.threads == 2")
end

T["moves between threads"] = function()
  H.cli({ "comment", file, "--quote", "# Bayes", "--body", "a" }, human)
  H.cli({ "comment", file, "--quote", "the key quantity", "--body", "b" }, human)
  edit()
  child.api.nvim_win_set_cursor(0, { 3, 0 })
  child.cmd("Overlai next")
  eq(child.api.nvim_win_get_cursor(0), { 5, 3 })
  child.cmd("Overlai next") -- wraps
  eq(child.api.nvim_win_get_cursor(0), { 1, 0 })
  child.cmd("Overlai prev") -- wraps back
  eq(child.api.nvim_win_get_cursor(0), { 5, 3 })
end

T["the panel lists threads and follows the cursor"] = function()
  H.cli({ "comment", file, "--quote", "# Bayes", "--body", "Title?" }, human)
  H.cli({ "comment", file, "--quote", "the key quantity", "--body", "Vague" }, human)
  H.cli({ "reply", file, "t2", "--body", "Agreed", "--suggest", "the crux" })
  edit()
  child.cmd("Overlai panel")
  local panel_buf = child.lua_get("vim.fn.bufnr('overlai://panel')")
  local text = table.concat(child.api.nvim_buf_get_lines(panel_buf, 0, -1, false), "\n")
  eq(text:find("doc.md", 1, true) ~= nil, true)
  eq(text:find("2 open · 1 your turn · 0 resolved", 1, true) ~= nil, true)
  eq(text:find("t1 L1", 1, true) ~= nil, true)
  eq(text:find("t2 L5", 1, true) ~= nil, true)
  eq(text:find("claude Agreed", 1, true) ~= nil, true)
  -- Focus stays in the document.
  eq(child.api.nvim_get_current_buf() ~= panel_buf, true)

  child.api.nvim_win_set_cursor(0, { 5, 6 })
  child.lua("vim.api.nvim_exec_autocmds('CursorMoved', {})")
  local panel_win = child.fn.bufwinid(panel_buf)
  local row = child.api.nvim_win_get_cursor(panel_win)[1]
  eq(child.api.nvim_buf_get_lines(panel_buf, row - 1, row, false)[1]:find("t2", 1, true) ~= nil, true)

  -- Moving through the panel shows each passage, leaving focus in the panel.
  child.api.nvim_set_current_win(panel_win)
  local source_win = child.fn.win_getid(child.fn.winnr("#"))
  child.type_keys("gg", "]]")
  row = child.api.nvim_win_get_cursor(panel_win)[1]
  eq(child.api.nvim_buf_get_lines(panel_buf, row - 1, row, false)[1]:find("t1", 1, true) ~= nil, true)
  eq(child.api.nvim_win_get_cursor(source_win)[1], 1)
  child.type_keys("]]")
  eq(child.api.nvim_win_get_cursor(source_win), { 5, 3 })
  eq(child.api.nvim_get_current_win(), panel_win)
  child.type_keys("[[")
  eq(child.api.nvim_win_get_cursor(source_win)[1], 1)
  child.type_keys("]]")

  -- Accepting from the panel.
  child.type_keys("a")
  eq(child.lua_get("vim.fn.getbufline(vim.fn.bufnr(...), 5)[1]", { file }), "is the crux.")
  child.cmd("Overlai panel")
  eq(child.fn.bufwinid(panel_buf), -1)
end

T["the thread window shows the conversation and the diff"] = function()
  H.cli({ "comment", file, "--quote", "the key quantity", "--body", "Vague" }, human)
  H.cli({ "reply", file, "t1", "--body", "Try this", "--suggest", "the crux" })
  edit()
  child.api.nvim_win_set_cursor(0, { 5, 5 })
  child.cmd("Overlai show")
  local text = table.concat(lines(), "\n")
  eq(text:find("t1  your turn  line 5", 1, true) ~= nil, true)
  eq(text:find("Vague", 1, true) ~= nil, true)
  eq(text:find("- the key quantity", 1, true) ~= nil, true)
  eq(text:find("+ the crux", 1, true) ~= nil, true)
  child.type_keys("q")
  eq(child.bo.filetype, "markdown")
end

T["the thread window offers accept and reject only for a suggestion"] = function()
  local function footer()
    child.api.nvim_win_set_cursor(0, { 5, 5 })
    child.cmd("Overlai show")
    local f = child.lua_get(
      "vim.fn.join(vim.tbl_map(function(c) return c[1] end, vim.api.nvim_win_get_config(0).footer), '')"
    )
    child.type_keys("q")
    return f
  end
  H.cli({ "comment", file, "--quote", "the key quantity", "--body", "Vague" }, human)
  edit()
  local plain = footer()
  eq(plain:find("accept", 1, true), nil)
  eq(plain:find("reject", 1, true), nil)
  eq(plain:find("resolve", 1, true) ~= nil, true)
  H.cli({ "reply", file, "t1", "--body", "Try this", "--suggest", "the crux" })
  child.cmd("edit")
  local offered = footer()
  eq(offered:find("accept", 1, true) ~= nil, true)
  eq(offered:find("reject", 1, true) ~= nil, true)
end

T["detached threads can be reattached"] = function()
  H.cli({ "comment", file, "--quote", "is the key quantity.", "--body", "x" }, human)
  H.write(file, (DOC:gsub("is the key quantity%.", "matters.")))
  edit()
  eq(child.lua_get("require('overlai.buffer').thread_range(0, 't1')"), vim.NIL)
  select_chars(5, 0, 8) -- "matters."
  child.cmd("'<,'>Overlai reanchor t1")
  eq(child.lua_get("require('overlai.buffer').thread_range(0, 't1')"), { 4, 0, 4, 8 })
  eq(H.doc(dir, "doc.md").threads[1].anchor.quote, "matters.")
end

T["complains helpfully when there is no thread"] = function()
  H.cli({ "comment", file, "--quote", "# Bayes", "--body", "a" }, human)
  edit()
  child.api.nvim_win_set_cursor(0, { 5, 0 })
  child.cmd("Overlai accept")
  eq(notes()[#notes()], "overlai: no thread under the cursor")
end

T["completes subcommands"] = function()
  local got = child.lua_get("require('overlai').complete('re', 'Overlai re')")
  eq(got, { "reanchor", "reject", "reopen", "reply", "resolve" })
end

return T
