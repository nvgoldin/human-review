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
| `⌘]` / `⌘[` | Next / previous file |
| `⌘W` or click ✓ Exit | Close window (fires the `exit` event) |
| `⌘R` | Reload current file's source from disk |
| `Tab` | In composer: submit comment |
| `⌘Enter` | In composer: submit comment (alternative) |
| `Esc` | Cancel open composer |

## CLI

```
human-review <file1.md> [file2.md ...]   GUI mode (stream + emit-on-exit ON)
  --no-stream                            Disable live JSONL events
  --no-emit-on-exit                      Disable final exit-summary event

human-review add <file.md> --line N --body "TEXT"   Headless add (snaps to nearest block)
human-review list <file.md>                          Pretty-print sidecar comments as JSON
human-review delete <file.md> --id UUID
human-review export <file.md>                        Force-write <basename>.review.md
```

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

Two equivalent paths:

**Push** — consume stdout as the GUI runs:

```bash
human-review notes.md > /tmp/review.log &
tail -F /tmp/review.log | jq -c 'select(.event != "session_start")'
# react to "added" / "deleted" / "edited" events; "exit" marks end of session
```

**Pull** — ignore stdout, just read the sidecar after the user exits:

```bash
human-review notes.md      # foreground; or background and wait $!
jq '.comments' notes.md.comments.json
```

The sidecar is always authoritative; the stream is just a notification channel.

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
