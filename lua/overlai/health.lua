local M = {}

function M.check()
  local h = vim.health
  h.start("overlai")
  if vim.fn.has("nvim-0.10") == 1 then
    h.ok("Neovim " .. tostring(vim.version()))
  else
    h.error("Neovim 0.10 or later is required")
  end

  local agent = require("overlai.agent")
  local bin = vim.fs.joinpath(agent.bin_dir, "overlai")
  if vim.fn.executable(bin) == 1 then
    h.ok("CLI: " .. bin)
  else
    h.error("CLI not executable: " .. bin)
  end

  h.start("overlai agents")
  local config = require("overlai.config")
  for _, name in ipairs(agent.names()) do
    local build = config.options.agent.agents[name] or agent.agents[name]
    local ok, cmd = pcall(build, "", { root = vim.uv.cwd(), rel = "", file = "" })
    if not ok then
      h.warn(name .. ": could not build its command: " .. tostring(cmd))
    elseif vim.fn.executable(cmd[1]) == 1 then
      h.ok(("%s: %s%s"):format(name, vim.fn.exepath(cmd[1]), name == config.options.agent.default and " (default)" or ""))
    else
      h.warn(("%s: %s not found on PATH"):format(name, cmd[1]))
    end
  end

  h.start("overlai skill")
  for _, t in ipairs(require("overlai.skill").targets()) do
    local skill = vim.fs.joinpath(t.dir, "overlai", "SKILL.md")
    if vim.uv.fs_stat(skill) then
      h.ok(("%s skill installed: %s"):format(t.name, skill))
    else
      h.info(("%s skill not installed (optional; the hand-off prompt carries the instructions). Run :Overlai install-skill"):format(t.name))
    end
  end

  h.start("overlai review files")
  local buf = vim.api.nvim_get_current_buf()
  local st = require("overlai.buffer").get(buf)
  if st then
    h.ok(("this buffer: %s (%d threads)"):format(st.paths.sidecar, #st.doc.threads))
  else
    h.info("this buffer has no review file")
  end
end

return M
