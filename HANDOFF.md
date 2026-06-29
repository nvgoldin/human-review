# human-review · HANDOFF

Snapshot for picking the project up in a fresh session. Last updated end-of-session 2026-05-28.

## TL;DR for a new agent

You're working on **`human-review`**, a native macOS app at `~/src/human-review/` that lets a human review local markdown files with a GitHub-style threaded review UI. It is also designed to be **driven by agents over the shell**: every interaction is a `human-review <subcommand>` call, every state change appends one JSONL line to `<file>.md.events.jsonl`, and a long-lived `human-review watch FILE` subscription auto-acks comments as the watcher reads them.

```bash
human-review --help          # full protocol surface, single source of truth
human-review file.md         # GUI mode
human-review watch file.md   # live JSONL on stdout, auto-acks every event seen
```

The repo is **local-only** (`git remote -v` is empty). **Never push to a remote without explicit user permission.** `./install.sh` builds a release binary, assembles a `.app` bundle at `~/Applications/human-review.app`, ad-hoc-signs it with a stable identifier, and points `~/bin/human-review` at the in-bundle executable. Always re-run `./install.sh` to ship a change.

## Repo layout

```
~/src/human-review/
├── Package.swift                                — SwiftPM, single executable target
├── README.md                                    — user-facing docs (shell-first)
├── HANDOFF.md                                   — this file
├── install.sh                                   — build + .app bundle + ad-hoc codesign + ~/bin symlink
├── bundle/
│   └── Info.plist                               — template baked into the .app on every install
├── Sources/human-review/
│   ├── main.swift                               — ~2200 lines: model, store, session, CLI, stdin protocol, AppDelegate
│   └── Resources/
│       ├── viewer.html                          — ~2000 lines: HTML/CSS + render JS + bridge
│       ├── marked.min.js                        — bundled (40KB) markdown → HTML
│       └── mermaid.min.js                       — bundled (3.2MB) mermaid diagram rendering
└── .build/release/human-review                  — raw build product, copied into the .app by install.sh
```

The shipped .app lives outside the repo:

```
~/Applications/human-review.app/
└── Contents/
    ├── Info.plist                               — CFBundleIdentifier dev.nadav.human-review,
    │                                              NSMicrophoneUsageDescription, NSSpeechRecognitionUsageDescription
    ├── MacOS/human-review                       — the executable
    └── Resources/
        └── human-review_human-review.bundle/    — SwiftPM resources (viewer.html etc.)
                                                  AppResources helper in main.swift prefers this path;
                                                  Bundle.module's default would land them at .app root,
                                                  which codesign rejects ("unsealed contents at bundle root").
```

## Per-file artifacts (the agent's universe)

For each `FILE.md` the tool maintains four artifacts:

| File | Purpose |
|---|---|
| `FILE.md` | source (read-only to human-review) |
| `FILE.md.comments.json` | canonical state — atomic writes on every mutation |
| `FILE.md.events.jsonl` | append-only event log — `tail -F` or `human-review watch` to subscribe |
| `FILE.review.md` | human-readable inline-annotated copy with `> [!review]` callouts |

The GUI polls `comments.json` every 0.5s via SHA hash compare → auto-reloads on external mutation. Agents can therefore mutate state by running `human-review add/resolve/...` from any shell and the running GUI updates live.

## Architectural choices to know

**Thread model.** Every comment is the same shape. Threads form via `replyTo: UUID?` (null = root). A thread has `resolved: bool` on the root. Replying to a settled thread auto-reopens. There is no separate "flag" type — agents and humans post identically. The user's "scope" field separates **block-anchored** inline comments from **whole-document** sidebar chat (more below).

**Comment record** (also the shape in events, sidecar JSON, and `human-review list` output):

```jsonc
{
  "id":         "UUID",
  "replyTo":    "UUID" | null,    // null = thread root
  "scope":      "block" | "global",
  "anchorLine": 42,               // 0-indexed; meaningful only for scope=block
  "anchorText": "first 80 chars of the anchored block",
  "body":       "…",              // markdown — rendered with marked (GFM + soft breaks)
  "author":     "agent" | "Nadav Goldin" | …,
  "createdAt":  "ISO8601",
  "resolved":   false,            // only meaningful on the root
  "orphaned":   false,            // reload couldn't relocate anchorText
  "readBy":     ["agent", …]      // explicit ack list — WhatsApp-style ✓✓
}
```

**Event types** (every line in events.jsonl + every line on `human-review watch`):
`session_start`, `gui_opened`, `gui_closed`, `added`, `edited`, `deleted`, `resolved`, `reopened`, `read`, `reloaded`, `opened`, `focused`, `attention`, `pong`, `command_error`, `exit`. All JSON output is **alphabetically sorted-keys** (canonical, stable across versions).

