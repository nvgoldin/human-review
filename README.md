# human-review

Native macOS app for GitHub-style review of local markdown files. Built for
both humans (GUI) and agents (duplex JSONL on stdio). Every change streams
to stdout; the sidecar JSON file is the canonical source of truth.

```bash
human-review file.md [file2.md ...]
```

## Model

Everything is a **comment**. Comments form **threads** via `replyTo`. A
thread is **active** (open) or **settled** (resolved). Replying to a settled
thread auto-reopens it. Agents and humans participate symmetrically: agent
posts a comment → human replies → agent replies → someone resolves.

```
comment (root)                    ← anchored to a markdown block
  ├─ comment (reply)
  ├─ comment (reply)
  │    └─ comment (reply-to-reply)
  └─ comment (reply)
[resolved | active]               ← one bit per thread
```

There is no separate "flag" type. An agent flagging a block for re-review is
just a new top-level comment. The active/settled state is what `n` / `N` walks.

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

## GUI

- Hover any block → blue `+` → click to start a new thread
- Each thread renders inline under its block; replies appear inside the thread
- A reply composer sits at the bottom of every active thread
- Settled threads collapse to a one-line header; click to expand and read history
- Click **Resolve** to settle, **Reopen** to un-settle (or just reply, which auto-reopens)

## Keyboard

| Shortcut | Action |
|---|---|
| `↑` / `↓` (`k` / `j`) | Move focus between blocks |
| `Enter` | Open composer on focused block — replies to active thread if any, else new |
| `n` / `N` | Jump to next / previous **active thread** (wraps) |
| `Tab` | In composer: submit comment + auto-advance focus |
| `⌘Enter` | In composer: submit (alternative) |
| `Esc` | Cancel open composer |
| `⌘]` / `⌘[` | Next / previous file |
| `⌘R` | Reload current source from disk + smart re-anchor |
| `⌘W` or click ✓ Exit | Close window (fires `exit` event) |

## Headless CLI

```
human-review add     FILE.md --line N --body "TEXT" [--author NAME]   start a new thread
human-review add     FILE.md --reply-to UUID --body "TEXT"            reply
human-review list    FILE.md                                          pretty JSON
human-review delete  FILE.md --id UUID                                remove comment (root → whole thread)
human-review resolve FILE.md --id UUID                                settle thread
human-review reopen  FILE.md --id UUID                                un-settle thread
human-review export  FILE.md                                          force-write FILE.review.md
human-review reload  FILE.md                                          re-anchor after editing source
```

## Duplex agent protocol

Auto-active when stdin is piped (not a tty). One JSON command per line in,
one JSON event per line out.

**Commands you send:**

```json
{"cmd":"add",     "file":"…", "line":N, "body":"…"}
{"cmd":"add",     "file":"…", "replyTo":"UUID", "body":"…"}
{"cmd":"resolve", "file":"…", "id":"UUID"}
{"cmd":"reopen",  "file":"…", "id":"UUID"}
{"cmd":"delete",  "file":"…", "id":"UUID"}
{"cmd":"reload",  "file":"…"}
{"cmd":"open",    "file":"…"}
{"cmd":"focus",   "file":"…"}
{"cmd":"ping"}
```

**Events you receive:**

| event | payload |
|---|---|
| `session_start` | `{files:[{file, comments[]}]}` on launch |
| `added` | `{file, comment}` — new thread or reply (check `comment.replyTo`) |
| `edited` | `{file, comment}` body changed |
| `deleted` | `{file, comment}` removed (root removal deletes the thread) |
| `resolved` | `{file, comment}` thread root marked settled |
| `reopened` | `{file, comment}` thread root un-settled (manual or auto via reply) |
| `reloaded` | `{file, reanchor:{unchanged,relocated,orphaned}}` |
| `opened` | `{file}` file appended to session |
| `focused` | `{file}` GUI switched to file |
| `pong` | `{}` reply to ping |
| `command_error` | `{raw, reason}` |
| `exit` | `{files:[{file, comments[]}]}` window closed — final state |

**Comment record:**

```jsonc
{
  "id": "UUID",
  "replyTo": "UUID" | null,    // null = thread root
  "anchorLine": 42,             // 0-indexed; mirrors root for replies
  "anchorText": "first 80 chars of the block",
  "body": "…",
  "author": "you" | "agent" | …,
  "createdAt": "ISO8601",
  "resolved": false,            // only meaningful on root
  "orphaned": false             // root only; true if reload couldn't find anchorText
}
```

## Python client (recommended for agents)

The repo ships a single-file client at `clients/python/human_review.py`. Drop
it next to your agent script (no third-party deps, Python 3.9+). The whole
review loop becomes 5 lines:

```python
from human_review import HumanReview

with HumanReview(["notes.md"]) as hr:
    root = hr.add(file="notes.md", line=42, body="please verify the claim about X")
    reply = hr.wait_for_reply(root["id"], timeout=600)   # blocks until human responds
    if reply:
        hr.reply(file="notes.md", reply_to=root["id"], body=f"thanks {reply['author']}")
        hr.resolve(file="notes.md", root_id=root["id"])
```

Other useful methods on the client:

| Method | Purpose |
|---|---|
| `add(file, line, body)` | Start a new thread, blocks until the `added` event lands. Returns the comment. |
| `add(file, reply_to, body)` / `reply(...)` | Post a reply (auto-reopens settled thread). |
| `resolve(file, root_id)` / `reopen(file, root_id)` | Settle / un-settle a thread. |
| `delete(file, comment_id)` | Remove a comment (root removal deletes whole thread). |
| `reload(file)` | Re-read source + re-anchor by `anchorText`. |
| `open_file(file)` / `focus(file)` | Append / switch files in a running session. |
| `ping()` | Liveness check. |
| `events(since=0, timeout=…)` | Generator over the full event stream. Independent per consumer. |
| `wait_for_reply(root_id, timeout)` | Block until a non-agent reply lands in the thread. |
| `wait_for_resolve(root_id, timeout)` | Block until the thread is settled. |
| `wait_for_exit(timeout)` | Block until the GUI closes; returns the final snapshot. |
| `comments(file)` / `active_threads(file)` | Local-derived view of the current state. |

See `clients/python/example_basic.py` for a complete runnable example.

### Raw subprocess (when not using the client)

```python
import json, subprocess
proc = subprocess.Popen(
    ["human-review", "a.md", "b.md"],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1,
)
proc.stdin.write(json.dumps({"cmd": "add", "file": "a.md", "line": 42,
                             "body": "verify"}) + "\n")
proc.stdin.flush()
# Then iterate proc.stdout line-by-line and JSON-decode each event.
```

## Per-file side effects

```
FILE.md
FILE.md.comments.json   ← canonical sidecar, atomically updated on every change
FILE.review.md          ← markdown copy with [!review] callouts (one per thread)
```

The `.review.md` is regenerated on every change and groups replies under their
thread root with a `→` reply marker.

## Limitations

- Block-level anchor granularity (no per-line within a paragraph)
- `ReviewStore`s for all session files load on startup; external sidecar writes
  to unvisited files aren't auto-detected until `⌘R` reload
- Re-anchoring after external source edits is best-effort: roots keep
  `anchorText` (first 80 chars) and re-search after `⌘R` / reload-command;
  unmatched roots get `orphaned: true` and render in a separate section
