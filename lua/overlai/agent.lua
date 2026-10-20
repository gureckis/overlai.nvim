-- Handing a document to an LLM agent. The agent runs headless (`claude -p`,
-- `codex exec`) in the project root with overlai's bin/ on its PATH, reads
-- the threads with `overlai agenda`, and answers through the CLI. Its replies
-- reach the buffer through the review-file watcher as they are written.

local buffer = require("overlai.buffer")
local config = require("overlai.config")
local model = require("overlai.model")
local store = require("overlai.store")
local util = require("overlai.util")

local M = {}

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
M.bin_dir = vim.fs.joinpath(plugin_root, "bin")

---@type table<integer, table>
local jobs = {}

M.PROMPT = [[
You are co-editing a document with %{author}, in the comment-and-suggest style of
reviewing in Word or Google Docs. The document is %{rel} (project
root: %{root}). Comment threads are anchored to passages of it and stored
alongside it by a tool called overlai.

You must not edit %{rel} yourself. Everything you contribute goes through the
`overlai` command, which records replies, suggested edits and new comments for
%{author} to accept, reject or discuss.

Start by running:

    overlai agenda %{rel}

It lists the threads waiting on you, each with its passage, nearby lines and
the conversation so far. Read as much of the document as you need to
understand each one. Then, for every thread waiting on you:

- If the comment asks for a change, or a change is the best answer, propose it
  as a suggestion. The suggestion text replaces the thread's whole passage,
  exactly as shown under "Passage:", so repeat any part you keep. Say briefly
  why in --body.
      overlai reply %{rel} t3 --body "Splits the long sentence." --suggest - <<'EOF'
      replacement text, which may span lines
      EOF
  To replace a different stretch of text than the passage (a neighbouring
  sentence, a whole paragraph), add --quote with that text exactly as it
  appears in the file.
- If the request is unclear, or you disagree, reply with a question or your
  reasoning instead of a suggestion. Discussion is welcome.
- Match the document's voice, its markdown conventions and its line wrapping.
%{web}
You may also open new threads on passages that need attention:

    overlai comment %{rel} --quote "exact passage" --body "Your note" [--suggest -]

Keep new threads few unless you were asked for a review. Do not resolve threads
that %{author} opened; they decide. Use simple commands: one overlai call per
command, with text that contains quotes, newlines or $ passed on stdin through
a quoted heredoc as above. When you are done, end with a one-paragraph summary
of what you did.
%{instructions}]]

local function fill(template, ctx)
  return (template:gsub("%%{(%w+)}", function(k)
    return ctx[k] ~= nil and tostring(ctx[k]) or ""
  end))
end

