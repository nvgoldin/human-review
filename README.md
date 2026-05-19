# human-review

Native macOS app for GitHub-style review of local markdown files. Built for
humans (GUI) **and agents** (pure shell). Every interaction is a `human-review
<subcommand>` call — no Python, no client library, no subprocess pipes. A
running GUI is optional: the agent works identically whether or not your
window is open.

```bash
human-review file.md [file2.md ...]
```

## Model

A *comment* anchors to a markdown block. A *thread* is a comment + replies.
A thread is **active** (`resolved:false`) or **settled** (`resolved:true`).
Replying to a settled thread auto-reopens it. There is no separate "flag" type —
agents and humans post the same kind of comment.

```
comment (root)                    ← anchored to a markdown block
  ├─ comment (reply)
  ├─ comment (reply-to-reply)
  └─ comment (reply)
[resolved | active]               ← one bit per thread, on the root
```

## Per-file sidecars

For each `notes.md`:

```
notes.md                   source (read-only to human-review)
notes.md.comments.json     canonical state — atomically updated on every mutation
notes.md.events.jsonl      append-only event log — tail this for live updates
notes.review.md            human-readable copy with [!review] callouts per thread
```

Any process that mutates state (the GUI, your shell agent, anything) updates
all three. A running GUI auto-reloads when an external process mutates the
sidecar — no `⌘R` needed.

## Install

```bash
git clone <this-repo> ~/src/human-review     # or move it there
cd ~/src/human-review
./install.sh
```

`install.sh` builds release and symlinks `~/bin/human-review` to
`~/src/human-review/.build/release/human-review`. Every `./install.sh` (or
plain `swift build -c release`) in the repo is immediately the version your
shell launches.

Requires Swift 5.9+, macOS 13+. `marked.js` is bundled — no network at runtime.

## GUI keyboard

| Shortcut | Action |
|---|---|
| `↑` / `↓` (`k` / `j`) | Move focus between blocks |
| `Enter` | Open composer — replies to active thread if any, else starts new |
| `n` / `N` | Jump to next / previous **active thread** (wraps) |
| `Tab` | In composer: submit + auto-advance focus |
| `⌘Enter` | In composer: submit (alternative) |
| `Esc` | Cancel open composer |
| `⌘]` / `⌘[` | Next / previous file |
| `⌘R` | Reload current source from disk + smart re-anchor |
| `⌘W` or ✓ Exit | Close window (fires `exit` event) |

## CLI for agents

### Mutate

```
human-review add     FILE.md --line N    --body "TEXT" [--author NAME]
human-review add     FILE.md --reply-to UUID --body "TEXT"   [--author NAME]
human-review resolve FILE.md --id UUID
human-review reopen  FILE.md --id UUID
human-review delete  FILE.md --id UUID            (root → whole thread)
human-review reload  FILE.md                      (re-anchor after editing source)
human-review export  FILE.md                      (force-write FILE.review.md)
```

Each prints the resulting record as JSON on stdout, and appends one line to
`FILE.md.events.jsonl`.

### Read

```
human-review list    FILE.md                      All comments as a JSON array
human-review threads FILE.md [--active|--settled]  Thread roots + reply counts
human-review get     FILE.md --id UUID            One comment as JSON
```

### Subscribe to live events

```
human-review watch FILE.md [FILE2 ...]
  [--from-start]                                  Replay from line 1 (default: from now)
  [--types added,resolved,...]                     Comma-separated event-type filter
```

Tails `FILE.md.events.jsonl` and prints each new event to stdout. Blocks
until killed.

### Block-and-wait

Exit 0 on match (printing the matching event JSON), exit 124 on timeout.

```
human-review wait FILE.md --reply-to UUID [--from-author NAME] [--timeout S]
human-review wait FILE.md --resolve   UUID                     [--timeout S]
human-review wait FILE.md --exit                               [--timeout S]
```

### Housekeeping

```
human-review prune FILE.md          Truncate events.jsonl
```

## Complete agent flow (pure shell)

```bash
# 1. Open a GUI for the human in the background
human-review notes.md &

# 2. Post an inline review note, capture the thread root id
ROOT=$(human-review add notes.md --line 42 \
         --body "verify the claim about X" | jq -r '.id')

# 3. Block until the human replies (up to 10 minutes)
REPLY=$(human-review wait notes.md --reply-to "$ROOT" --timeout 600)
echo "human said: $(echo "$REPLY" | jq -r '.comment.body')"

# 4. Send a follow-up and resolve
human-review add notes.md --reply-to "$ROOT" --body "thanks, addressed."
human-review resolve notes.md --id "$ROOT"

# 5. (Optional) wait for the user to close the window
human-review wait notes.md --exit
```

That's the whole agent loop. For an LLM-driven agent, the model invokes those
commands via its shell / Bash tool — same as it would invoke `git`, `grep`, or
`jq`. There is no library to install and no protocol to learn beyond what
`human-review --help` documents.

## Event shapes

Events emitted to stdout (when a GUI is running with `--stream`, the default)
and appended to `FILE.md.events.jsonl`:

| event | payload |
|---|---|
| `gui_opened` | `{file, files:[{file, comments[]}]}` GUI started for that file |
| `gui_closed` | `{file, files:[{file, comments[]}]}` GUI exited for that file |
| `added` | `{file, comment}` new thread root OR reply (check `comment.replyTo`) |
| `edited` | `{file, comment}` body changed |
| `deleted` | `{file, comment}` removed (root removal deletes the whole thread) |
| `resolved` | `{file, comment}` thread root marked settled |
| `reopened` | `{file, comment}` thread root un-settled (manual or auto-via-reply) |
| `reloaded` | `{file, reanchor:{unchanged, relocated, orphaned}}` |

Comment record:

```jsonc
{
  "id":         "UUID",
  "replyTo":    "UUID" | null,    // null = thread root
  "anchorLine": 42,               // 0-indexed; mirrors root for replies
  "anchorText": "first 80 chars of the anchored block",
  "body":       "…",
  "author":     "you" | "agent" | …,
  "createdAt":  "ISO8601",
  "resolved":   false,            // only meaningful on the root
  "orphaned":   false             // root only; true if reload couldn't relocate anchorText
}
```

## Optional: long-lived parent process (stdin protocol)

If your agent prefers a single long-lived `human-review` subprocess instead of
many one-shot CLI calls, the same commands are accepted as JSONL on stdin
when stdin is piped. See `--help` for the full schema. For most use cases the
shell-native flow above is simpler and the per-file event log makes it
equivalent in expressiveness.

## Limitations

- Block-level anchor granularity (no per-line within a paragraph)
- Re-anchoring after external source edits is best-effort: roots keep
  `anchorText` (first 80 chars) and re-search after `⌘R` / `reload`; unmatched
  roots get `orphaned: true` and render in a separate section
- `wait --exit` only fires when a GUI session for that file closes. If you
  never open a GUI, use `wait --reply-to` / `wait --resolve` with a timeout
- `events.jsonl` grows forever. Run `human-review prune FILE.md` periodically
  if it gets large