**Two encoding paths into the log:** `JSONEncoder` on a `StreamEvent` struct (most events) and `JSONSerialization` on a `[String: Any]` dict (command_error). Both now use `.sortedKeys`.

**Auto-ack semantics.** Read receipts are explicit ack lists (`readBy: [String]`). The default behavior:

| Action | Auto-acks? |
|---|---|
| `human-review get`, `wait --reply-to`, `wait --resolve` | yes, under `--author` (default `"agent"`) |
| `human-review watch` | yes — *the watcher = the reader* |
| `human-review list`, `watch` with `--no-ack` | no (opt-out) |
| GUI navigation to a file with unread `scope: "global"` | yes, under `NSFullUserName()` |
| GUI rendering a regular comment | no (no implicit reads on human-side render) |

UI shows ✓ (delivered) at the bottom-right of every comment, transitioning smoothly to ✓✓ when any non-self author has acked.

**The right-side "Document chat" sidebar** renders `scope: "global"` threads. CSS Grid (`auto 1fr auto`) for header/scroll/composer. Single pinned composer at the bottom that flips between "new global thread" mode and "reply to thread X" mode when you click a sidebar thread. Auto-scrolls to the latest message if the user was near the bottom.

**Chevron unread badges.** `⌘[` and `⌘]` show a small red badge (caps at "9+") for the count of `scope: "global"` comments in the neighbor file that are unread by `NSFullUserName()`. When the user navigates to that file, `autoAckCurrentGlobals()` runs and the badge resets.

**Attention.** Auto-jump-to-first-active-thread on file open was **removed** in `39fbe35`. Agents can now explicitly request focus:

```bash
ID=$(human-review add file.md --line 42 --body "look here" | jq -r '.id')
human-review attention file.md --id "$ID"   # → GUI scrolls + pulses
```

Implementation: `pendingAttention: UUID?` field on `CommentFile` (the sidecar). GUI's `applyState` honors it once, calls `clearAttention` on Swift to wipe the field.

**Cross-link overlay.** Standard markdown links to local absolute paths (`/path/to/other.md#section-slug`) open as a modal overlay showing just the linked section (heading match via auto-slug, falls back to substring). Backdrop / Esc / ✕ to close. "Open in review" button opens the linked file in the running session via `openInSession` bridge message.

**Mermaid + diagram zoom overlay.** ```` ```mermaid ```` fenced blocks render as SVG via `mermaid.run({nodes})` (NOT `mermaid.render(id, src)` — that had a race condition where async work clobbered the DOM during the GUI's auto-reload). Clicking a diagram opens an overlay with a toolbar (−/＋/Fit/100%, current % live), 20%-2000% zoom range, drag-to-pan, wheel/pinch zoom, double-click to reset.

**Sidebar scroll (load-bearing — easy to break).** Three things together make the right-side `Document chat` sidebar scroll independently of the document; removing any one of them silently re-breaks it:

1. `html, body { height: 100vh; overflow: hidden }`. The doc scroll lives inside `#content` (`height: 100vh; overflow-y: auto`) — NOT on `body`. If the body scrolls, *both* scrollbars stack at the right edge of the viewport (same x-coord as the sidebar's), and the body's wins all wheel events. The two `window.scrollY` calls in `render()` read/write `container.scrollTop` because of this.
2. `#chat-sidebar` is `display: flex; flex-direction: column`, with `#sidebar-threads { flex: 1 1 0; min-height: 0 }`. `min-height: 0` is required — flex items default to `min-height: auto` and refuse to shrink below their content size, so without it the threads region grows to fit and never overflows. Earlier attempts using `display: grid; grid-template-rows: auto minmax(0, 1fr) auto` worked on paper but WKWebView didn't actually bound the middle track. Flex with explicit `min-height: 0` is the textbook fix and it sticks.
3. `#sidebar-threads .thread { flex-shrink: 0 }`. `.sidebar-scroll` is itself `display: flex; flex-direction: column` (so threads stack with a `gap`). Without `flex-shrink: 0` on each card, the flex algorithm proportionally squashes all N threads to fit the container instead of letting them overflow — so the threads render as 5-px-tall bars, no scrollbar appears, and it looks completely broken.

The sidebar scrollbar is also styled to be always-visible (`::-webkit-scrollbar` rules) so it's obvious which region scrolls.

