# human-review

Native macOS app for local, GitHub-style review of markdown and code
files. Built for **humans (GUI)** and **agents (pure shell)** at the same
time — every interaction is a `human-review <subcommand>` call, and a
running GUI auto-reloads whenever an external process changes the
sidecar files.

- Per-block comments in `.md` files (with syntax-highlighted code fences,
  mermaid diagrams, and cross-file link previews).
- Per-line comments in `.py` / `.txt` / `.js` / `.go` / `.rs` / … — hljs
  syntax highlighting, GitHub-style gutter, click a line number to start
  a thread on that line.
- Threaded replies, resolve/reopen, orphaned-thread tracking, read
  receipts (✓✓), whole-document (sidebar) chat threads.
- `⌘F` search across code + comments + author names, floating zoom
  widget, macOS dictation via `Fn`-`Fn`, composer drafts that survive
  agent posts.
- No web server, no daemon, no login, no network calls at runtime. The
  sidecar files are your source of truth.

<sub>Screenshots pending. See [`HANDOFF.md`](HANDOFF.md) for architectural
notes and load-bearing invariants.</sub>

## Install

**Requirements:** macOS 13+ and Swift 5.9+ (ships with Xcode Command Line
Tools — `xcode-select --install` if you don't have them).

```bash
git clone https://github.com/nvgoldin/human-review.git ~/src/human-review
cd ~/src/human-review
./install.sh
```

`install.sh` builds release, assembles a `.app` bundle at
`~/Applications/human-review.app`, ad-hoc code-signs it (needed so macOS
attributes microphone/dictation permission to it), and symlinks
`~/bin/human-review` at the in-bundle binary. Make sure `~/bin` is on
your `PATH`:

```bash
export PATH="$HOME/bin:$PATH"       # add to your ~/.zshrc or ~/.bashrc
```

Then:

```bash
human-review notes.md              # or foo.py, bar.txt, README.md, …
```

**Customizing the bundle identifier.** The default is
`io.github.nvgoldin.human-review`. Override with an env var:

```bash
BUNDLE_ID=dev.you.human-review ./install.sh
```

(TCC — the permission gate for mic/dictation — keys on this identifier,
so keep it stable once you've granted permission.)

## What it looks like

You launch it against any file:

```bash
human-review path/to/notes.md
human-review path/to/module.py
human-review a.md b.md c.md            # multi-file session; ⌘] / ⌘[ to switch
```

The window has three panes: the doc/code on the left, per-block or
per-line threads inline, and a global-chat sidebar on the right for
whole-document conversations.

Every change writes to three sidecars next to your source file:

```
notes.md                     source (untouched)
notes.md.comments.json       canonical state — atomically rewritten on each mutation
notes.md.events.jsonl        append-only log — tail this for live updates
notes.review.md              human-readable copy with > [!review] callouts
```

## Keyboard

| Shortcut | Action |
|---|---|
| `↑` / `↓` (`k` / `j`) | Move focus between blocks or lines |
| `Enter` | Open composer — replies to active thread if any, else new |
| `n` / `N` | Jump to next / previous active thread (wraps) |
| `Tab` or `⌘Enter` | Submit composer |
| `Esc` | Cancel composer |
| `⌘F` | In-doc search (code, comments, authors) |
| `⌘+` / `⌘-` / `⌘0` | Zoom in / out / reset |
| `⌘]` / `⌘[` | Next / previous file |
| `⌘R` | Reload source from disk with re-anchor |
| `⌘W` | Close window (fires `exit` event) |
| `Fn Fn` | Start macOS dictation into the focused composer |

## Agent CLI

Everything the GUI does is available as shell subcommands. Full surface
is `human-review --help`.

### Mutate

```
human-review add     FILE --line N       --body "TEXT" [--author NAME]
human-review add     FILE --reply-to UUID --body "TEXT" [--author NAME]
human-review add     FILE --global       --body "TEXT"                # whole-doc chat
human-review resolve FILE --id UUID
human-review reopen  FILE --id UUID
human-review delete  FILE --id UUID                                   # root deletes the thread
human-review reload  FILE                                             # re-anchor after edits
human-review attention FILE --id UUID                                 # pulse the GUI's focus
```

Each command prints the resulting record as JSON and appends one line to
the events log.

### Read

```
human-review list    FILE                       # all comments (JSON array)
human-review threads FILE [--active|--settled]  # thread roots + reply counts
human-review get     FILE --id UUID             # one comment
```

### Subscribe

```
human-review watch FILE [FILE2 ...]             # tail events.jsonl; blocks
  [--from-start]                                # replay from beginning
  [--types added,resolved,…]                    # filter event types
```

### Block-and-wait

Exit 0 on match (printing the matching event JSON), exit 124 on timeout.

```
human-review wait FILE --reply-to UUID [--from-author NAME] [--timeout S]
human-review wait FILE --resolve   UUID                     [--timeout S]
human-review wait FILE --exit                               [--timeout S]
```

## Full agent flow (pure shell)

```bash
# 1. Show a GUI to the human
human-review notes.md &

# 2. Post an inline review note, capture the thread root id
ROOT=$(human-review add notes.md --line 42 \
         --body "verify the claim about X" | jq -r '.id')

# 3. Block until the human replies (up to 10 minutes)
REPLY=$(human-review wait notes.md --reply-to "$ROOT" --timeout 600)
echo "human said: $(echo "$REPLY" | jq -r '.comment.body')"

# 4. Follow up, then resolve
human-review add notes.md --reply-to "$ROOT" --body "thanks, addressed."
human-review resolve notes.md --id "$ROOT"
```

That's the whole loop. There is no client library, no long-lived
subprocess, no protocol beyond `--help`. The LLM invokes these
commands via its `Bash` tool the same way it invokes `git` or `jq`.

## Comment record

```jsonc
{
  "id":         "UUID",
  "replyTo":    "UUID" | null,     // null = thread root
  "scope":      "block" | "global",
  "anchorLine": 42,                // 0-indexed; meaningful only for scope=block
  "anchorText": "first 80 chars of the anchored block",
  "body":       "…",               // rendered as GFM markdown in the GUI
  "author":     "you" | "agent" | …,
  "createdAt":  "ISO8601",
  "resolved":   false,             // only meaningful on the root
  "orphaned":   false,             // true if reload couldn't relocate anchorText
  "readBy":     ["agent", …]       // ack list (✓✓)
}
```

## Events

All state changes append to `FILE.events.jsonl`. Sample types: `added`,
`edited`, `deleted`, `resolved`, `reopened`, `read`, `reloaded`,
`gui_opened`, `gui_closed`, `attention`, `exit`. JSON keys are
alphabetically sorted (stable across releases).

## Bundled resources

No runtime network. Ships with:

- [`marked`](https://github.com/markedjs/marked) — markdown → HTML
- [`highlight.js`](https://github.com/highlightjs/highlight.js) — syntax
  highlighting (common language pack, ~35 languages)
- [`mermaid`](https://github.com/mermaid-js/mermaid) — diagrams from
  ` ```mermaid ` fenced blocks

## Development

```bash
swift build                          # debug
swift build -c release               # release (what install.sh calls)
./install.sh                         # rebuild + repackage + re-sign the .app
```

The whole GUI is `Sources/human-review/Resources/viewer.html` — you can
iterate on the JS/CSS without touching Swift and see changes immediately
after `./install.sh` (or `swift build -c release`) and a window reopen.

Deep architectural notes and the "how did we end up here" bug log live
in [`HANDOFF.md`](HANDOFF.md).

## Limitations

- macOS only (no Linux / Windows port).
- `events.jsonl` grows forever. Run `human-review prune FILE` if it
  becomes large.
- Re-anchoring after external edits is best-effort: roots keep the
  first 80 chars of the block as `anchorText` and re-search on `⌘R` /
  `reload`. Unmatched roots get `orphaned: true` and render in a
  separate section.

## License

MIT
