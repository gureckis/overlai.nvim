local H = require("tests.helpers")
local cli = require("overlai.cli")

local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

local DOC = table.concat({
  "# Bayes",
  "",
  "We multiply the prior by the likelihood and",
  "normalize to get the posterior. The likelihood",
  "is the key quantity.",
  "",
}, "\n")

local dir, file
local function setup()
  dir = H.project({ ["doc.md"] = DOC })
  file = dir .. "/doc.md"
end

local function has(s, needle)
  if not s:find(needle, 1, true) then
    error(("expected to find %q in:\n%s"):format(needle, s), 2)
  end
end

local human = { env = { OVERLAI_AUTHOR = "todd", OVERLAI_ROLE = "human" } }

T["parse"] = MiniTest.new_set()

T["parse"]["reads flags, values and positionals"] = function()
  local args = cli.parse({ "reply", "f.md", "t1", "--body", "hi", "--json", "--as=claude" })
  eq(args._, { "reply", "f.md", "t1" })
  eq({ args.body, args.json, args.as }, { "hi", true, "claude" })
end

T["parse"]["complains about a missing value"] = function()
  MiniTest.expect.error(function()
    cli.parse({ "reply", "f.md", "t1", "--body" })
  end, "needs a value")
end

T["commands"] = MiniTest.new_set({ hooks = { pre_case = setup } })

T["commands"]["help and unknown commands"] = function()
  local code, out = H.cli({ "help" })
  eq(code, 0)
  has(out, "usage: overlai")
  local code2, _, err = H.cli({ "frobnicate", file })
  eq(code2, 1)
  has(err, 'unknown command "frobnicate"')
end

T["commands"]["missing files and threads are errors"] = function()
  local code, _, err = H.cli({ "list", dir .. "/nope.md" })
  eq(code, 1)
  has(err, "cannot read")
  code, _, err = H.cli({ "reply", file, "t9", "--body", "x" })
  eq(code, 1)
  has(err, "no thread t9")
end

T["commands"]["comment anchors to a quote across line breaks"] = function()
  local code, out = H.cli({ "comment", file, "--quote", "the likelihood and normalize", "--body", "Too terse?" }, human)
  eq(code, 0)
  has(out, "created t1 at line 3")
  local doc = H.doc(dir, "doc.md")
  eq(doc.threads[1].anchor.quote, "the likelihood and\nnormalize")
  eq(doc.threads[1].messages[1].author, "todd")
  eq(doc.threads[1].messages[1].role, "human")
end

T["commands"]["comment asks for --line when the quote repeats"] = function()
  local code, _, err = H.cli({ "comment", file, "--quote", "likelihood", "--body", "x" })
  eq(code, 1)
  has(err, "appears 2 times (lines 3, 4)")
  code = H.cli({ "comment", file, "--quote", "likelihood", "--line", "4", "--body", "x" })
  eq(code, 0)
  eq(H.doc(dir, "doc.md").threads[1].anchor.line, 4)
end

T["commands"]["comment reports a quote that is not there"] = function()
  local code, _, err = H.cli({ "comment", file, "--quote", "frequentist", "--body", "x" })
  eq(code, 1)
  has(err, "passage not found")
end

T["commands"]["reply with a suggestion, body from stdin"] = function()
  H.cli({ "comment", file, "--quote", "the key quantity", "--body", "Vague." }, human)
  local code, out = H.cli(
    { "reply", file, "t1", "--body", "-", "--suggest", "the quantity that carries the data" },
    { stdin = "Name what it does.\nSecond line.\n" }
  )
  eq(code, 0)
  has(out, "replied to t1 with a suggestion")
  local t = H.doc(dir, "doc.md").threads[1]
  eq(t.messages[2].body, "Name what it does.\nSecond line.")
  eq(t.messages[2].suggestion, { text = "the quantity that carries the data", status = "pending" })
  eq(t.messages[2].author, "claude")
  eq(t.messages[2].role, "agent")
end

T["commands"]["only one value may come from stdin"] = function()
  H.cli({ "comment", file, "--quote", "the key quantity", "--body", "Vague." }, human)
  local code, _, err = H.cli({ "reply", file, "t1", "--body", "-", "--suggest", "-" }, { stdin = "x" })
  eq(code, 1)
  has(err, "only one value")
end

T["commands"]["a no-op suggestion is refused"] = function()
  H.cli({ "comment", file, "--quote", "the key quantity", "--body", "Vague." }, human)
  local code, _, err = H.cli({ "reply", file, "t1", "--suggest", "the key quantity" })
  eq(code, 1)
  has(err, "identical")
