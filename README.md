# overlai.nvim

Review a document with an LLM the way you would with a colleague in Word or
Google Docs. You highlight a passage and leave a comment. The agent
reads it and answers, either with a reply, a question back, or a suggested edit
you can accept or reject. Then you go back and forth on the same thread until
it is settled.

overlai works on any text file. The comments are kept beside the file, so the
document itself stays clean for your build, formatter and git history. Claude
Code and Codex work out of the box, and any other agent that can run a shell
command can join in.

```
  3 Bayesian models combine what you believed before   󰚩 claude: Splits the run-on… (2)
  4 prior is the thing that does the believing before, and the likelihood is the
  5 thing that does the data saying, and when you multiply them together and
  6 normalize you get the posterior which is what you believe after.
    + The
    + prior encodes what you believed before; the likelihood encodes what the data
    + say. Multiply them and normalize, and you get the posterior: what you believe
    + after.
```

## Why

Editor integrations for LLMs let you talk about a whole file or a selection,
and the agent then rewrites the text. That works for code. For writing it is
the wrong shape. Reviewing prose means many small conversations, each pinned to
a passage. Some end in an edit, some in a question answered, and some in a
decision to leave the text alone. You want to see each proposed change before
it lands, and to push back on it in place.

## How it works

- **Threads** are anchored to passages. Each holds a conversation between you
  and one or more agents, and may carry a **suggestion**: replacement text for
  the passage, drawn in the buffer as a tracked change.
- **Anchors** follow the text. While a buffer is open, extmarks track your
  edits. In between, each anchor stores the quoted passage and a little context
  around it, and finds its place again even after the file is rewrapped (by
  prettier, say) or edited outside Neovim. When the quoted text itself changes,
  the surrounding context places the anchor on the new wording. A passage that
  is deleted outright leaves its thread **detached**, still listed and ready to
  be reattached.
- **Review files** live in `.review/` at the project root, mirroring the
  document's path (`readings/bayes.md` → `.review/readings/bayes.md.json`).
  They are stable, pretty-printed JSON, so you can commit them or gitignore
  them.
- **Agents never edit your file.** `:Overlai ask` saves the buffer and starts
  the agent headless in the project root. The agent reads the threads with
  `overlai agenda` and answers through the `overlai` command: `reply`,
  `--suggest`, `comment`. Its answers show up in the buffer as they are
  written, and nothing reaches the file until you accept a suggestion.

## Requirements

