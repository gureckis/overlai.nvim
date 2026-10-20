local H = require("tests.helpers")
local agent = require("overlai.agent")

local eq = MiniTest.expect.equality
local child = H.child()

local DOC = "# Bayes\n\nThe likelihood is the key quantity.\n"

local T = MiniTest.new_set()

local function has(s, needle)
  if not s:find(needle, 1, true) then
    error(("expected to find %q in:\n%s"):format(needle, s), 2)
  end
end

T["prompt"] = MiniTest.new_set()

T["prompt"]["names the file, the CLI and the rules"] = function()
  local p = agent.prompt({ rel = "readings/bayes.md", root = "/r", author = "todd" })
  has(p, "overlai agenda readings/bayes.md")
  has(p, "You must not edit readings/bayes.md yourself")
  has(p, "co-editing a document with todd")
  eq(p:find("%{", 1, true), nil)
  eq(p:find("Additional instructions", 1, true), nil)
end

T["prompt"]["appends configured and per-run instructions"] = function()
  require("overlai.config").setup({ agent = { instructions = "Use British spelling." } })
  local p = agent.prompt({ rel = "a.md", root = "/r", author = "todd", instructions = "Focus on section 2." })
  has(p, "Additional instructions:\nUse British spelling.\nFocus on section 2.")
  require("overlai.config").setup({})
end

T["prompt"]["can be replaced"] = function()
  require("overlai.config").setup({ agent = { prompt = "Review %{rel} for %{author}." } })
  eq(agent.prompt({ rel = "a.md", author = "todd" }), "Review a.md for todd.")
  require("overlai.config").setup({
    agent = {
      prompt = function(ctx)
        return "custom " .. ctx.rel
      end,
    },
  })
  eq(agent.prompt({ rel = "a.md" }), "custom a.md")
  require("overlai.config").setup({})
end

T["commands"] = MiniTest.new_set()

T["commands"]["claude runs headless, limited to overlai and reading"] = function()
  local cmd = agent.agents.claude("PROMPT", { root = "/r" })
  eq(cmd[1], "claude")
  eq(vim.tbl_contains(cmd, "-p"), true)
  eq(vim.tbl_contains(cmd, "Bash(overlai:*),Read,Grep,Glob"), true)
  eq(vim.tbl_contains(cmd, "Edit,Write,NotebookEdit"), true)
end

T["commands"]["codex runs in a workspace-write sandbox at the root"] = function()
  local cmd = agent.agents.codex("PROMPT", { root = "/r" })
  eq({ cmd[1], cmd[2] }, { "codex", "exec" })
  local s = table.concat(cmd, " ")
  has(s, "--sandbox workspace-write")
  has(s, "--cd /r")
  eq(cmd[#cmd], "PROMPT")
end

T["commands"]["web access adds the web tools and says so in the prompt"] = function()
  local s = table.concat(agent.agents.claude("PROMPT", { root = "/r", web = true }), " ")
  has(s, "Bash(overlai:*),Read,Grep,Glob,WebSearch,WebFetch")
  local cmd = agent.agents.codex("PROMPT", { root = "/r", web = true })
  eq({ cmd[1], cmd[2], cmd[3] }, { "codex", "--search", "exec" })
  has(agent.prompt({ rel = "a.md", web = true }), "search the web")
  eq(agent.prompt({ rel = "a.md" }):find("search the web", 1, true), nil)
  eq(table.concat(agent.agents.claude("PROMPT", { root = "/r" }), " "):find("WebSearch", 1, true), nil)
end

T["activity"] = MiniTest.new_set()

T["activity"]["reads claude's stream-json events"] = function()
  local ev = vim.json.encode({
    type = "assistant",
    message = { content = { { type = "tool_use", name = "Bash", input = { command = "overlai agenda a.md" } } } },
  })
  eq(agent.activity_from_event(ev), "Bash overlai agenda a.md")
  eq(agent.activity_from_event(vim.json.encode({ type = "assistant", message = { content = { { type = "text" } } } })), "writing")
  eq(agent.activity_from_event("not json"), nil)
  eq(agent.activity_from_event(vim.json.encode({ type = "system" })), nil)
end

T["activity"]["is safe to call from the job's output callback"] = function()
  -- vim.system delivers output in a fast event; parsing must not need the
  -- main loop. Run the parser in one and check it does not throw.
  local ev = vim.json.encode({
    type = "assistant",
    message = { content = { { type = "tool_use", name = "Bash", input = { command = string.rep("x", 200) } } } },
  })
  local ok, res
  local timer = vim.uv.new_timer()
  timer:start(0, 0, function()
    ok, res = pcall(agent.activity_from_event, ev)
    timer:close()
  end)
  vim.wait(1000, function()
    return ok ~= nil
  end)
  eq(ok, true, res)
end

T["activity"]["reads codex's json events"] = function()
  local ev = vim.json.encode({ type = "item.started", item = { type = "command_execution", command = "overlai list a.md" } })
  eq(agent.activity_from_event(ev), "overlai list a.md")
end

T["summarize"] = function()
  local before = { threads = { { id = "t1", messages = { { role = "human" } } } } }
  local after = {
    threads = {
      { id = "t1", messages = { { role = "human" }, { role = "agent", suggestion = {} } } },
      { id = "t2", messages = { { role = "agent" } } },
    },
  }
  eq(agent.summarize(before, after), "1 reply, 1 new thread, 1 suggested edit")
  eq(agent.summarize(before, before), "no changes")
end

T["run"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.setup()
      child.lua([[
        _G.notes = {}
        vim.notify = function(msg, level) table.insert(_G.notes, { msg = msg, level = level }) end
      ]])
    end,
    post_once = child.stop,
  },
})