end

T["commands"]["a suggestion can target other text with --quote"] = function()
  H.cli({ "comment", file, "--quote", "the key quantity", "--body", "Rework the sentence" }, human)
  local code = H.cli({
    "reply",
    file,
    "t1",
    "--suggest",
    "The likelihood matters most.",
    "--quote",
    "The likelihood is the key quantity.",
  })
  eq(code, 0)
  local s = H.doc(dir, "doc.md").threads[1].messages[2].suggestion
  eq(s.anchor.quote, "The likelihood\nis the key quantity.")
end

T["commands"]["agenda shows threads waiting on the agent with context"] = function()
  H.cli({ "comment", file, "--quote", "the key quantity", "--body", "Vague." }, human)
  H.cli({ "comment", file, "--quote", "# Bayes", "--body", "A question for you" })
  local code, out = H.cli({ "agenda", file })
  eq(code, 0)
  has(out, "1 thread(s) waiting on you, 1 open and waiting on the human")
  has(out, "## t1 (line 5; open, waiting on the agent)")
  has(out, "> the key quantity")
  has(out, ">5| is the key quantity.")
  has(out, "- **todd** (human")
  has(out, "Open threads waiting on the human")
  has(out, "t2")
end

T["commands"]["agenda notes passages that changed or vanished"] = function()
  H.cli({ "comment", file, "--quote", "multiply the prior by", "--body", "a" }, human)
  H.cli({ "comment", file, "--quote", "is the key quantity.", "--body", "b" }, human)
  H.write(file, DOC:gsub("multiply the prior by", "combine the prior with"):gsub("is the key quantity%.", ""))
  local _, out = H.cli({ "agenda", file })
  has(out, "combine the prior with")
  has(out, "it originally read")
  has(out, "detached")
  has(out, "no longer found in the file")
end

T["commands"]["list, show and json output"] = function()
  H.cli({ "comment", file, "--quote", "the key quantity", "--body", "Vague." }, human)
  local _, out = H.cli({ "list", file })
  has(out, 't1   open     L5')
  local _, js = H.cli({ "list", file, "--json" })
  local items = vim.json.decode(js)
  eq(items[1].id, "t1")
  eq(items[1].awaiting, "agent")
  eq(items[1].line, 5)
  local _, shown = H.cli({ "show", file, "t1" })
  has(shown, "Conversation:")
  local _, shown_js = H.cli({ "show", file, "t1", "--json" })
  eq(vim.json.decode(shown_js).thread.id, "t1")
end

T["commands"]["resolve and reopen"] = function()
  H.cli({ "comment", file, "--quote", "the key quantity", "--body", "Vague." }, human)
  local _, out = H.cli({ "resolve", file, "t1" })
  has(out, "resolved t1")
  eq(H.doc(dir, "doc.md").threads[1].status, "resolved")
  local _, listed = H.cli({ "list", file })
  has(listed, "no open threads")
  H.cli({ "reopen", file, "t1" })
  eq(H.doc(dir, "doc.md").threads[1].status, "open")
end

T["bin/overlai"] = MiniTest.new_set({ hooks = { pre_case = setup } })

T["bin/overlai"]["runs as a real command"] = function()
  local bin = H.root .. "/bin/overlai"
  local res = vim
    .system({ bin, "comment", file, "--quote", "the key quantity", "--body", "-" }, {
      stdin = "From a pipe",
      env = { OVERLAI_AUTHOR = "codex", OVERLAI_NVIM = vim.v.progpath },
    })
    :wait()
  eq(res.code, 0)
  has(res.stdout, "created t1")
  local m = H.doc(dir, "doc.md").threads[1].messages[1]
  eq({ m.author, m.body }, { "codex", "From a pipe" })

  res = vim.system({ bin, "show", file, "t9" }, { env = { OVERLAI_NVIM = vim.v.progpath } }):wait()
  eq(res.code, 1)
  has(res.stderr, "no thread t9")
end

T["bin/overlai"]["works through a symlink, as install-skill links it"] = function()
  local links = vim.fn.tempname()
  vim.fn.mkdir(links, "p")
  vim.uv.fs_symlink(H.root .. "/bin/overlai", links .. "/overlai")
  local res = vim.system({ links .. "/overlai", "list", file }, { env = { OVERLAI_NVIM = vim.v.progpath } }):wait()
  eq(res.code, 0)
  has(res.stdout, "no open threads")
end

return T
