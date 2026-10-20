-- Minimal config for tests: this plugin and mini.test, nothing else.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/?.lua;" .. package.path
vim.opt.rtp:prepend(root .. "/deps/mini.nvim")
vim.o.swapfile = false
vim.o.shadafile = "NONE"
if #vim.api.nvim_list_uis() == 0 then
  require("mini.test").setup()
end
