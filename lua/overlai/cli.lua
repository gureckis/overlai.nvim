-- `overlai`, the command-line side of the plugin. Agents (and people at a
-- shell) use it to read the threads on a document and to reply, suggest, and
-- comment. It runs under `nvim -l` and shares its code with the plugin.

local anchor = require("overlai.anchor")
local model = require("overlai.model")
local store = require("overlai.store")
local text = require("overlai.text")
local util = require("overlai.util")

local M = {}

M.usage = [[
usage: overlai <command> FILE [args]

Reading
  agenda FILE                 Threads waiting on you, with context (start here)
  list FILE [--all]           One line per thread (open only, unless --all)
  show FILE ID                One thread in full

Writing
  reply FILE ID --body TEXT [--suggest TEXT] [--quote Q]
                              Answer a thread; --suggest proposes replacement
                              text for the thread's passage (or for Q)
  comment FILE --quote Q [--line N] [--body TEXT] [--suggest TEXT]
                              Start a thread on passage Q (--line picks
                              between repeated passages)
  resolve FILE ID             Close a thread
  reopen FILE ID              Reopen a resolved thread

Options
  --as NAME                   Author name (default $OVERLAI_AUTHOR, or "agent")
  --role human|agent          (default $OVERLAI_ROLE, or "agent")
  --json                      Machine-readable output
  TEXT, Q and the values of --body/--suggest/--quote may be "-" to read stdin.
]]

---------------------------------------------------------------------------
-- Argument parsing

local BOOLEAN = { all = true, json = true, help = true }

