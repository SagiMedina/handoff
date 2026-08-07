#!/usr/bin/env python3
"""
Stream Handoff notification events over a paired device's gate channel.

Invoked by `handoff gate <fp>` when SSH_ORIGINAL_COMMAND starts with
`subscribe`. The phone consumes one NDJSON record per line on stdout:
queued events first (id > since, matching device session patterns), then a
live tail of the events log. Heartbeats keep half-open TCP detectable.

This script speaks only stdout — never use print() for diagnostics; the phone
is parsing every line.

Args (positional):
    1: device fingerprint (informational; for logging only)
    2: cursor `since` (int) — emit events strictly greater than this id
    3: type filter — comma-separated allowlist, or empty for all
    4: device session patterns — semicolon-separated globs (e.g. "main;work-*")
       Empty/missing means "all sessions" (legacy behavior).
"""
from __future__ import annotations

import errno
import fnmatch
import json
import os
import signal
import sys
import time
from datetime import datetime, timezone
from typing import Iterable

EVENTS_LOG = os.environ.get(
    "HANDOFF_EVENTS_LOG",
    os.path.expanduser("~/.handoff/events.jsonl"),
)
HEARTBEAT_INTERVAL_S = 25.0
POLL_INTERVAL_S = 0.25


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _emit(obj: dict) -> bool:
    """Write a single NDJSON line. Return False on broken pipe."""
    try:
        sys.stdout.write(json.dumps(obj, separators=(",", ":")))
        sys.stdout.write("\n")
        sys.stdout.flush()
        return True
    except BrokenPipeError:
        return False
    except OSError as e:
        if e.errno == errno.EPIPE:
            return False
        raise


def _matches_device(session: str, patterns: list[str]) -> bool:
    # Events without tmux context are global by design — every device sees
    # them. (Claude Code running outside tmux, or a future `handoff watch-exit`
    # wrapper that doesn't infer a tab.)
    if not session:
        return True
    if not patterns:
        return True
    for p in patterns:
        if not p:
            continue
        if fnmatch.fnmatchcase(session, p):
            return True
    return False


def _passes_type(ev_type: str, type_filter: list[str]) -> bool:
    return not type_filter or ev_type in type_filter


def _open_log():
    """Open the events log, returning (fh, inode) or (None, None) if missing."""
    try:
        fh = open(EVENTS_LOG, "rb")
    except FileNotFoundError:
        return None, None
    try:
        st = os.fstat(fh.fileno())
    except OSError:
        fh.close()
        return None, None
    return fh, st.st_ino


def _read_lines(fh) -> Iterable[bytes]:
    """Yield complete newline-terminated lines from a binary file handle.

    Re-buffer partial trailing lines so a writer that hasn't flushed the
    newline yet doesn't corrupt the next read.
    """
    buf = b""
    while True:
        chunk = fh.read(65536)
        if not chunk:
            break
        buf += chunk
        while True:
            nl = buf.find(b"\n")
            if nl < 0:
                break
            yield buf[: nl + 1]
            buf = buf[nl + 1 :]
    # Whatever's left is partial; reposition so we re-read it next time.
    if buf:
        try:
            fh.seek(-len(buf), os.SEEK_CUR)
        except OSError:
            pass


def _process_record(
    raw: bytes,
    *,
    since: int,
    type_filter: list[str],
    patterns: list[str],
) -> tuple[bool, int]:
    """Decode and emit one record if it passes filters.

    Returns (still_alive, max_id_seen). still_alive=False means the consumer
    closed the pipe and we should exit.
    """
    s = raw.strip()
    if not s:
        return True, since
    try:
        rec = json.loads(s)
    except json.JSONDecodeError:
        return True, since
    rid = rec.get("id")
    if not isinstance(rid, int):
        return True, since
    if rid <= since:
        return True, rid
    if not _passes_type(rec.get("type", ""), type_filter):
        return True, rid
    if not _matches_device(rec.get("tmux_session", "") or "", patterns):
        return True, rid
    if not _emit(rec):
        return False, rid
    return True, rid


def main() -> int:
    # SIGPIPE: when the phone closes its SSH channel mid-stream, Python would
    # otherwise raise an exception we'd need to catch on every write. Restoring
    # the default disposition turns it into a quick clean exit.
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)

    argv = sys.argv[1:]
    # _fingerprint is intentionally unused; kept in the arg surface so the
    # caller's logging stays grep-friendly.
    _fingerprint = argv[0] if len(argv) > 0 else ""
    try:
        since = int(argv[1]) if len(argv) > 1 and argv[1] else 0
    except ValueError:
        since = 0
    type_filter_raw = argv[2] if len(argv) > 2 else ""
    patterns_raw = argv[3] if len(argv) > 3 else ""
    type_filter = [s for s in type_filter_raw.split(",") if s]
    patterns = [s for s in patterns_raw.split(";") if s]

    # 1) Drain the existing log up to EOF so the phone catches up on anything
    # it missed while offline. We honor `since` strictly (events with id <=
    # since are skipped) and bound replay to whatever the rotation policy has
    # kept on disk.
    last_id = since
    fh, inode = _open_log()
    if fh is not None:
        try:
            for line in _read_lines(fh):
                alive, last_id = _process_record(
                    line,
                    since=last_id,
                    type_filter=type_filter,
                    patterns=patterns,
                )
                if not alive:
                    fh.close()
                    return 0
        finally:
            pass  # keep fh open for the tail loop

    # If the log rotated below `since` (very rare, only after a long offline
    # phone + ~10k Mac-side events), the client cursor is ahead of the file.
    # Don't replay; just acknowledge the gap so the client advances.
    if not _emit({"type": "ready", "ts": _now_iso(), "last_id": last_id}):
        if fh is not None:
            fh.close()
        return 0

    # 2) Tail-forever loop. Polls inode every POLL_INTERVAL_S; when the inode
    # changes (rotation), reopen and continue. Heartbeats keep TCP fresh.
    last_heartbeat = time.monotonic()
    while True:
        if fh is None:
            fh, inode = _open_log()
            if fh is None:
                # No log yet — sleep until one appears.
                time.sleep(POLL_INTERVAL_S)
                continue
            # Don't seek to end — read from the start. The id-based dedupe
            # in _process_record skips anything <= last_id, so re-reading the
            # whole file after a rotation can't double-deliver events.
            # Seeking past existing lines would *miss* events written between
            # the file's creation and our open (the cold-start race when the
            # log didn't yet exist at subscribe time).

        # Read whatever has accumulated since the last poll.
        for line in _read_lines(fh):
            alive, last_id = _process_record(
                line,
                since=last_id,
                type_filter=type_filter,
                patterns=patterns,
            )
            if not alive:
                fh.close()
                return 0
            last_heartbeat = time.monotonic()

        # Detect rotation by inode swap (atomic rename in events_log_append).
        try:
            st = os.stat(EVENTS_LOG)
            if st.st_ino != inode:
                fh.close()
                fh = open(EVENTS_LOG, "rb")
                inode = os.fstat(fh.fileno()).st_ino
                continue
        except FileNotFoundError:
            # Log was removed entirely; wait for it to come back.
            try:
                fh.close()
            except OSError:
                pass
            fh = None
            inode = None
            time.sleep(POLL_INTERVAL_S)
            continue

        # Heartbeat.
        now = time.monotonic()
        if now - last_heartbeat >= HEARTBEAT_INTERVAL_S:
            if not _emit({"type": "ping", "ts": _now_iso()}):
                fh.close()
                return 0
            last_heartbeat = now

        time.sleep(POLL_INTERVAL_S)


if __name__ == "__main__":
    sys.exit(main())