function M.prompt(ctx)
  local p = config.options.agent.prompt
  if type(p) == "function" then
    return p(ctx)
  end
  local extra = {}
  if config.options.agent.instructions then
    extra[#extra + 1] = config.options.agent.instructions
  end
  if ctx.instructions and ctx.instructions ~= "" then
    extra[#extra + 1] = ctx.instructions
  end
  ctx = vim.tbl_extend("force", ctx, {
    web = ctx.web and "- You can search the web and fetch pages, to check a citation, a date or a claim.\n  Say in --body what you looked up.\n" or "",
    instructions = #extra > 0 and ("\nAdditional instructions:\n" .. table.concat(extra, "\n") .. "\n") or "",
  })
  return fill(type(p) == "string" and p or M.PROMPT, ctx)
end

--- Built-in agents: name -> function(prompt, ctx) returning the argv.
M.agents = {
  claude = function(prompt, ctx)
    return {
      "claude",
      "-p",
      prompt,
      "--output-format",
      "stream-json",
      "--verbose",
      "--allowedTools",
      "Bash(overlai:*),Read,Grep,Glob" .. (ctx and ctx.web and ",WebSearch,WebFetch" or ""),
      "--disallowedTools",
      "Edit,Write,NotebookEdit",
    }
  end,
  codex = function(prompt, ctx)
    local cmd = { "codex" }
    if ctx.web then
      cmd[#cmd + 1] = "--search"
    end
    return vim.list_extend(cmd, {
      "exec",
      "--json",
      "--skip-git-repo-check",
      "--sandbox",
      "workspace-write",
      "--cd",
      ctx.root,
      prompt,
    })
  end,
}

local function agent_cmd(name)
  return config.options.agent.agents[name] or M.agents[name]
end

function M.names()
  local names = vim.tbl_keys(vim.tbl_extend("force", {}, M.agents, config.options.agent.agents))
  table.sort(names)
  return names
end

--- One line about what a running agent is doing, or nil.
function M.status(buf)
  local job = jobs[buf]
  if not job then
    return nil
  end
  return ("%s: %s"):format(job.name, job.activity)
end

--- For statuslines: the status of whichever agent is running on the current
--- buffer (or any buffer), else "".
function M.statusline()
  local s = M.status(vim.api.nvim_get_current_buf())
  if s then
    return s
  end
  for buf in pairs(jobs) do
    return M.status(buf)
  end
  return ""
end

function M.running(buf)
  return jobs[buf] ~= nil
end

M.log_path = vim.fs.joinpath(vim.fn.stdpath("log"), "overlai-agent.log")

local function log(line)
  local f = io.open(M.log_path, "a")
  if f then
    f:write(line, "\n")
    f:close()
  end
end

-- Pull a short description of the agent's latest step out of one line of
-- its JSON event stream.
function M.activity_from_event(line)
  local ok, ev = pcall(vim.json.decode, line)
  if not ok or type(ev) ~= "table" then
    return nil
  end
  -- claude stream-json
  if ev.type == "assistant" and ev.message and type(ev.message.content) == "table" then
    for _, c in ipairs(ev.message.content) do
      if c.type == "tool_use" then
        local input = c.input or {}
        local what = input.command or input.file_path or input.pattern or ""
        return util.truncate_chars(c.name .. " " .. util.first_line(what), 60)
      elseif c.type == "text" then
        return "writing"
      end
    end
  end
  -- codex --json
  local item = ev.item or (ev.msg and ev.msg) or nil
  if type(item) == "table" then
    if item.command then
      local cmd = type(item.command) == "table" and table.concat(item.command, " ") or item.command
      return util.truncate_chars(util.first_line(cmd), 60)
    end
    if item.type == "reasoning" then
      return "thinking"
    end
  end
  return nil
end

-- Count what the agent added between two versions of the document.
function M.summarize(before, after)
  local old = {}
  for _, t in ipairs(before.threads) do
    old[t.id] = #t.messages
  end
  local replies, suggestions, new_threads = 0, 0, 0
  for _, t in ipairs(after.threads) do
    local start = (old[t.id] or 0) + 1
    if not old[t.id] then
      new_threads = new_threads + 1
    end
    for i = start, #t.messages do
      local m = t.messages[i]
      if m.role == "agent" then
        if old[t.id] then
          replies = replies + 1
        end
        if m.suggestion then
          suggestions = suggestions + 1
        end
      end
    end
  end
  local parts = {}
  if replies > 0 then
    parts[#parts + 1] = ("%d repl%s"):format(replies, replies == 1 and "y" or "ies")
  end
  if new_threads > 0 then
    parts[#parts + 1] = ("%d new thread%s"):format(new_threads, new_threads == 1 and "" or "s")
  end
  if suggestions > 0 then
    parts[#parts + 1] = ("%d suggested edit%s"):format(suggestions, suggestions == 1 and "" or "s")
  end
  return #parts > 0 and table.concat(parts, ", ") or "no changes"
end

local function refresh_ui(buf)
  vim.schedule(function()
    local panel = require("overlai.panel")
    if panel.source() == buf then
      panel.render()
    end
    vim.cmd.redrawstatus()
  end)
end

--- Hand a buffer's document to an agent.
--- opts = { agent = name?, instructions = string? }
function M.run(buf, opts)
  opts = opts or {}
  local name = opts.agent or config.options.agent.default
  local build = agent_cmd(name)
  if not build then
    return vim.notify(("overlai: unknown agent %q (have: %s)"):format(name, table.concat(M.names(), ", ")), vim.log.levels.ERROR)
  end
  if jobs[buf] then
    return vim.notify("overlai: an agent is already working on this buffer (:Overlai cancel)", vim.log.levels.WARN)
  end
  if vim.bo[buf].modified then
    if not config.options.agent.save then
      return vim.notify("overlai: write the buffer first; the agent reads the file on disk", vim.log.levels.WARN)
    end
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("silent write")
    end)
  end
  local st = buffer.attach(buf, true)
  local paths = st.paths
  local ctx = {
    file = paths.file,
    rel = paths.rel,
    root = paths.root,
    author = config.author(),
    agent = name,
    instructions = opts.instructions,
    web = config.options.agent.web,
  }
  local prompt = M.prompt(ctx)
  local cmd = build(prompt, ctx)
  if vim.fn.executable(cmd[1]) == 0 then
    return vim.notify(("overlai: %s is not installed (or not on PATH)"):format(cmd[1]), vim.log.levels.ERROR)
  end

  local before = store.load(paths.sidecar, paths.rel)
  local file_hash = util.sha256(util.read_file(paths.file))
  local env = {
    PATH = M.bin_dir .. ":" .. (vim.env.PATH or ""),
    OVERLAI_AUTHOR = name,
    OVERLAI_ROLE = "agent",
    OVERLAI_NVIM = vim.v.progpath,
  }
  local job = { name = name, activity = "starting", started = os.time(), output = {} }
  jobs[buf] = job
  log(("\n=== %s %s on %s"):format(os.date("%F %T"), name, paths.file))

  local pending = ""
  -- vim.system calls this in a fast event, where most of the API is off
  -- limits; the work is done on the main loop.
  local on_stdout = vim.schedule_wrap(function(_, data)
    if not data then
      return
    end
    pending = pending .. data
    while true do
      local nl = pending:find("\n", 1, true)
      if not nl then
        break
      end
      local line = pending:sub(1, nl - 1)
      pending = pending:sub(nl + 1)
      log(line)
      job.output[#job.output + 1] = line
      local what = M.activity_from_event(line)
      if what then
        job.activity = what
        refresh_ui(buf)
      end
    end
  end)

  local ok, handle = pcall(vim.system, cmd, {
    cwd = paths.root,
    env = env,
    text = true,
    stdin = false,
    stdout = on_stdout,
    stderr = function(_, data)
      if data then
        log("[stderr] " .. data)
      end
    end,
  }, function(res)
    vim.schedule(function()
      jobs[buf] = nil
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      buffer.reload(buf)
      local now = buffer.get(buf)
      local summary = now and M.summarize(before, now.doc) or ""
      if job.cancelled then
        vim.notify(("overlai: %s cancelled (%s)"):format(name, summary), vim.log.levels.WARN)
      elseif res.code ~= 0 then
        vim.notify(
          ("overlai: %s exited with code %d (%s); see :Overlai log"):format(name, res.code, summary),
          vim.log.levels.ERROR
        )
      else
        vim.notify(("overlai: %s finished: %s"):format(name, summary))
      end
      if util.sha256(util.read_file(paths.file)) ~= file_hash then
        vim.notify(("overlai: %s changed %s directly; reloading it"):format(name, paths.rel), vim.log.levels.WARN)
        vim.cmd.checktime(buf)
      end
      refresh_ui(buf)
    end)
  end)
  if not ok then
    jobs[buf] = nil
    return vim.notify("overlai: could not start " .. name .. ": " .. tostring(handle), vim.log.levels.ERROR)
  end
  job.handle = handle
  vim.notify(("overlai: handed %s to %s"):format(paths.rel, name))
  refresh_ui(buf)
  return job
end

function M.cancel(buf)
  local job = jobs[buf]
  if not job then
    return vim.notify("overlai: no agent is running on this buffer")
  end
  job.cancelled = true
  job.handle:kill(15)
end

return M
