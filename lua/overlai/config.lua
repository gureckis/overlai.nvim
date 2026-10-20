local M = {}

---@class overlai.Config
M.defaults = {
  -- Your name on comments. Defaults to $USER.
  author = nil,
  -- Directory (at the project root) that holds the review files.
  dir_name = ".review",
  -- Attach automatically to any buffer whose file has a review file.
  auto_attach = true,
  -- Draw resolved threads too.
  show_resolved = false,

  -- Decorations in the document.
  signs = true,
  sign_text = "▎",
  -- Preview of the latest message at the end of the passage's first line.
  virt_text = true,
  virt_text_width = 50,
  icons = {
    human = "󰆉 ",
    agent = "󰚩 ",
    suggestion = "± ",
    resolved = "✓ ",
    detached = "? ",
    your_turn = "● ",
    their_turn = "○ ",
  },

  panel = {
    width = 50,
    position = "right", -- "right" or "left"
    -- Lines of each thread's latest messages to show.
    preview_messages = 2,
    -- Moving through the panel scrolls the document to each passage.
    auto_preview = true,
  },

  float = {
    border = "rounded",
    max_width = 80,
    max_height = 24,
  },

  -- Keys inside overlai's own windows. Set a key to false to disable it.
  mappings = {
    panel = {
      jump = "<CR>",
      next = "]]",
      prev = "[[",
      show = "K",
      reply = "r",
      accept = "a",
      reject = "x",
      toggle_resolved = "R",
      delete = "dd",
      toggle_show_resolved = "H",
      refresh = "<C-l>",
      close = "q",
      help = "g?",
    },
    thread = {
      reply = "r",
      accept = "a",
      reject = "x",
      toggle_resolved = "R",
      close = "q",
    },
    compose = {
      submit = "<C-s>",
      cancel = "q",
    },
  },

  agent = {
    default = "claude",
    -- Save a modified buffer before handing it off (the agent reads the file
    -- on disk).
    save = true,
    -- Let the agent search the web and read pages (claude: WebSearch and
    -- WebFetch; codex: --search).
    web = false,
    -- Extra instructions added to every hand-off prompt.
    instructions = nil,
    -- Replace the whole prompt: a function(ctx) returning a string, where ctx
    -- = { file, rel, root, author, agent, instructions, web }.
    prompt = nil,
    -- Each agent is a function(prompt, ctx) returning the command to run.
    agents = {},
  },
}

---@type overlai.Config
M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  require("overlai.store").dir_name = M.options.dir_name
  return M.options
end

function M.author()
  return M.options.author or vim.env.USER or "me"
end

return M
