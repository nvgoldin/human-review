"""human_review — Python client for the human-review duplex JSONL protocol.

Quick start:

    from human_review import HumanReview

    with HumanReview(["notes.md"]) as hr:
        root = hr.add(file="notes.md", line=42,
                      body="please verify the claim about X")
        reply = hr.wait_for_reply(root["id"], timeout=600)
        if reply:
            print("human said:", reply["body"])
        hr.resolve(file="notes.md", root_id=root["id"])

Drop this single file alongside your agent script (or `pip install` the repo
in editable mode — but a single-file copy is the intended path).

Requires: Python 3.9+. No third-party deps.
"""
from __future__ import annotations

import json
import subprocess
import threading
import time
from typing import Any, Callable, Iterator, Optional


Comment = dict   # {id, replyTo|None, anchorLine, anchorText, body, author, createdAt, resolved, orphaned}
Event = dict     # {event, timestamp, file?, comment?, files?, reanchor?}


class HumanReview:
    """Long-running handle on a `human-review` subprocess.

    Use as a context manager so the GUI exits cleanly when your agent finishes:

        with HumanReview(["a.md", "b.md"]) as hr:
            ...
    """

    def __init__(
        self,
        files: list[str],
        *,
        author: str = "agent",
        binary: str = "human-review",
        extra_args: Optional[list[str]] = None,
    ):
        args = [binary, *files]
        if extra_args:
            args.extend(extra_args)
        self.author = author
        self._proc = subprocess.Popen(
            args,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        # All events ever seen, in arrival order. Multiple consumers track their
        # own read position. Append + notify under self._cv.
        self._events: list[Event] = []
        self._cv = threading.Condition()
        self._exited = False
        self._reader = threading.Thread(target=self._read_loop, daemon=True)
        self._reader.start()

    # ─── lifecycle ──────────────────────────────────────────────────────────

    def __enter__(self) -> "HumanReview":
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    def close(self) -> None:
        """Signal the GUI to exit by closing stdin. Waits for process to end."""
        if self._proc.stdin and not self._proc.stdin.closed:
            try:
                self._proc.stdin.close()
            except BrokenPipeError:
                pass
        # If stdin close doesn't trigger exit on its own, terminate gracefully.
        try:
            self._proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self._proc.terminate()
            try:
                self._proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self._proc.kill()

    @property
    def returncode(self) -> Optional[int]:
        return self._proc.returncode

    # ─── reader thread ──────────────────────────────────────────────────────

    def _read_loop(self) -> None:
        assert self._proc.stdout is not None
        for line in self._proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            with self._cv:
                self._events.append(ev)
                if ev.get("event") == "exit":
                    self._exited = True
                self._cv.notify_all()
        with self._cv:
            self._exited = True
            self._cv.notify_all()

    # ─── sending commands ───────────────────────────────────────────────────

    def _send(self, cmd: dict) -> None:
        if self._exited or self._proc.stdin is None or self._proc.stdin.closed:
            raise RuntimeError("human-review has exited or stdin is closed")
        self._proc.stdin.write(json.dumps(cmd) + "\n")
        self._proc.stdin.flush()

    def add(
        self,
        *,
        file: str,
        body: str,
        line: Optional[int] = None,
        reply_to: Optional[str] = None,
        author: Optional[str] = None,
        wait: bool = True,
        timeout: float = 5.0,
    ) -> Optional[Comment]:
        """Post a comment.

        Either `line` (1-indexed) for a new thread root, OR `reply_to` (UUID
        of any comment in an existing thread) for a reply. Replying to a
        settled thread auto-reopens it.

        When wait=True (default), blocks until the matching `added` event is
        seen and returns the new comment record. Set wait=False if you don't
        need the round-trip (fire and forget).
        """
        cmd: dict[str, Any] = {
            "cmd": "add",
            "file": file,
            "body": body,
            "author": author or self.author,
        }
        if reply_to is not None:
            cmd["replyTo"] = reply_to
        elif line is not None:
            cmd["line"] = line
        else:
            raise ValueError("HumanReview.add requires either `line` or `reply_to`")

        start_pos = len(self._events)
        self._send(cmd)
        if not wait:
            return None

        ev = self._wait_for(
            lambda e: (
                e.get("event") == "added"
                and e.get("file") == file
                and (e.get("comment") or {}).get("body") == body
            ),
            since=start_pos,
            timeout=timeout,
        )
        return (ev or {}).get("comment")

    def reply(self, *, file: str, reply_to: str, body: str, **kw) -> Optional[Comment]:
        """Convenience alias for add(..., reply_to=...)."""
        return self.add(file=file, reply_to=reply_to, body=body, **kw)

    def resolve(self, *, file: str, root_id: str) -> None:
        """Settle the thread containing root_id (accepts any descendant id too)."""
        self._send({"cmd": "resolve", "file": file, "id": root_id})

    def reopen(self, *, file: str, root_id: str) -> None:
        self._send({"cmd": "reopen", "file": file, "id": root_id})

    def delete(self, *, file: str, comment_id: str) -> None:
        """Delete a single comment. Deleting a thread root removes the whole thread."""
        self._send({"cmd": "delete", "file": file, "id": comment_id})

    def reload(self, *, file: str) -> None:
        """Re-read source from disk and re-anchor comments by anchorText."""
        self._send({"cmd": "reload", "file": file})

    def open_file(self, *, file: str) -> None:
        """Append a new file to the running session (no GUI restart)."""
        self._send({"cmd": "open", "file": file})

    def focus(self, *, file: str) -> None:
        """Switch the GUI to show this file."""
        self._send({"cmd": "focus", "file": file})

    def ping(self, *, timeout: float = 2.0) -> bool:
        """Round-trip liveness check. Returns True if a pong came back in time."""
        start = len(self._events)
        self._send({"cmd": "ping"})
        return self._wait_for(
            lambda e: e.get("event") == "pong",
            since=start, timeout=timeout
        ) is not None

    # ─── reading events ─────────────────────────────────────────────────────

    def events(
        self, *, since: int = 0, timeout: Optional[float] = None
    ) -> Iterator[Event]:
        """Yield events as they arrive (or replay from `since`).

        Each call gives you an independent cursor — multiple consumers do not
        interfere. The iterator returns when the GUI exits or `timeout` elapses
        with no new event.
        """
        pos = since
        deadline = (time.monotonic() + timeout) if timeout is not None else None
        while True:
            with self._cv:
                while pos >= len(self._events):
                    if self._exited:
                        return
                    remaining = (deadline - time.monotonic()) if deadline else None
                    if remaining is not None and remaining <= 0:
                        return
                    self._cv.wait(timeout=remaining)
                    if pos >= len(self._events) and self._exited:
                        return
                ev = self._events[pos]
                pos += 1
            yield ev

    def wait_for_reply(
        self,
        thread_root: str,
        *,
        from_author: Optional[str] = None,
        timeout: Optional[float] = None,
    ) -> Optional[Comment]:
        """Block until a reply lands in the thread rooted at `thread_root`.

        By default, returns the first reply NOT authored by `self.author`
        (i.e., a real human/other-party response). Pass `from_author="*"` to
        accept any author including your own.
        """
        # Build the set of ids that belong to this thread, including any past
        # replies we've already seen.
        with self._cv:
            ids_in_thread = self._descendants_of(thread_root, self._events)
            start = len(self._events)

        for ev in self.events(since=start, timeout=timeout):
            if ev.get("event") != "added":
                continue
            c = ev.get("comment") or {}
            parent = c.get("replyTo")
            if parent not in ids_in_thread and c.get("id") != thread_root:
                continue
            ids_in_thread.add(c.get("id"))
            if from_author == "*" or c.get("author") != self.author:
                if from_author and from_author != "*" and c.get("author") != from_author:
                    continue
                return c
        return None

    def wait_for_resolve(
        self, thread_root: str, *, timeout: Optional[float] = None
    ) -> bool:
        """Block until the thread is resolved. Returns True on resolve, False on timeout/exit."""
        start = len(self._events)
        for ev in self.events(since=start, timeout=timeout):
            if ev.get("event") == "resolved" and (ev.get("comment") or {}).get("id") == thread_root:
                return True
        return False

    def wait_for_exit(self, *, timeout: Optional[float] = None) -> Optional[Event]:
        """Block until the GUI emits its final `exit` event."""
        start = 0  # always replay from start so a past exit is still found
        for ev in self.events(since=start, timeout=timeout):
            if ev.get("event") == "exit":
                return ev
        return None

    # ─── snapshots ──────────────────────────────────────────────────────────

    def comments(self, file: str) -> list[Comment]:
        """Current known comments for a file, derived from the event log."""
        with self._cv:
            evs = list(self._events)
        cur: dict[str, Comment] = {}
        for ev in evs:
            t = ev.get("event")
            if t in ("session_start", "exit"):
                for f in (ev.get("files") or []):
                    if f.get("file") == file:
                        cur = {c["id"]: c for c in (f.get("comments") or [])}
            elif t == "added" and ev.get("file") == file:
                c = ev.get("comment") or {}
                cur[c["id"]] = c
            elif t == "edited" and ev.get("file") == file:
                c = ev.get("comment") or {}
                cur[c["id"]] = c
            elif t == "deleted" and ev.get("file") == file:
                c = ev.get("comment") or {}
                cur.pop(c.get("id"), None)
            elif t in ("resolved", "reopened") and ev.get("file") == file:
                c = ev.get("comment") or {}
                if c.get("id") in cur:
                    cur[c["id"]]["resolved"] = (t == "resolved")
        return list(cur.values())

    def active_threads(self, file: str) -> list[Comment]:
        return [c for c in self.comments(file)
                if c.get("replyTo") is None and not c.get("resolved")]

    # ─── helpers ────────────────────────────────────────────────────────────

    def _wait_for(
        self,
        pred: Callable[[Event], bool],
        *,
        since: int = 0,
        timeout: float = 5.0,
    ) -> Optional[Event]:
        deadline = time.monotonic() + timeout
        for ev in self.events(since=since, timeout=timeout):
            if pred(ev):
                return ev
            if time.monotonic() > deadline:
                return None
        return None

    @staticmethod
    def _descendants_of(root_id: str, events: list[Event]) -> set[str]:
        """Walk events to find every comment id in the thread rooted at root_id."""
        ids: set[str] = {root_id}
        # Multi-pass to catch out-of-order events (rare but cheap).
        changed = True
        while changed:
            changed = False
            for ev in events:
                if ev.get("event") in ("added", "edited"):
                    c = ev.get("comment") or {}
                    if c.get("replyTo") in ids and c.get("id") not in ids:
                        ids.add(c["id"])
                        changed = True
                elif ev.get("event") in ("session_start", "exit"):
                    for f in (ev.get("files") or []):
                        for c in (f.get("comments") or []):
                            if c.get("id") == root_id or c.get("replyTo") in ids:
                                ids.add(c["id"])
        return ids


if __name__ == "__main__":
    # Run as `python human_review.py` for a one-shot smoke test against a
    # fixture you provide on the command line.
    import sys
    if len(sys.argv) < 2:
        print("usage: python human_review.py FILE.md [FILE2.md ...]", file=sys.stderr)
        sys.exit(2)
    with HumanReview(sys.argv[1:]) as hr:
        print("started session.", "ping →", hr.ping())
        root = hr.add(file=sys.argv[1], line=1,
                      body="smoke-test comment from human_review.py")
        print("posted root:", root["id"] if root else None)
        print("waiting up to 30s for a reply…")
        reply = hr.wait_for_reply(root["id"], timeout=30) if root else None
        print("reply:", reply["body"] if reply else "(none)")
