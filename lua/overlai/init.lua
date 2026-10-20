-- overlai: comment, suggest, and discuss edits on any text file with an LLM,
-- the way you would review a document in Word or Google Docs.

local M = {}

local initialized = false

--- Wire up autocommands and decorations. Called by plugin/overlai.lua; safe to
--- call more than once.
function M.init()
  if initialized then
    return
  end
  initialized = true
  local buffer = require("overlai.buffer")
  local render = require("overlai.render")
  local panel = require("overlai.panel")
  local view = require("overlai.view")
  local config = require("overlai.config")

  render.highlights()
  buffer.on_change(function(buf)
    render.render(buf)
    if panel.source() == buf then
      panel.render()
      panel.follow()
    end
    view.refresh(buf)
  end)

  local group = vim.api.nvim_create_augroup("overlai", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = render.highlights })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
    group = group,
    callback = function(ev)
      if config.options.auto_attach then
        pcall(buffer.attach, ev.buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = group,
    callback = function(ev)
      if buffer.get(ev.buf) then
        render.render_current(ev.buf)
        panel.follow()
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function(ev)
      if panel.is_open() and vim.bo[ev.buf].buftype == "" and vim.api.nvim_buf_get_name(ev.buf) ~= "" then
        panel.set_source(ev.buf)
      end
    end,
  })

  -- Buffers loaded before the plugin (e.g. `nvim file.md` with lazy loading).
  if config.options.auto_attach then
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) then
        pcall(buffer.attach, buf)
      end
    end
  end
end

function M.setup(opts)
  require("overlai.config").setup(opts)
  initialized = false
  M.init()
  for buf in pairs(require("overlai.buffer").state) do
    require("overlai.render").render(buf)
  end
end

---------------------------------------------------------------------------
-- :Overlai {subcommand}

local function actions()
  return require("overlai.actions")
end

---@type table<string, { run: fun(args: string[], opts: table), complete?: fun(): string[], range?: boolean }>
M.subcommands = {
  comment = {
    range = true,
    run = function(_, o)
      actions().comment(0, o)
    end,
  },
  suggest = {
    range = true,
    run = function(_, o)
      actions().suggest(0, o)
    end,
  },
  reply = {
    run = function(a)
      actions().reply(0, a[1])
    end,
  },
  show = {
    run = function(a)
      actions().show(0, a[1])
    end,
  },
  accept = {
    run = function(a)
      actions().accept(0, a[1])
    end,
  },
  reject = {
    run = function(a)
      actions().reject(0, a[1])
    end,
  },
  resolve = {
    run = function(a)
      actions().resolve(0, a[1])
    end,
  },
  reopen = {
    run = function(a)
      actions().reopen(0, a[1])
    end,
  },
  delete = {
    run = function(a)
      actions().delete(0, a[1])
    end,
  },
  next = {
    run = function()
      actions().goto(0, 1)
    end,
  },
  prev = {
    run = function()
      actions().goto(0, -1)
    end,
  },
  panel = {
    run = function()
      local buf = vim.api.nvim_get_current_buf()
      require("overlai.buffer").attach(buf)
      require("overlai.panel").toggle(buf)
    end,
  },
  reanchor = {
    range = true,
    run = function(a, o)
      actions().reanchor(0, o, a[1])
    end,
  },
  ask = {
    run = function(a)
      local names = require("overlai.agent").names()
      local agent
      if a[1] and vim.tbl_contains(names, a[1]) then
        agent = table.remove(a, 1)
      end
      actions().ask(0, agent, table.concat(a, " "))
    end,
    complete = function()
      return require("overlai.agent").names()
    end,
  },
  cancel = {
    run = function()
      actions().cancel(0)
    end,
  },
  log = {
    run = function()
      vim.cmd.split(vim.fn.fnameescape(require("overlai.agent").log_path))
      vim.cmd("normal! G")
    end,
  },
  attach = {
    run = function()
      require("overlai.buffer").attach(0, true)
    end,
  },
  detach = {
    run = function()
      require("overlai.buffer").detach(vim.api.nvim_get_current_buf())
    end,
  },
  ["install-skill"] = {
    run = function(a)
      require("overlai.skill").install(a[1])
    end,
  },
}

function M.command(opts)
  local args = vim.deepcopy(opts.fargs)
  local name = table.remove(args, 1) or "panel"
  local sub = M.subcommands[name]
  if not sub then
    return vim.notify("overlai: unknown subcommand " .. name, vim.log.levels.ERROR)
  end
  local ok, err = pcall(sub.run, args, opts)
  if not ok then
    vim.notify(tostring(err), vim.log.levels.ERROR)
  end
end

function M.complete(arglead, cmdline)
  local words = vim.split(cmdline:gsub("^%S*%s*", ""), "%s+")
  -- Strip a leading range (e.g. "'<,'>Overlai").
  if #words <= 1 then
    local names = vim.tbl_keys(M.subcommands)
    table.sort(names)
    return vim.tbl_filter(function(n)
      return n:find(arglead, 1, true) == 1
    end, names)
  end
  local sub = M.subcommands[words[1]]
  if sub and sub.complete and #words == 2 then
    return vim.tbl_filter(function(n)
      return n:find(arglead, 1, true) == 1
    end, sub.complete())
  end
  return {}
end

--- Statusline component: what the agent is doing, if one is running.
function M.status()
  return require("overlai.agent").statusline()
end

return M