-- Configure a fake agent that runs a shell script in the project root.
local function fake_agent(script)
  child.lua(
    [[
    local script = ...
    require('overlai').setup({
      author = 'todd',
      agent = {
        default = 'fake',
        agents = { fake = function() return { 'sh', '-c', script } end },
      },
    })
  ]],
    { script }
  )
end

local function notes()
  return child.lua_get("vim.tbl_map(function(n) return n.msg end, _G.notes)")
end

local function wait_done()
  H.wait(child, "not require('overlai.agent').running(vim.api.nvim_get_current_buf())", 10000)
end

T["run"]["the agent answers through the CLI and the buffer updates"] = function()
  local dir = H.project({ ["doc.md"] = DOC })
  local file = dir .. "/doc.md"
  H.cli({ "comment", file, "--quote", "the key quantity", "--body", "Vague" }, {
    env = { OVERLAI_AUTHOR = "todd", OVERLAI_ROLE = "human" },
  })
  fake_agent([[
    overlai agenda doc.md > agenda.txt &&
    overlai reply doc.md t1 --body "Sharper" --suggest "what carries the evidence" &&
    overlai comment doc.md --quote "# Bayes" --body "Title case?"
  ]])
  child.cmd("edit " .. file)
  child.cmd("Overlai ask")
  wait_done()
  -- It saw the agenda, as the agent author.
  has(H.read(dir .. "/agenda.txt"), "1 thread(s) waiting on you")
  local doc = H.doc(dir, "doc.md")
  eq(#doc.threads, 2)
  eq(doc.threads[1].messages[2].author, "fake")
  eq(doc.threads[1].messages[2].role, "agent")
  eq(child.lua_get("#require('overlai.buffer').get(0).doc.threads"), 2)
  local n = notes()
  has(n[#n], "fake finished: 1 reply, 1 new thread, 1 suggested edit")
  -- The suggestion is waiting to be accepted.
  child.lua("require('overlai.actions').accept(0, 't1')")
  eq(child.api.nvim_buf_get_lines(0, 2, 3, false)[1], "The likelihood is what carries the evidence.")
end

T["run"]["saves a modified buffer first"] = function()
  local dir = H.project({ ["doc.md"] = DOC })
  fake_agent("cat doc.md > seen.txt")
  child.cmd("edit " .. dir .. "/doc.md")
  child.api.nvim_buf_set_lines(0, 0, 1, false, { "# Bayes, edited" })
  child.cmd("Overlai ask")
  wait_done()
  has(H.read(dir .. "/seen.txt"), "# Bayes, edited")
end

T["run"]["passes instructions into the prompt"] = function()
  local dir = H.project({ ["doc.md"] = DOC })
  child.lua(
    [[
    require('overlai').setup({ author = 'todd', agent = { agents = {
      echo = function(prompt) return { 'sh', '-c', 'printf "%s" "$1" > prompt.txt', 'sh', prompt } end,
    } } })
  ]]
  )
  child.cmd("edit " .. dir .. "/doc.md")
  child.cmd("Overlai ask echo tighten the prose")
  wait_done()
  local p = H.read(dir .. "/prompt.txt")
  has(p, "overlai agenda doc.md")
  has(p, "tighten the prose")
end

T["run"]["warns when the agent edits the file directly"] = function()
  local dir = H.project({ ["doc.md"] = DOC })
  fake_agent("echo extra >> doc.md")
  child.cmd("edit " .. dir .. "/doc.md")
  child.cmd("Overlai ask")
  wait_done()
  local n = table.concat(notes(), "\n")
  has(n, "fake changed doc.md directly")
end

T["run"]["reports failures and can be cancelled"] = function()
  local dir = H.project({ ["doc.md"] = DOC })
  fake_agent("exit 3")
  child.cmd("edit " .. dir .. "/doc.md")
  child.cmd("Overlai ask")
  wait_done()
  has(table.concat(notes(), "\n"), "fake exited with code 3")

  fake_agent("sleep 30")
  child.cmd("Overlai ask")
  eq(child.lua_get("require('overlai.agent').running(vim.api.nvim_get_current_buf())"), true)
  has(child.lua_get("require('overlai').status()"), "fake: starting")
  child.cmd("Overlai ask")
  has(table.concat(notes(), "\n"), "already working on this buffer")
  child.cmd("Overlai cancel")
  wait_done()
  has(table.concat(notes(), "\n"), "fake cancelled")
end

T["run"]["refuses unknown agents and missing programs"] = function()
  local dir = H.project({ ["doc.md"] = DOC })
  child.lua([[require('overlai').setup({ agent = { agents = {
    ghost = function() return { 'definitely-not-a-program' } end } } })]])
  child.cmd("edit " .. dir .. "/doc.md")
  child.lua("require('overlai.agent').run(0 + vim.api.nvim_get_current_buf(), { agent = 'nobody' })")
  has(table.concat(notes(), "\n"), 'unknown agent "nobody"')
  child.lua("require('overlai.agent').run(vim.api.nvim_get_current_buf(), { agent = 'ghost' })")
  has(table.concat(notes(), "\n"), "definitely-not-a-program is not installed")
end

return T
