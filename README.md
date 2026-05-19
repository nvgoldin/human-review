# human-review

Native macOS app for GitHub-style review of local markdown files. Built for
both humans and agents — every change streams to stdout as JSONL, and a sidecar
JSON file is the canonical source of truth.

```bash
human-review file.md [file2.md ...]
```

## What it does

- Renders each markdown file in a native window (SwiftUI + WKWebView, marked.js for HTML).
- **Inline comments** — hover any block, click `+`, type, hit Tab to submit. Comment threads render right under the anchored block, like GitHub PR review.
- **Multi-file sessions** — pass several files; the header shows `N / M · filename` with `⌘[` / `⌘]` to navigate. On the last file the right chevron becomes a green **✓ Exit** button.
- **Always-on persistence** — no save button. Every add / edit / delete writes:
  - `<file>.md.comments.json` — canonical sidecar (JSON, schema below)
  - `<file>.review.md`        — markdown copy with `> [!review]` callouts inserted after each anchored block
- **Agent-ready streaming** — by default emits one JSONL event per change to stdout:
  - `session_start` on launch (every file's current comment list)
  - `added` / `deleted` / `edited` per interaction
  - `exit` on close (final per-file snapshot)
- Same binary also exposes headless subcommands for scripted use.

## Install

```bash
git clone <this-repo> ~/src/human-review     # or move it there
cd ~/src/human-review
./install.sh
```

`install.sh` builds release and symlinks `~/bin/human-review` to
`~/src/human-review/.build/release/human-review`. **The binary is a symlink** —
every `swift build -c release` (or `./install.sh`) in the repo is immediately
the version your shell launches. No copy step, no stale binary.

Requirements: Swift 5.9+ (Xcode or macOS command-line tools), macOS 13+. The
marked.js renderer is bundled as a resource — no network needed at runtime.

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| `↑` / `↓` (or `k` / `j`) | Move keyboard focus between blocks |
| `Enter` | Open composer on focused block |
| `n` / `N` | Jump to next / previous **flagged** block (wraps) |
| `Tab` | In composer: submit comment + auto-advance focus |
| `⌘Enter` | In composer: submit comment (alternative) |
| `Esc` | Cancel open composer |
| `⌘]` / `⌘[` | Next / previous file |
| `⌘W` or click ✓ Exit | Close window (fires the `exit` event) |
| `⌘R` | Reload current file's source from disk + smart re-anchor |

## CLI

```
human-review <file1.md> [file2.md ...]   GUI mode (stream + emit-on-exit ON)
  --no-stream                            Disable live JSONL events
  --no-emit-on-exit                      Disable final exit-summary event

human-review add     <file.md> --line N --body "TEXT" [--author NAME]
human-review flag    <file.md> --line N --reason "TEXT" [--author NAME]
human-review list    <file.md>                       Pretty-print sidecar comments as JSON
human-review delete  <file.md> --id UUID             (alias: resolve)
human-review export  <file.md>                       Force-write <basename>.review.md
human-review reload  <file.md>                       Re-anchor comments after editing source
```

The `flag` subcommand creates a `kind: "flag"` comment with `author: "agent"`.
Flagged blocks render with a yellow accent in the GUI; `n` / `N` walk between
them; clicking **Resolve** in the thread removes the flag and emits a
`resolved` event.

## File layout per source file

```
notes.md
notes.md.comments.json   ← canonical state, schema: { file, sourceHash, comments[] }
notes.review.md          ← human-readable, regenerated on every change
```

Comment record (also the shape emitted on stdout):

```json
{
  "id": "UUID",
  "anchorLine": 8,
  "anchorText": "first 80 chars of the anchored block",
  "body": "the comment body",
  "author": "Nadav Goldin",
  "createdAt": "2026-05-19T09:32:51Z"
}
```

## Agent integration

### Pull (offline)

After the user exits, just read the sidecar:

```bash
human-review notes.md         # foreground; or background and wait $!
jq '.comments' notes.md.comments.json
```

### Push (live, one-way)

Consume stdout as the GUI runs:

```bash
human-review notes.md > /tmp/review.log &
tail -F /tmp/review.log | jq -c '.'
# events: session_start | added | deleted | edited | reloaded | flagged | resolved | opened | focused | exit
```

### Duplex (live, bidirectional)

Pipe JSONL **commands** into stdin while reading **events** from stdout —
the agent controls the running session without restarting human-review:

```python
import json, subprocess, threading
proc = subprocess.Popen(
    ["human-review", "a.md", "b.md"],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE,
    text=True, bufsize=1,
)
def read():
    for line in proc.stdout:
        ev = json.loads(line)
        print("event:", ev["event"])
threading.Thread(target=read, daemon=True).start()
def send(cmd): proc.stdin.write(json.dumps(cmd) + "\n"); proc.stdin.flush()

send({"cmd": "flag",    "file": "a.md", "line": 42, "reason": "verify"})
send({"cmd": "add",     "file": "a.md", "line": 10, "body": "agent note"})
send({"cmd": "open",    "file": "c.md"})              # append a new file live
send({"cmd": "focus",   "file": "b.md"})              # switch GUI to a file
send({"cmd": "reload",  "file": "a.md"})              # re-read source + re-anchor
send({"cmd": "resolve", "file": "a.md", "id": UUID})  # remove a flag/comment
send({"cmd": "ping"})                                  # liveness — replies "pong"
```

Stdin is read **only when it's piped** — when you launch `human-review` from
a terminal manually, stdin stays the tty and the protocol is dormant.

### Agent flag flow

```
agent edits the doc + sends `flag` commands for spots needing review
                       ↓
human sees 🚩 N in header, presses `n` to walk between flags,
either resolves them or adds counter-comments
                       ↓
agent reads the stream — knows what was resolved, what got pushback,
                       updates the doc, sends new flags…
                       ↓                          (no human-review restart)
```

The sidecar JSON (`<file>.md.comments.json`) is always authoritative; the
stream is the live notification channel.

## How block anchoring works

Source is split into blocks separated by blank lines (fenced code blocks stay
intact). Each block is rendered to HTML and wrapped in a `<div data-line="N">`
where N is the 0-indexed source line of the block's first line. The headless
`add` subcommand snaps a user-provided 1-indexed line to the nearest block
start so you don't have to count lines exactly.

## Limitations

- Block-level granularity only — no per-line comments inside a single paragraph or code block.
- All `ReviewStore`s are loaded into memory on session start. If an external process writes to a sidecar of a file you haven't visited yet, the GUI won't see the change until `⌘R` reload on that file.
- Re-anchoring after the source is edited between sessions is best-effort: comments keep `anchorText` (first 80 chars), but there's no automatic relocation if line numbers shift.
