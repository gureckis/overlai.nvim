local skill = require("overlai.skill")

local eq = MiniTest.expect.equality
local saved = {}

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      saved = { home = vim.env.HOME, codex = vim.env.CODEX_HOME, notify = vim.notify }
      vim.env.HOME = vim.fn.tempname()
      vim.env.CODEX_HOME = nil
      vim.fn.mkdir(vim.env.HOME, "p")
      vim.notify = function() end
    end,
    post_case = function()
      vim.env.HOME, vim.env.CODEX_HOME, vim.notify = saved.home, saved.codex, saved.notify
    end,
  },
})

T["install links the skill for Claude Code and Codex, and the command"] = function()
  local home = vim.env.HOME
  skill.install()
  eq(vim.uv.fs_readlink(home .. "/.claude/skills/overlai"), skill.skill_dir)
  eq(vim.uv.fs_readlink(home .. "/.codex/skills/overlai"), skill.skill_dir)
  eq(vim.uv.fs_readlink(home .. "/.local/bin/overlai"), skill.bin)
  eq(vim.uv.fs_stat(home .. "/.codex/skills/overlai/SKILL.md") ~= nil, true)
end

T["install honors CODEX_HOME"] = function()
  vim.env.CODEX_HOME = vim.env.HOME .. "/codex"
  skill.install()
  eq(vim.uv.fs_readlink(vim.env.HOME .. "/codex/skills/overlai"), skill.skill_dir)
end

T["install with a directory links only there"] = function()
  local dir = vim.env.HOME .. "/elsewhere"
  skill.install(dir)
  eq(vim.uv.fs_readlink(dir .. "/overlai"), skill.skill_dir)
  eq(vim.uv.fs_lstat(vim.env.HOME .. "/.claude/skills/overlai"), nil)
  eq(vim.uv.fs_lstat(vim.env.HOME .. "/.codex/skills/overlai"), nil)
end

T["install is idempotent and leaves existing files alone"] = function()
  local home = vim.env.HOME
  vim.fn.mkdir(home .. "/.codex/skills/overlai", "p")
  skill.install()
  local lines = skill.install()
  eq(lines[1]:find("already linked", 1, true) ~= nil, true)
  eq(lines[2]:find("exists; remove it first", 1, true) ~= nil, true)
end

return T
