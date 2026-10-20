-- Entry point for bin/overlai: put the plugin on the runtimepath and hand the
-- arguments to overlai.cli.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
os.exit(require("overlai.cli").run(_G.arg))
