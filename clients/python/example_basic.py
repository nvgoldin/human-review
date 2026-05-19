#!/usr/bin/env python3
"""Minimal end-to-end agent example.

Spawns human-review on a single file, posts an inline comment, waits for the
human to reply, posts a follow-up, and resolves the thread.

    python example_basic.py path/to/notes.md
"""
from __future__ import annotations

import sys
from pathlib import Path

# Make `import human_review` work when run from this directory.
sys.path.insert(0, str(Path(__file__).parent))
from human_review import HumanReview


def main(file: str) -> None:
    with HumanReview([file]) as hr:
        # 1) Verify the GUI is alive.
        assert hr.ping(), "human-review didn't respond to ping"

        # 2) Post a review comment anchored to line 1 of the file.
        print("→ posting initial review comment")
        root = hr.add(file=file, line=1,
                      body="agent: please verify the intro paragraph")
        assert root, "add() returned nothing"
        print(f"   posted as id={root['id']}")

        # 3) Wait for the human to reply (up to 5 minutes).
        print("→ waiting up to 5 minutes for a human reply…")
        reply = hr.wait_for_reply(root["id"], timeout=300)
        if reply is None:
            print("   timed out — no reply within 5 minutes")
            return
        print(f"   got reply from {reply['author']}: {reply['body']!r}")

        # 4) Post a follow-up.
        print("→ posting a follow-up")
        hr.add(file=file, reply_to=root["id"],
               body="thanks — closing this out.", wait=False)

        # 5) Resolve the thread.
        print("→ resolving the thread")
        hr.resolve(file=file, root_id=root["id"])

        # 6) Optionally: wait for the user to close the window.
        print("→ waiting for window close (or 60s timeout)")
        exit_ev = hr.wait_for_exit(timeout=60)
        if exit_ev:
            total = sum(len(f.get("comments", [])) for f in exit_ev.get("files", []))
            print(f"   GUI exited cleanly · {total} comment(s) in final state")
        else:
            print("   timed out waiting for exit — closing GUI from our side")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: python example_basic.py FILE.md", file=sys.stderr)
        sys.exit(2)
    main(sys.argv[1])
