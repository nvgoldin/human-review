---
name: human-review
description: Run a human review loop with the human-review macOS app. Open one or more markdown or code files in the review GUI, arm a persistent monitor on the comment stream, and answer every comment the human writes — fast, in-thread, with subagents doing the work. Trigger on "/human-review", "open a human review", "put this up for review", "let me review that doc", "human-review this file", "I want to comment on this", "watch my comments", "did I leave any comments", or any request to collect, monitor, answer, or close out review comments on a local file.
user-invocable: true
---

# /human-review — review loop with a human in the seat

`human-review` is a native macOS app for GitHub-style review of local markdown and
code files. The human reviews in a GUI. You drive the identical state from the
shell. There is no server, no daemon, and no protocol beyond the subcommands.

This skill is the contract for the agent side of that loop. Follow it exactly. The
failure this skill exists to prevent is an agent that opens the window, walks away,
and leaves comments sitting unread.

## Read the user's preferences first

Every `human-review` subcommand except `config`, `prompt`, and `--help` prints the
user's review preferences to stderr before it does anything else. Read them. They
come from `human-review config` and they **override this skill wherever they
disagree with it**.

```bash
human-review prompt
```

If that exits 1, no preferences are configured — this skill's defaults stand.

## The loop

Six steps. Do all six. Never stop after step 2.

### 1. Confirm the target files exist

Use absolute paths. Every sidecar is written next to the source file.

```bash
ls -la /abs/path/doc.md
```

### 2. Open the GUI without blocking

The GUI runs an `NSApplication` event loop and does not return until the human
closes the window. Launch it as a background task so your own thread stays free:

Bash tool, `run_in_background: true`:

```bash
human-review /abs/path/a.md /abs/path/b.md /abs/path/c.py
```

One session takes many files. `⌘]` and `⌘[` switch between them. Open every file
the human needs to see in that one command — a second `human-review` invocation
opens a second window, and a running GUI cannot be told to add a file from the
CLI. To bring another file in later, either relaunch with the full list, or put an
absolute markdown link to it in a comment and let the human click **Open in
review** in the preview overlay.

When the human closes the window the background task ends and you are notified.
That is your session-over signal.

### 3. Arm the monitor — this step is not optional

Arm it in the same turn you open the GUI. Use the `Monitor` tool with
`persistent: true`:

```bash
human-review watch /abs/path/a.md /abs/path/b.md --no-prompt \
  --types added,edited,deleted,resolved,reopened,gui_closed \
| jq -rc --unbuffered '
    select(.event != "added" or .comment.author != "agent")
    | "\(.event) | \(.comment.author // "-") | id=\(.comment.id // "-") | replyTo=\(.comment.replyTo // "null") | \(.comment.body // "" | gsub("\n"; " ⏎ ") | .[0:400])"'
```

Set `description` to something specific, such as `review comments on a.md, b.md`.

What that command does, and why each part is load-bearing:

| Part | Why |
|---|---|
| `watch` with several files | One monitor covers the whole session. |
| `--types …` | Drops `read` and `reloaded` chatter. Keeps `gui_closed`, so a closed window is never silent. |
| `--no-prompt` | Suppresses the preferences banner on a long-lived stream. |
| `jq --unbuffered` | Without it, events sit in jq's buffer and you learn nothing. |
| `select(… author != "agent")` | Drops the echo of your own posts. Human comments and every state change still come through. |
| `gsub("\n"; " ⏎ ")` | One event, one notification line. |

`watch` marks each incoming comment as read under the author `agent`, which is the
✓✓ the human sees in the GUI. That is automatic. It is a read receipt, not a
reply, and it does not discharge step 5.

### 4. Post the opening comment

Say what you want looked at and how you will behave. Whole-document scope:

```bash
human-review add /abs/path/a.md --global \
  --body "Ready for review. I'm watching the comment stream and will reply in-thread. Anything you flag, I fix in the document itself — no changelog sections."
```

### 5. Answer every event, in the turn you receive it

A monitor notification is work, not information. When one lands:

1. Read the full thread if the one-line projection is not enough:
   `human-review get FILE --id <UUID>` or `human-review threads FILE --active`.
2. Reply within that same turn. Acknowledge first, even when the answer will take
   an hour. A comment with no reply is the one thing this loop must never produce.
3. Do the work. Spawn a subagent for anything past a one-line change, so the main
   thread stays free for the next comment.
4. Reply again with the outcome, then resolve.

Reply shapes — keep them short, and match the user's configured style:

| Situation | Body |
|---|---|
| Picked up, answering now | `✓✓ got it — <what you're about to do>.` |
| Delegated | `✓✓ on it — subagent is <task>. I'll post the result here.` |
| Answered | The answer. No preamble, no restating the question. |
| Fixed | `Done — <what changed>, ` + a `file.md:120` reference. Then resolve. |
| You disagree | The fact, the evidence, one question. Do **not** resolve. |
| Needs the human | The blocker and the single decision you need. Leave it active. |