- Neovim 0.10 or later
- For hand-offs: [Claude Code](https://claude.com/claude-code) (`claude`)
  and/or [Codex](https://github.com/openai/codex) (`codex`) on your PATH

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "gureckis/overlai.nvim",
  cmd = "Overlai",
  event = "BufReadPost",
  opts = {
    author = "todd",
  },
  keys = {
    { "<leader>rc", ":Overlai comment<CR>", mode = { "n", "x" }, desc = "Comment" },
    { "<leader>rs", ":Overlai suggest<CR>", mode = { "n", "x" }, desc = "Suggest edit" },
    { "<leader>rr", "<Cmd>Overlai reply<CR>", desc = "Reply" },
    { "<leader>rk", "<Cmd>Overlai show<CR>", desc = "Show thread" },
    { "<leader>ra", "<Cmd>Overlai accept<CR>", desc = "Accept suggestion" },
    { "<leader>rx", "<Cmd>Overlai reject<CR>", desc = "Reject suggestion" },
    { "<leader>rR", "<Cmd>Overlai resolve<CR>", desc = "Resolve" },
    { "<leader>rp", "<Cmd>Overlai panel<CR>", desc = "Panel" },
    { "<leader>rl", "<Cmd>Overlai ask claude<CR>", desc = "Hand off to Claude" },
    { "<leader>rL", "<Cmd>Overlai ask codex<CR>", desc = "Hand off to Codex" },
    { "]r", "<Cmd>Overlai next<CR>", desc = "Next thread" },
    { "[r", "<Cmd>Overlai prev<CR>", desc = "Previous thread" },
  },
}
```

overlai sets no global keys of its own. Use the spec above, `:Overlai`, or the
`<Plug>(overlai-…)` mappings. Run `:checkhealth overlai` to confirm it can
find the CLI and your agents.

## A session

1. Select a passage and run `:Overlai comment` (in visual mode,
   `:'<,'>Overlai comment`). Write your note in the float and press `<C-s>`.
   Without a selection, the comment goes on the current line.
2. To propose wording yourself, use `:Overlai suggest` on a selection. The
   float opens with the passage's text for you to edit.
3. Run `:Overlai ask` (or `:Overlai ask codex tighten section 2`, with any
   extra instructions after the agent's name). The status line and panel
   show what the agent is doing. When it finishes, you get a summary such as
   "claude finished: 3 replies, 2 suggested edits".
4. Read the threads in the panel (`:Overlai panel`), or put the cursor in a
   passage and run `:Overlai show`. **Accept** a suggestion and the text is
   replaced in your buffer and the thread resolves. **Reject** it and the
   thread stays open, so you can **reply** with why and ask again. **Resolve**
   a thread when you are done with it.

## Commands

| Command | |
| --- | --- |
| `:Overlai comment` | Start a thread on the selection (or current line) |
| `:Overlai suggest` | Suggest replacement text for the selection, or for the thread under the cursor |
| `:Overlai reply [id]` | Reply to the thread under the cursor |
| `:Overlai show [id]` | Open the thread in a float |
| `:Overlai accept [id]` / `reject [id]` | Act on the thread's pending suggestion |
| `:Overlai resolve [id]` / `reopen [id]` | Close or reopen a thread |
| `:Overlai delete [id]` | Delete a thread |
| `:Overlai next` / `prev` | Jump between open threads |
| `:Overlai panel` | Toggle the side panel |
| `:Overlai reanchor [id]` | Attach a detached thread to the selection |
| `:Overlai ask [agent] [instructions]` | Hand the document to an agent |
| `:Overlai cancel` | Stop the running agent |
| `:Overlai log` | Open the agent log |
| `:Overlai install-skill` | Link the skill (Claude Code and Codex) and the `overlai` CLI into place |

**Panel keys:** `]]` / `[[` next / previous thread · `<CR>` jump to
passage · `K` open thread · `r` reply ·
`a` accept · `x` reject · `R` resolve/reopen · `dd` delete ·
`H` show/hide resolved · `q` close · `g?` help.

## The CLI

The agent and the plugin share one command, `bin/overlai`. It runs the
plugin's Lua under `nvim -l`, so it needs nothing else installed. You can use
it yourself too:

```sh
overlai agenda readings/bayes.md          # threads waiting on the agent
overlai list readings/bayes.md --all
overlai comment readings/bayes.md --quote "the likelihood" --body "Define it here?"
overlai reply readings/bayes.md t3 --body "Agreed." --suggest - <<'EOF'
the probability of the data under each hypothesis
EOF
```

See [docs/format.md](docs/format.md) for the review file format and the
protocol in full.

## Agents outside Neovim

`:Overlai install-skill` links the [skill](skills/overlai/SKILL.md) into
`~/.claude/skills/` for Claude Code and `~/.codex/skills/` for Codex (both
read the same `SKILL.md` format), and `overlai` into `~/.local/bin`. After
that, any session of either knows the workflow; try "answer the overlai
comments on chapter 3".

## Configuration

Defaults, all optional:

```lua
require("overlai").setup({
  author = nil,             -- your name on comments ($USER)
  dir_name = ".review",
  auto_attach = true,       -- attach to buffers that have a review file
  show_resolved = false,
  signs = true,
  sign_text = "▎",
  virt_text = true,         -- latest message at the end of the line
  virt_text_width = 50,
  panel = {
    width = 50, position = "right", preview_messages = 2,
    auto_preview = true,    -- moving in the panel scrolls the document along
  },
  float = { border = "rounded", max_width = 80, max_height = 24 },
  agent = {
    default = "claude",
    save = true,            -- write the buffer before a hand-off
    web = false,            -- let the agent search the web and read pages
    instructions = nil,     -- added to every prompt
    prompt = nil,           -- replace the prompt: string with %{rel} etc, or function(ctx)
    agents = {},            -- name = function(prompt, ctx) return argv end
  },
})
```

Add an agent by giving the command that runs it. The agent's process gets
`overlai` on its PATH, plus `OVERLAI_AUTHOR` (the agent's name) and
`OVERLAI_ROLE=agent`, so its CLI calls are credited to it:

```lua
agent = {
  agents = {
    sonnet = function(prompt)
      return { "claude", "-p", prompt, "--model", "sonnet",
               "--allowedTools", "Bash(overlai:*),Read,Grep,Glob" }
    end,
  },
}
```

Highlight groups (`OverlaiRange`, `OverlaiRangeAgent`, `OverlaiCurrent`,
`OverlaiDelete`, `OverlaiAdd`, `OverlaiSign`, …) are listed in
`:help overlai-highlights`. For a statusline, `require("overlai").status()`
returns what a running agent is doing.

## Development

```sh
make test                          # the whole suite, headless
make test FILE=tests/test_ui.lua   # one file
```

The tests use [mini.test](https://github.com/echasnovski/mini.nvim) (cloned
into `deps/` on first run). The UI and agent tests drive a child Neovim; agent
runs use a fake agent script that calls the real CLI.

## License

MIT
