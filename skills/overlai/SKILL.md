---
name: overlai
description: Review a document with its author through overlai comment threads - read the open threads on a file, reply, propose suggested edits as tracked changes, and raise new comments, without editing the file directly. Use when the user asks you to address, answer or look at the comments, review threads, or overlai notes on a file, when a project has a .review/ directory, or when the user mentions overlai.
---

# Reviewing with overlai

overlai keeps comment threads on a text file, the way Word and Google Docs
do. Each thread is anchored to a passage and holds a conversation
between the author and reviewers (you included), sometimes with a suggested
replacement for the passage. The threads live in `.review/<path>.json` at the
project root, never in the file itself.

You take part through the `overlai` command. **Do not edit the document, and
do not edit the `.review/` files by hand.** The author accepts or rejects your
suggestions in their editor; that is what keeps the conversation reviewable.

If `overlai` is not on PATH, it is at `bin/overlai` in the overlai.nvim plugin
directory (for lazy.nvim, `~/.local/share/nvim/lazy/overlai.nvim/bin/overlai`).

## Workflow

1. See what is waiting on you:

   ```sh
   overlai agenda path/to/file.md
   ```

   Each thread shows its passage, nearby lines with line numbers, and the
   conversation. Threads waiting on the human are listed at the end; leave
   them alone.

2. Read the document around each passage (and more of it if needed) before
   answering.

3. Answer every thread waiting on you, in one of three ways.

   - **Suggest an edit** when the comment asks for a change or a change is the
     best answer. The suggestion replaces the thread's whole passage, exactly
     as printed under "Passage:", so repeat any part you keep. Put a short
     reason in `--body`.

     ```sh
     overlai reply file.md t3 --body "Splits the long sentence." --suggest - <<'EOF'
     The prior says what we believe before the data. The likelihood says how
     well each hypothesis predicts the data.
     EOF
     ```

     To replace a different stretch of text than the passage (the whole
     paragraph, the next sentence), add `--quote` with that text exactly as it
     appears in the file. Line breaks and runs of spaces in the quote need not
     match.

   - **Reply** with a question when the request is unclear, or with your
     reasoning when you disagree. Discussion is the point of the format.

     ```sh
     overlai reply file.md t4 --body "Do you want the formal definition here, or only the intuition?"
     ```

   - **Do both**: a reply with `--suggest` carries a note and an edit.

4. Raise new points only where they matter (more freely if the author asked
   for a review):

   ```sh
   overlai comment file.md --quote "exact passage" --body "This contradicts section 2."
   ```

   If the passage occurs more than once, overlai says on which lines; pass
   `--line N`.

5. Finish with a short summary of what you did.

## Rules

- Never resolve a thread the author opened; they decide when it is done. You
  may `overlai resolve` a thread you opened once it is settled.
- Keep the author's voice, the document's markdown conventions and its line
  wrapping. Follow the project's own writing instructions (CLAUDE.md,
  AGENTS.md, style guides) when it has them.
- One `overlai` call per shell command. Pass any text containing quotes,
  newlines, backticks or `$` on stdin through a quoted heredoc (`<<'EOF'`);
  only one option per call can read stdin (`-`).
- A suggestion identical to the current text is refused; a passage the file no
  longer contains is reported as detached. Ask the author about a detached
  thread instead of guessing.

## Reference

```text
overlai agenda FILE                      threads waiting on you, with context
overlai list FILE [--all]                one line per thread
overlai show FILE ID                     one thread in full
overlai reply FILE ID [--body T] [--suggest T] [--quote Q]
overlai comment FILE --quote Q [--line N] [--body T] [--suggest T]
overlai resolve FILE ID / overlai reopen FILE ID
  --as NAME   author name (default $OVERLAI_AUTHOR)
  --json      machine-readable output
```