### 6. Close the session out

Before you report the work finished:

```bash
human-review threads /abs/path/a.md --active     # must be []
```

Every file. Then stop the monitor with `TaskStop`, and report the artifacts: file
paths, thread counts, what changed.

Never resolve a thread to make that list empty. Resolve only what you acted on. A
thread you could not settle stays active and gets named in your report.

## Choosing where a comment goes

| What you are saying | Command |
|---|---|
| Anything inside an existing thread | `add FILE --reply-to <UUID>` |
| A new point about one block or line | `add FILE --line N --body "…"` |
| A point about the whole file | `add FILE --global --body "…"` |

`--reply-to` accepts any UUID in the thread, not only the root. Replies inherit
the root's scope, so `--global` is ignored on a reply.

Never open a new root to answer an existing thread. It splits the conversation and
the human loses the context they wrote in.

## Editing the document under review

The document states what is true now.

1. Edit the source file in place with `Edit`.
2. Delete text that is no longer true. Do not add `UPDATE:`, `EDIT:`, `Correction:`,
   or a dated note. Do not keep superseded text struck through.
3. Keep open questions — they are current truth. Put them at the end.
4. Re-anchor afterwards:

   ```bash
   human-review reload /abs/path/a.md
   ```

   It prints `{"orphaned": N, "relocated": N, "unchanged": N}`. A non-zero
   `orphaned` means a thread's anchor block no longer exists. Reply in each
   orphaned thread saying the block was removed and why, then resolve it.

## Command reference

Mutate — each prints the resulting record as JSON and appends one event:

```
human-review add      FILE --line N        --body "TEXT" [--author NAME]
human-review add      FILE --reply-to UUID --body "TEXT" [--author NAME]
human-review add      FILE --global        --body "TEXT" [--author NAME]
human-review resolve  FILE --id UUID
human-review reopen   FILE --id UUID
human-review delete   FILE --id UUID          # root deletes the whole thread
human-review reload   FILE                    # re-anchor after you edit the source
human-review attention FILE --id UUID         # scroll + pulse the GUI onto a comment
```

Read — `get` and `wait` mark the comment read; `list` and `watch` need `--ack`:

```
human-review list     FILE [--scope block|global|all]
human-review threads  FILE [--active|--settled] [--scope block|global|all]
human-review get      FILE --id UUID [--no-ack]
human-review ack      FILE --id UUID
```

Stream and block:

```
human-review watch    FILE [FILE …] [--from-start] [--types LIST] [--no-ack]
human-review wait     FILE --reply-to UUID [--from-author NAME] [--timeout S]
human-review wait     FILE --resolve UUID [--timeout S]
human-review wait     FILE --exit [--timeout S]
```

`wait` exits 0 with the matching event on stdout, or 124 on timeout.

Preferences:

```
human-review prompt                                   # the user's review rules
human-review config --list
human-review config --global global.prompt "TEXT"
human-review config --global global.promptFile PATH
```

Full surface: `human-review --help`.

## Use `wait`, or use the monitor

The monitor is the default. It is non-blocking and it covers the whole session.

Use `wait` only when the human has explicitly said they are answering right now and
you have nothing else to do. Always pass `--timeout`. Never leave a bare `wait` in
front of a long-running plan — an unattended block burns the hours the human
expected you to be working.

## Writing comment bodies

Bodies render as GitHub-flavored markdown in the GUI, so styling is not decoration
— unstyled output renders wrong.

- Wrap every identifier, path, flag, and command in backticks.
- Fence code with a language tag: ` ```python `, ` ```bash `, ` ```json `.
- Check the fence closes before you post. An unclosed fence swallows the rest of
  the comment.
- Keep it to a few lines. The comment column is narrow.
- Absolute markdown links to other local files open as a preview overlay:
  `see [the spec](/Users/me/docs/spec.md#anchoring)`.

## Sidecar files

Three sidecars sit next to the source file and stay in sync. For `notes.md`:

| File | What it is |
|---|---|
| `notes.md.comments.json` | Canonical state, atomically rewritten on every mutation. |
| `notes.md.events.jsonl` | Append-only event log. This is what `watch` tails. |
| `notes.review.md` | Human-readable copy with `> [!review]` callouts. The source extension is replaced, not appended. |

The source file itself is never modified by the app. Read the sidecars if you need
to; write them only through the CLI.

## Anti-patterns

Each of these has actually happened. Do not repeat them.

- Opening the GUI and not arming the monitor. The human comments into a void.
- Treating the ✓✓ read receipt as an answer.
- Blocking on `wait` while the human is away.
- Answering in a new root instead of `--reply-to`.
- Resolving a thread you did not act on, to clear the active list.
- Appending an `UPDATE:` section instead of editing the document.
- Editing the source and not running `reload`, so every anchor drifts.
- Doing a large fix inline while five more comments queue up behind it.
- Deleting the human's comment. Reply and resolve instead.
- Ending the session with active threads and not naming them in the report.
