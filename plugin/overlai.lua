if vim.g.loaded_overlai then
  return
end
vim.g.loaded_overlai = true

if vim.fn.has("nvim-0.10") == 0 then
  vim.notify("overlai needs Neovim 0.10 or later", vim.log.levels.ERROR)
  return
end

vim.api.nvim_create_user_command("Overlai", function(opts)
  require("overlai").command(opts)
end, {
  nargs = "*",
  range = true,
  desc = "overlai: comment, suggest, and review with an LLM",
  complete = function(arglead, cmdline)
    return require("overlai").complete(arglead, cmdline)
  end,
})

-- <Plug> mappings for users who prefer them over :Overlai.
local plug = {
  comment = { { "n", "x" }, ":Overlai comment<CR>" },
  suggest = { { "n", "x" }, ":Overlai suggest<CR>" },
  reply = { "n", "<Cmd>Overlai reply<CR>" },
  show = { "n", "<Cmd>Overlai show<CR>" },
  accept = { "n", "<Cmd>Overlai accept<CR>" },
  reject = { "n", "<Cmd>Overlai reject<CR>" },
  resolve = { "n", "<Cmd>Overlai resolve<CR>" },
  next = { "n", "<Cmd>Overlai next<CR>" },
  prev = { "n", "<Cmd>Overlai prev<CR>" },
  panel = { "n", "<Cmd>Overlai panel<CR>" },
  ask = { "n", "<Cmd>Overlai ask<CR>" },
}
for name, m in pairs(plug) do
  vim.keymap.set(m[1], "<Plug>(overlai-" .. name .. ")", m[2], { silent = true, desc = "overlai " .. name })
end

-- Decorations and auto-attach start right away; the heavier modules load on
-- first use.
require("overlai").init()
