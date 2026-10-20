-- Installing the agent instructions: the skill, for Claude Code and Codex, and
-- the `overlai` command on PATH for agents started outside Neovim.

local M = {}

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
M.skill_dir = vim.fs.joinpath(root, "skills", "overlai")
M.bin = vim.fs.joinpath(root, "bin", "overlai")

local function link(src, dest)
  vim.fn.mkdir(vim.fs.dirname(dest), "p")
  local stat = vim.uv.fs_lstat(dest)
  if stat then
    if stat.type == "link" and vim.uv.fs_readlink(dest) == src then
      return "already linked"
    end
    return nil, dest .. " exists; remove it first"
  end
  local ok, err = vim.uv.fs_symlink(src, dest)
  if not ok then
    return nil, err
  end
  return "linked"
end

--- Where each agent looks for skills. Both read the same SKILL.md format.
function M.targets()
  local home = vim.env.HOME
  return {
    { name = "Claude Code", dir = vim.fs.joinpath(home, ".claude", "skills") },
    { name = "Codex", dir = vim.fs.joinpath(vim.env.CODEX_HOME or vim.fs.joinpath(home, ".codex"), "skills") },
  }
end

--- Link the skill into each agent's skills directory (or only into `dir`) and
--- bin/overlai into ~/.local/bin.
function M.install(dir)
  local jobs = {}
  local targets = dir and { { name = "skill", dir = dir } } or M.targets()
  for _, t in ipairs(targets) do
    jobs[#jobs + 1] = { M.skill_dir, vim.fs.joinpath(t.dir, "overlai"), t.name }
  end
  jobs[#jobs + 1] = { M.bin, vim.fs.joinpath(vim.env.HOME, ".local", "bin", "overlai"), "command" }
  local lines = {}
  for _, job in ipairs(jobs) do
    local res, err = link(job[1], job[2])
    lines[#lines + 1] = ("%s: %s (%s)"):format(job[3], res or ("not installed: " .. err), job[2])
  end
  vim.notify("overlai\n" .. table.concat(lines, "\n"))
  return lines
end

return M