**Whole-window zoom.** `⌘+ / ⌘- / ⌘0` + trackpad pinch — `WKWebView.pageZoom` on `ReviewSession.pageZoom`, persists across file navigation. `⌘+` requires explicit `[.command, .shift]` modifier mask on the menu item (the keyEquivalent `"+"` is `Shift+=` on US layouts and won't fire without it). There's also a hidden `⌘=` alternate for users who don't realize Shift is required. A floating `−` / `%` / `+` widget at the bottom-left of the window mirrors the menu actions and shows the current percentage. The widget's button clicks send `zoomIn` / `zoomOut` / `zoomReset` messages via the JS bridge; the handler writes `webView.pageZoom` directly (Swift's `@ObservedObject session` chain isn't reliable enough to trigger `updateNSView` when only `pageZoom` mutates in place) and pushes a fresh `applyState` so the % indicator updates immediately.

**In-document search (`⌘F`).** Floating bar at top-center: input + `1/N` count + ↑ / ↓ / ✕. Walks text nodes inside `#content` and `#sidebar-threads`, wraps matches in `<mark class="search-hit">` (current match also gets `.current`). Auto-expands settled/collapsed threads when a match is inside. Skips composer textareas so a live search doesn't corrupt drafts. `Enter` / `Shift+Enter` step, `Esc` closes. Survives external sidecar reloads — `applyState` re-runs the active query and preserves the current index. The composer-draft system (see below) and search both rely on stable `data-composer-key` / `mark.search-hit` selectors — don't rename without updating both code paths.

**Composer drafts.** Every composer (new-thread / reply / sidebar) gets a stable `data-composer-key` (`new:<line>`, `reply:<root>`, `sidebar`). `snapshotComposers()` runs at the top of `render()` and captures `{value, selStart, selEnd}` + which composer had focus; `restoreComposers()` writes them back after `replaceChildren()`. Drafts cleared on submit-new / submit-reply / submit-global / cancel / Esc. Without this, an external sidecar reload (agent posts a comment while you're typing) would wipe the textarea and steal focus. `autofocus` is intentionally NOT on composer textareas — it re-fires on every re-insertion and competes with the snapshot/restore flow.

**Dictation.** macOS system dictation (Fn-Fn, the Edit ▸ Start Dictation… menu item, or the 🎤 button in any composer) inserts speech-to-text into the focused composer textarea. Three requirements made this work:

  1. The app must be a real `.app` bundle with a stable `CFBundleIdentifier` — TCC (microphone, speech recognition) refuses to attribute permissions to a raw SwiftPM executable launched from the terminal. `install.sh` handles this.
  2. `Info.plist` must include `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription` — without them, macOS exits silently when dictation tries to start. They live in `bundle/Info.plist`.
  3. The `.app` must be ad-hoc-signed with a stable identifier (`codesign --sign - --identifier dev.nadav.human-review --force`). Without `--identifier`, every rebuild changes the signature hash and TCC sometimes re-prompts; with it, the grant sticks. `--deep` is intentionally omitted — codesign tries to recursively sign the SwiftPM resource `.bundle/` (which has no Mach-O / Info.plist) and fails with "bundle format unrecognized."

  The JS side just calls `postSwift({type: 'startDictation'})`; the Swift handler dispatches `Selector(("startDictation:"))` to `nil` so it walks the responder chain and lands on the focused WKWebView textarea. The Edit menu item uses the same selector with an empty `keyEquivalent` — macOS auto-renders the user's configured Fn-Fn shortcut from System Settings.

**`writeInlineExport` invariant.** The `.review.md` rebuild only inlines `scope == .block` comments whose `anchorLine` is in `[0, lines.count)`. Globals + orphans + stale-anchor blocks render in a separate "Document discussion" section at the bottom of `.review.md`. Earlier `start..<lines.count` traps on a stale anchor were fixed by guarding `start` and using a closed range bounded by `lastValidLine` (commit `ac16def`).

## Recent commits (newest first)

```
1928f40  Sidebar: grid layout for reliable scroll + auto-scroll to latest; remove post-submit focus jump
39fbe35  Sidebar UX: scroll fix + single bottom composer with reply mode; remove auto-jump in favor of explicit attention
6080c22  Diagram overlay: toolbar + drag-to-pan, max 2000% zoom
cba051b  Mermaid: fix first-render race + click-to-zoom overlay
6bbd96a  Zoom: ⌘+ / ⌘- / ⌘0 menu + trackpad pinch
a2d5297  Canonical sorted-keys output for all event JSONL emissions
d298d26  Mermaid: suppress + sweep stray 'Syntax error in text' bombs from body
e014369  Add mermaid.min.js to repo (bundled resource)
effef74  Mermaid rendering + n-key regression fix
ac16def  Fix writeInlineExport Range trap; render globals + stale anchors in Document discussion
6038e2b  Global (whole-doc) chat sidebar + cross-link overlay
223c74f  Read receipts (✓✓) + markdown rendering in comment bodies
…
6d43407  Initial commit: human-review macOS app
```

Run `git log --oneline | head -25` from the repo for the full chain.

## Open / not-yet-built items

The user mentioned wanting these and we've **designed but not implemented**:

### Inline text-range comments (designed, not built)

Select a span of text inside a block, hit a floating "+" button, comment lands anchored to that precise text range (not just the surrounding block). Designed in mid-session but tabled. Plan:

- New optional `anchorRange: { selected, offset, length }` on `Comment`. Nil for current comments.
- Selection-based: listen for `selectionchange`, show floating "Comment" button near the selected text, on click open composer; submit posts with `anchorRange` populated.
- Render: when a comment has `anchorRange.selected`, wrap the matching substring in `<mark class="comment-anchor" data-comment-id="…">…</mark>` in the rendered HTML. Hover shows first line of comment.
- Re-anchor: search `anchorRange.selected` substring in the new block source after reload; fall back to whole-block if not found.

Estimated: ~80 lines JS, ~30 lines Swift.

### Other things to watch for

- **Sidebar scroll** was fixed twice (`min-height: 0` then full switch to grid in `1928f40`). If a future regression appears, check `display` mode on `#chat-sidebar`.
- **`n`-key regression** was fixed in `effef74` by scoping the post-render auto-focus to only the explicitly-opened composer. If `n` ever stops working again, suspect a new auto-focus path.
- **Mermaid first-render** is fragile — keep using `mermaid.run({nodes})` with the data-processed idempotency marker. Per-block `mermaid.render(id, src)` will race the GUI's sidecar auto-reload.
- **Stray mermaid error bombs** (the "Syntax error in text" SVG pinned to body) — covered by `suppressErrorRendering: true` + a `cleanupMermaidStrays()` sweep, but new mermaid versions sometimes change the element shape. If new stray DOM appears, extend the selector list in `cleanupMermaidStrays`.

## How to resume

```bash
cd ~/src/human-review
git log --oneline | head -15           # recent commits
git status                              # working tree

# Rebuild + reinstall (idempotent)
./install.sh

# Try it
human-review /path/to/some.md

# Or test the agent surface
human-review --help
human-review add /tmp/foo.md --line 1 --body "hi" --global
human-review watch /tmp/foo.md         # leave running; auto-acks
human-review attention /tmp/foo.md --id <uuid>
```

## Conventions to keep

- **Greenfield migrations.** The user said "we're in greenfield, break whatever you want" early on. Don't add backwards-compat shims unless explicitly requested.
- **No Python client.** Earlier we had one at `clients/python/`; it was deleted in `8038196` in favor of pure shell. Don't re-add unless asked.
- **No remote on the repo.** Local-only. Don't push.
- **`.review.md` invariants.** Only inline-eligible block comments (scope=block, anchor in-bounds, non-orphan) get inserted inline. Everything else goes in the "Document discussion" section at the end.
- **Output formatting.** All event JSON uses `.sortedKeys`. Don't add new emit paths that bypass this.
- **CLI default author = "agent"** (matches stdin protocol). Headless `add` without `--author` lands as `agent`.
- **Single source of truth for the protocol = `--help`.** Whenever you add a CLI flag, stdin command, or event type, update `--help` in the same commit.

## Mental model for new contributors

The same `human-review` binary serves four modes:

1. **GUI window** — `human-review FILE.md [FILE2.md ...]` launches the SwiftUI window. AppDelegate owns the `ReviewSession`, which owns per-file `ReviewStore`s, which own a `WKWebView` each (rebuilt per-file via `.id(currentIndex)`).
2. **Headless mutation** — `human-review add/resolve/reopen/delete/reload/ack/attention` create a transient `ReviewStore` (no polling, no streaming), mutate, persist, exit. The running GUI (if any) picks up the change via sidecar polling.
3. **Headless read** — `human-review list/threads/get` — same transient store, just print and exit.
4. **Live subscription** — `human-review watch FILE [...]` shells out to `tail -F` over each file's `.events.jsonl`, applies a sorted-keys-aware grep filter, and **auto-acks every `added` event seen** (the watcher IS the reader). `human-review wait FILE --reply-to UUID` is a one-shot block-until-predicate variant.

The duplex stdin/stdout protocol exists for cases when the agent owns the GUI subprocess. Most of the time, the **shell-native flow is preferred**: `human-review add → wait → resolve`.