function M.parse(argv)
  local args = { _ = {} }
  local i = 1
  while i <= #argv do
    local a = argv[i]
    local key, value = a:match("^%-%-([%w-]+)=(.*)$")
    if key then
      args[key] = value
    elseif a:match("^%-%-[%w-]+$") then
      key = a:sub(3)
      if BOOLEAN[key] then
        args[key] = true
      else
        i = i + 1
        if argv[i] == nil then
          error("overlai: --" .. key .. " needs a value", 0)
        end
        args[key] = argv[i]
      end
    elseif a == "-h" then
      args.help = true
    else
      args._[#args._ + 1] = a
    end
    i = i + 1
  end
  return args
end

local stdin_used = false
local function value(v, read_stdin)
  if v ~= "-" then
    return v
  end
  if stdin_used then
    error("overlai: only one value can come from stdin", 0)
  end
  stdin_used = true
  local data = (read_stdin or function()
    return io.read("*a")
  end)()
  return (data:gsub("\n$", ""))
end

---------------------------------------------------------------------------
-- Locating threads in the current text

--- Resolve every thread against the document text.
--- Returns a map id -> { a, b, first, last, exact } (nil entry = orphaned).
function M.locate(doc, content)
  local idx = anchor.index(content)
  local where = {}
  for _, t in ipairs(doc.threads) do
    local a, b, info = anchor.resolve(idx, t.anchor)
    if a then
      where[t.id] = {
        a = a,
        b = b,
        first = text.line_of(idx.lines, a),
        last = text.line_of(idx.lines, math.max(a, b - 1)),
        exact = info.exact,
        quote = content:sub(a, b - 1),
      }
    end
  end
  return where, idx
end

local function lines_label(loc)
  if not loc then
    return "detached"
  end
  if loc.first == loc.last then
    return "line " .. loc.first
  end
  return ("lines %d-%d"):format(loc.first, loc.last)
end

local function quote_block(s)
  local out = {}
  for _, l in ipairs(vim.split(s, "\n", { plain = true })) do
    out[#out + 1] = l == "" and ">" or ("> " .. l)
  end
  return table.concat(out, "\n")
end

local function context_block(content_lines, loc, radius)
  local first = math.max(1, loc.first - radius)
  local last = math.min(#content_lines, loc.last + radius)
  local out = {}
  local width = #tostring(last)
  for n = first, last do
    local mark = (n >= loc.first and n <= loc.last) and ">" or " "
    out[#out + 1] = ("%s%" .. width .. "d| %s"):format(mark, n, content_lines[n])
  end
  return table.concat(out, "\n")
end

local function describe_message(m)
  local out = { ("- **%s** (%s, %s):"):format(m.author, m.role, m.created_at or "?") }
  if m.body ~= "" then
    for _, l in ipairs(vim.split(m.body, "\n", { plain = true })) do
      out[#out + 1] = "  " .. l
    end
  end
  if m.suggestion then
    out[#out + 1] = ("  [suggestion, %s]%s"):format(
      m.suggestion.status,
      m.suggestion.anchor and (' replacing "' .. util.truncate(m.suggestion.anchor.quote, 60) .. '"') or ""
    )
    for _, l in ipairs(vim.split(m.suggestion.text, "\n", { plain = true })) do
      out[#out + 1] = "  | " .. l
    end
  end
  return table.concat(out, "\n")
end

--- Full markdown description of one thread.
function M.describe(t, loc, content_lines, opts)
  opts = opts or {}
  local turn = model.awaiting(t)
  local status = t.status
  if turn then
    status = status .. ", waiting on " .. (turn == "agent" and "the agent" or "the human")
  end
  local out = { ("## %s (%s; %s)"):format(t.id, lines_label(loc), status), "" }
  if loc then
    out[#out + 1] = "Passage:"
    out[#out + 1] = quote_block(loc.quote)
    if not loc.exact then
      out[#out + 1] = ""
      out[#out + 1] = "(The passage was edited since the comment was made; it originally read:)"
      out[#out + 1] = quote_block(t.anchor.quote)
    end
    if content_lines and (opts.context or 0) > 0 then
      out[#out + 1] = ""
      out[#out + 1] = "Context:"
      out[#out + 1] = "```"
      out[#out + 1] = context_block(content_lines, loc, opts.context)
      out[#out + 1] = "```"
    end
  else
    out[#out + 1] = "Passage (no longer found in the file):"
    out[#out + 1] = quote_block(t.anchor.quote)
  end
  out[#out + 1] = ""
  out[#out + 1] = "Conversation:"
  for _, m in ipairs(t.messages) do
    out[#out + 1] = describe_message(m)
  end
  return table.concat(out, "\n")
end

local function summary_line(t, loc)
  local last = model.last_message(t)
  local flags = {}
  if model.pending(t) then
    flags[#flags + 1] = "suggestion pending"
  end
  local turn = model.awaiting(t)
  if turn then
    flags[#flags + 1] = "waiting on " .. turn
  end
  return ('%-4s %-8s %-12s "%s"  %s: %s%s'):format(
    t.id,
    t.status,
    loc and ("L" .. loc.first) or "detached",
    util.truncate(t.anchor.quote, 40),
    last and last.author or "?",
    util.truncate(util.first_line(last and last.body or ""), 50),
    #flags > 0 and ("  [" .. table.concat(flags, ", ") .. "]") or ""
  )
end

---------------------------------------------------------------------------
-- Commands

local function open(file)
  if not file then
    error("overlai: missing FILE\n\n" .. M.usage, 0)
  end
  local paths = store.paths(file)
  local content = util.read_file(paths.file)
  if not content then
    error("overlai: cannot read " .. file, 0)
  end
  return paths, content
end

local function identity(args, env)
  local role = args.role or env.OVERLAI_ROLE or "agent"
  local author = args.as or env.OVERLAI_AUTHOR or role
  return author, role
end

-- Choose one match for a quote. `near` is a line to prefer.
local function pick_range(content, quote, line, near)
  local ranges = anchor.find_quote(content, quote)
  if #ranges == 0 then
    error(
      ("overlai: passage not found in the file: %q\n(quote it exactly as it appears; line breaks and runs of spaces may differ)"):format(
        util.truncate(quote, 80)
      ),
      0
    )
  end
  if line then
    line = tonumber(line)
    table.sort(ranges, function(x, y)
      return math.abs(x.line - line) < math.abs(y.line - line)
    end)
    return ranges[1]
  end
  if #ranges > 1 then
    if near then
      table.sort(ranges, function(x, y)
        return math.abs(x.line - near) < math.abs(y.line - near)
      end)
      return ranges[1]
    end
    local lines = vim.tbl_map(function(r)
      return tostring(r.line)
    end, ranges)
    error(
      ("overlai: that passage appears %d times (lines %s); pass --line N or quote more of it"):format(
        #ranges,
        table.concat(lines, ", ")
      ),
      0
    )
  end
  return ranges[1]
end

local function make_suggestion(content, args, thread_anchor, read_stdin)
  if not args.suggest then
    return nil
  end
  local s = { text = value(args.suggest, read_stdin) }
  local target
  if args.quote and thread_anchor then
    local where = anchor.resolve(content, thread_anchor)
    local near = where and text.line_of(text.line_starts(content), where) or nil
    local r = pick_range(content, value(args.quote, read_stdin), args.line, near)
    s.anchor = anchor.from_range(content, r[1], r[2])
    target = s.anchor.quote
  else
    local a, b = anchor.resolve(content, thread_anchor)
    if not a then
      error("overlai: this thread's passage is no longer in the file; use --quote to say what to replace", 0)
    end
    target = content:sub(a, b - 1)
  end
  if s.text == target then
    error("overlai: the suggestion is identical to the current text", 0)
  end
  return s
end

local commands = {}

function commands.list(args, io_)
  local paths, content = open(args._[2])
  local doc = store.load(paths.sidecar, paths.rel)
  local where = M.locate(doc, content)
  if args.json then
    local out = {}
    for _, t in ipairs(doc.threads) do
      if args.all or t.status == "open" then
        local loc = where[t.id]
        out[#out + 1] = {
          id = t.id,
          status = t.status,
          awaiting = model.awaiting(t),
          line = loc and loc.first or nil,
          detached = loc == nil,
          quote = t.anchor.quote,
          messages = #t.messages,
          suggestion_pending = model.pending(t) ~= nil,
        }
      end
    end
    io_.out(vim.json.encode(out) .. "\n")
    return
  end
  local shown = 0
  for _, t in ipairs(doc.threads) do
    if args.all or t.status == "open" then
      io_.out(summary_line(t, where[t.id]) .. "\n")
      shown = shown + 1
    end
  end
  if shown == 0 then
    io_.out(args.all and "no threads\n" or "no open threads\n")
  end
end

function commands.show(args, io_)
  local paths, content = open(args._[2])
  local id = args._[3] or error("overlai: missing thread ID", 0)
  local doc = store.load(paths.sidecar, paths.rel)
  local t = model.get(doc, id)
  local where = M.locate(doc, content)
  if args.json then
    io_.out(vim.json.encode({ thread = t, line = where[id] and where[id].first or nil }) .. "\n")
    return
  end
  local lines = vim.split(content, "\n", { plain = true })
  io_.out(M.describe(t, where[id], lines, { context = 3 }) .. "\n")
end

function commands.agenda(args, io_, env)
  local paths, content = open(args._[2])
  local doc = store.load(paths.sidecar, paths.rel)
  local where = M.locate(doc, content)
  local lines = vim.split(content, "\n", { plain = true })
  local author = identity(args, env)

  local mine, theirs, resolved = {}, {}, 0
  for _, t in ipairs(doc.threads) do
    local turn = model.awaiting(t)
    if turn == "agent" then
      mine[#mine + 1] = t
    elseif t.status == "open" then
      theirs[#theirs + 1] = t
    else
      resolved = resolved + 1
    end
  end
  local by_line = function(x, y)
    local lx, ly = where[x.id], where[y.id]
    return (lx and lx.first or math.huge) < (ly and ly.first or math.huge)
  end
  table.sort(mine, by_line)
  table.sort(theirs, by_line)

  if args.json then
    local out = { file = paths.rel, author = author, waiting = {}, open = {}, resolved = resolved }
    for _, t in ipairs(mine) do
      out.waiting[#out.waiting + 1] = { thread = t, line = where[t.id] and where[t.id].first or nil }
    end
    for _, t in ipairs(theirs) do
      out.open[#out.open + 1] = { id = t.id, line = where[t.id] and where[t.id].first or nil }
    end
    io_.out(vim.json.encode(out) .. "\n")
    return
  end

  local out = {
    ("# Review agenda: %s"):format(paths.rel),
    "",
    ("%d thread(s) waiting on you, %d open and waiting on the human, %d resolved."):format(
      #mine,
      #theirs,
      resolved
    ),
  }
  for _, t in ipairs(mine) do
    out[#out + 1] = ""
    out[#out + 1] = M.describe(t, where[t.id], lines, { context = 2 })
  end
  if #theirs > 0 then
    out[#out + 1] = ""
    out[#out + 1] = "## Open threads waiting on the human (no action needed)"
    out[#out + 1] = ""
    for _, t in ipairs(theirs) do
      out[#out + 1] = "- " .. summary_line(t, where[t.id])
    end
  end
  io_.out(table.concat(out, "\n") .. "\n")
end

function commands.reply(args, io_, env, read_stdin)
  local paths, content = open(args._[2])
  local id = args._[3] or error("overlai: missing thread ID", 0)
  local author, role = identity(args, env)
  local body = args.body and value(args.body, read_stdin) or nil
  local msg
  store.update(paths, function(doc)
    local t = model.get(doc, id)
    msg = model.add_message(t, {
      author = author,
      role = role,
      body = body,
      suggestion = make_suggestion(content, args, t.anchor, read_stdin),
    })
  end)
  if args.json then
    io_.out(vim.json.encode({ id = id, message = msg }) .. "\n")
  else
    io_.out(("replied to %s%s\n"):format(id, msg.suggestion and " with a suggestion" or ""))
  end
end

function commands.comment(args, io_, env, read_stdin)
  local paths, content = open(args._[2])
  if not args.quote then
    error("overlai: comment needs --quote (the passage to comment on)", 0)
  end
  local author, role = identity(args, env)
  local r = pick_range(content, value(args.quote, read_stdin), args.line)
  local anc = anchor.from_range(content, r[1], r[2])
  local body = args.body and value(args.body, read_stdin) or nil
  local suggestion
  if args.suggest then
    suggestion = { text = value(args.suggest, read_stdin) }
    if suggestion.text == anc.quote then
      error("overlai: the suggestion is identical to the current text", 0)
    end
  end
  local thread
  store.update(paths, function(doc)
    thread = model.add_thread(doc, {
      anchor = anc,
      author = author,
      role = role,
      body = body,
      suggestion = suggestion,
    })
  end)
  if args.json then
    io_.out(vim.json.encode({ id = thread.id, line = anc.line }) .. "\n")
  else
    io_.out(("created %s at line %d\n"):format(thread.id, anc.line))
  end
end

commands.suggest = function(args, io_, env, read_stdin)
  args.suggest = args.suggest or args.text
  if not args.suggest then
    error("overlai: suggest needs --suggest TEXT", 0)
  end
  return commands.reply(args, io_, env, read_stdin)
end

local function set_status(args, io_, env, fn, verb)
  local paths = open(args._[2])
  local id = args._[3] or error("overlai: missing thread ID", 0)
  local author = identity(args, env)
  store.update(paths, function(doc)
    fn(model.get(doc, id), author)
  end)
  io_.out(("%s %s\n"):format(verb, id))
end

function commands.resolve(args, io_, env)
  set_status(args, io_, env, model.resolve, "resolved")
end

function commands.reopen(args, io_, env)
  set_status(args, io_, env, model.reopen, "reopened")
end

--- Run the CLI. Returns an exit code. `io_` = { out, err } writers, `env` a
--- table of environment variables; both default to the real ones.
function M.run(argv, opts)
  opts = opts or {}
  stdin_used = false
  local io_ = opts.io
    or {
      out = function(s)
        io.stdout:write(s)
      end,
      err = function(s)
        io.stderr:write(s)
      end,
    }
  local env = opts.env or vim.fn.environ()
  local ok, err = pcall(function()
    local args = M.parse(argv)
    local cmd = args._[1]
    if not cmd or args.help or cmd == "help" then
      io_.out(M.usage)
      return
    end
    local fn = commands[cmd]
    if not fn then
      error(("overlai: unknown command %q\n\n%s"):format(cmd, M.usage), 0)
    end
    fn(args, io_, env, opts.stdin)
  end)
  if not ok then
    io_.err(tostring(err) .. "\n")
    return 1
  end
  return 0
end

return M
