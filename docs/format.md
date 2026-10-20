# Review files and the agent protocol

This page specifies what overlai stores and how agents take part, for anyone
writing another client: an editor plugin, a script, or an agent integration.

## Where review files live

The **root** of a document is the nearest ancestor directory that contains a
`.review/` directory. If there is none, it is the nearest ancestor with `.git`,
and failing that, the document's own directory. The review file is at

```
<root>/.review/<path of the document relative to root>.json
```

To keep review files in a sub-project, create an empty `.review/` directory
there.

## Format (version 1)

```json
{
  "version": 1,
  "file": "readings/bayes.md",
  "next_id": 4,
  "threads": [
    {
      "id": "t3",
      "status": "open",
      "anchor": {
        "quote": "the likelihood",
        "prefix": "We multiply the prior by ",
        "suffix": " and normalize to get the poste",
        "line": 42
      },
      "messages": [
        {
          "author": "todd",
          "role": "human",
          "body": "Too terse?",
          "created_at": "2026-10-17T21:18:58Z"
        },
        {
          "author": "claude",
          "role": "agent",
          "body": "Names what the likelihood is.",
          "suggestion": {
            "status": "pending",
            "text": "the likelihood of the data under each hypothesis"
          },
          "created_at": "2026-10-17T21:19:10Z"
        }
      ],
      "created_at": "2026-10-17T21:18:58Z"
    }
  ]
}
```

| Field | |
| --- | --- |
| `version` | Format version. Clients refuse versions newer than they know. |
| `file` | The document's path relative to the root. |
| `next_id` | Ids are `t1`, `t2`, … and never reused. |
| `threads[].status` | `open` or `resolved`. Resolved threads also have `resolved_at` and `resolved_by`. |
| `threads[].anchor` | The passage, as below. |
| `messages[].role` | `human` or `agent`. Whose turn it is depends on the role of the last message. |
| `messages[].body` | Markdown. May be empty when the message only carries a suggestion. |
| `suggestion.text` | Replacement for the passage. |
| `suggestion.status` | `pending`, `accepted`, `rejected`, or `superseded` (when a newer suggestion arrives in the same thread). |
| `suggestion.anchor` | Present only when the suggestion replaces different text from the thread's passage. Same shape as `anchor`. |

Keys are written in a fixed order with two-space indentation, so rewriting an
unchanged document produces identical bytes.

### Anchors

An anchor is a text-quote selector: `quote` is the exact passage, `prefix` and
`suffix` are up to 32 bytes on either side (never splitting a UTF-8
character), and `line` is the 1-based line where the passage starts. To
resolve an anchor in a text:

1. Collapse every run of whitespace, in both the text and the anchor, to a
   single space. Re-wrapping changes nothing after this step.
2. Find every occurrence of the quote. If there are several, score each by how
   many characters of the prefix match just before it and of the suffix just
   after it, and take the best. If scores tie, take the one nearest `line`.
3. If the quote does not occur at all, look for the prefix and the suffix with
   a gap between them of at most `3 × quote length + 40`. The anchor re-forms
   around the text in that gap. This rescues passages whose wording was
   edited.
4. Otherwise the thread is **detached**.

An open buffer tracks passages directly with extmarks and rewrites the anchors
whenever the buffer is written, so anchors on disk describe the file on disk.

### Concurrency

Every change is a read-modify-write under a lock: the directory
`<review file>.lock`, created with `mkdir`. A lock older than 10 seconds is
treated as stale. Writes go to a temporary file that is then renamed over the
review file, so readers never see a partial file. Editors watch the
`.review/` directory and re-read the file when it changes.

## The agent protocol

An agent is any program that can run `overlai`. When overlai hands off a
document, it:

1. writes the buffer, so the file on disk is current;
2. runs the agent in the root with `overlai` on its PATH and with
   `OVERLAI_AUTHOR=<agent name>` and `OVERLAI_ROLE=agent` set;
3. gives it a prompt (see `lua/overlai/agent.lua`, or the skill in
   `skills/overlai/SKILL.md`) that says to start with `overlai agenda FILE`,
   to answer every thread waiting on it, and never to edit the file;
4. afterwards, compares the document's hash and warns if the agent changed it.

`overlai agenda` prints the threads waiting on the agent: each one with its
passage, two lines of context on either side with line numbers, and the full
conversation. It also lists the open threads that are waiting on the human.
The agent answers with:

```
overlai reply FILE ID [--body TEXT] [--suggest TEXT] [--quote Q]
overlai comment FILE --quote Q [--line N] [--body TEXT] [--suggest TEXT]
overlai resolve FILE ID
```

Quotes match whitespace-insensitively. The CLI refuses an ambiguous quote, and
lists the lines it occurs on so the agent can add `--line`. It also refuses a
missing quote and a suggestion that changes nothing. Any one value can be `-`,
to read it from stdin, which avoids quoting problems in shell commands. Every
command takes `--json`.
