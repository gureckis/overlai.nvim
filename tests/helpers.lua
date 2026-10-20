local H = {}

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
H.root = root

--- A fresh project directory (with .git, so it is its own root).
function H.project(files)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir .. "/.git", "p")
  for name, content in pairs(files or {}) do
    local path = dir .. "/" .. name
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(content)
    f:close()
  end
  return vim.uv.fs_realpath(dir)
end

function H.read(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

function H.write(path, content)
  local f = assert(io.open(path, "wb"))
  f:write(content)
  f:close()
end

function H.sidecar(dir, rel)
  return dir .. "/.review/" .. rel .. ".json"
end

function H.doc(dir, rel)
  local s = H.read(H.sidecar(dir, rel))
  return s and vim.json.decode(s) or nil
end

--- Run the CLI in-process. Returns code, stdout, stderr.
function H.cli(argv, opts)
  opts = opts or {}
  local out, err = {}, {}
  local code = require("overlai.cli").run(argv, {
    io = {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function(s)
        err[#err + 1] = s
      end,
    },
    env = opts.env or { OVERLAI_AUTHOR = "claude", OVERLAI_ROLE = "agent" },
    stdin = opts.stdin and function()
      return opts.stdin
    end,
  })
  return code, table.concat(out), table.concat(err)
end

--- A child Neovim with the plugin loaded.
function H.child()
  local child = MiniTest.new_child_neovim()
  child.setup = function(opts)
    child.restart({ "-u", root .. "/scripts/minimal_init.lua" })
    child.lua("vim.opt.rtp:prepend(...)", { root })
    child.cmd("runtime plugin/overlai.lua")
    child.lua("require('overlai').setup(...)", { opts or { author = "todd" } })
  end
  return child
end

--- Wait for a condition evaluated in the child.
function H.wait(child, lua_expr, timeout)
  local ok = child.lua(
    ("return vim.wait(%d, function() return %s end, 20)"):format(timeout or 3000, lua_expr)
  )
  if not ok then
    error("timed out waiting for: " .. lua_expr)
  end
end

return H
