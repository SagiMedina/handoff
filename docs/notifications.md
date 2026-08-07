# Phone notifications

Push events from your Mac to a paired Handoff Android device, reusing the
same SSH/Tailscale channel the app already uses for terminal access.

This document covers what the bridge actually is: the wire format, the
schema, the gate protocol additions, the dedupe and suppression rules,
and how to plug in a new source.

If you just want to *use* it, the [README's Phone notifications
section](../README.md#phone-notifications) is enough.

## Pipeline at a glance

```
                        Mac                                                     Phone
┌──────────────────────────────────────────────────────┐    ┌─────────────────────────────────────┐
│                                                      │    │                                     │
│  source ──► handoff notify ──► ~/.handoff/events.jsonl   │    │  HandoffConnectionService           │
│                                       │              │    │      └─► NotificationSubscriber     │
│                       (flock + monotonic id +        │    │              │                      │
│                        size-bounded rotation)        │    │              ▼                      │
│                                       ▼              │    │       JSch session over Tailscale   │
│           handoff gate subscribe                     │◄───┤       (own connection, separate     │
│              ↳ lib/handoff-events-stream.py          │    │       from the terminal SSH)        │
│                  – drain since=N                     │    │              │                      │
│                  – tail -F (inode-aware)             │    │              ▼                      │
│                  – heartbeat every 25s               │    │      NotificationPoster             │
│                  – session-pattern filter            │    │       ↳ HIGH-importance channel    │
│                                                      │    │       ↳ per-tab dedupe id          │
└──────────────────────────────────────────────────────┘    │       ↳ active-tab suppression     │
                                                            │       ↳ deep-link to terminal/{s}/{w}│
                                                            └─────────────────────────────────────┘
```

No new ports. No FCM. No third-party push service. The phone is the
SSH client; the Mac streams events back over an open exec channel.

## Event schema

`handoff notify` writes one JSON object per line into
`~/.handoff/events.jsonl`:

```json
{
  "id": 42,
  "ts": "2026-04-25T07:03:36Z",
  "type": "notify",
  "title": "Claude is waiting",
  "message": "Claude needs your permission to use Bash",
  "tmux_session": "main",
  "tmux_window": 1,
  "cwd": "/Users/sagimedina/PycharmProjects/handoff",
  "claude_session_id": "abc-123",
  "source": "claude-code"
}
```

| Field | Required | Notes |
|---|---|---|
| `id` | yes | Monotonic uint, allocated atomically via flock on `~/.handoff/events.id`. Subscribers use this for resume cursors and dedupe. |
| `ts` | yes | ISO-8601 UTC timestamp of when the event was written. |
| `type` | yes | Free-form, but `notify` and `stop` are conventions used by the Claude Code plugin. The Android side uses `type` only for default titles when `title` is absent. |
| `message` | yes | Body text of the notification. |
| `title` | optional | Title shown bold; if omitted, the Android side picks a sensible default per `type`. |
| `tmux_session` / `tmux_window` | optional but pair-up | Identify the tab. When both are set, drives per-tab dedupe and active-tab suppression. When omitted, the event delivers as a "no tab" notification (one per event id). |
| `cwd` | optional | Used as the notification's `subText`: `cwd.substringAfterLast('/')`. This is the most user-recognizable identifier ("handoff", "qodo-in-slack") — far better than `main · #1`. |
| `claude_session_id` | optional | Claude Code's session id. Currently informational; future deep-link targets could use it. |
| `source` | optional | Free-form; lets a source identify itself ("claude-code", "ci", etc.). Currently informational. |

### Rotation

When `events.jsonl` is about to exceed `HANDOFF_EVENTS_LOG_MAX_BYTES`
(default 1 MB, ≈10 k events), `events_log_append` renames it to
`events.jsonl.1` *atomically* (`os.replace`) before opening a fresh file.
Tailing subscribers pick up the new inode automatically — they poll
`os.stat().st_ino` every 250 ms inside `lib/handoff-events-stream.py`.

The `id` counter (`~/.handoff/events.id`) is **not** rotated. Ids are
monotonic forever; rotation only bounds disk usage, not the address space.

## Gate protocol

The phone subscribes by issuing a new gate subcommand:

```
SSH_ORIGINAL_COMMAND="subscribe since=<id> [types=<csv>]"
```

`since=<id>` resumes after the named id (events with `id <= since` are
skipped). `types=<csv>` (optional) restricts delivery to the named
types — e.g. `types=stop` to only get completion pings.

The gate logs **one line per connection** to `~/.handoff/access.log`:

```
{"ts":"...","fp":"SHA256:…","name":"Pixel 7","cmd":"subscribe since=5","result":"ok:subscribe:since=5"}
```

Per-event lines are not logged — that would drown out the access log on a
chatty source. The audit trail is at the connection level.

### Wire format

The subscribe stream is line-delimited NDJSON over the SSH channel. Three
record kinds:

```jsonc
{"id":42,"type":"notify","message":"…", …}                 // event
{"type":"ready","ts":"…","last_id":42}                     // initial drain done
{"type":"ping","ts":"…"}                                   // heartbeat every 25s
```

`ready` is emitted exactly once, after the helper has scanned the existing
log up to the current EOF. Clients use it to know "you're caught up" and
to potentially snap their persisted cursor forward if they're somehow
ahead of `last_id` (rotation gap edge case).

`ping` records keep half-open TCP detectable independently of JSch's
`ServerAliveInterval` (already 15 s on the Android side).

### Filtering

The gate reuses `session_matches_patterns` from `lib/handoff-common.sh` —
the same matcher that gates `list`, `attach`, etc. Events with no
`tmux_session` are treated as **global** and delivered to every device
regardless of session patterns. That preserves the reach of build scripts
and other non-tmux sources.

`subscribe` is read-only and respects soft expiry like the other gate
commands. There's no `read_only` check because there's nothing to write.

## Android-side rules

### Dedupe

```
notificationId = ("$tmux_session:$tmux_window").hashCode() and 0x3FFFFFFF
```

The mask keeps the result positive (Java/Kotlin `hashCode` can return
negative ints) and clears the high bit so it can't collide with the
"no tab" id space:

```
noTabId = (event.id.toInt() and 0x3FFFFFFF) or 0x40000000
```

Posting with the same id replaces in place. So a `Stop` event for
`main:1` overwrites the earlier `Notification` event for `main:1` —
the user sees one notification per tab, with the latest content.

### Active-tab suppression

`ForegroundState` (singleton in `data/ForegroundState.kt`) holds three
`StateFlow`s:

| Flow | Updated by | When the user is "viewing this tab" |
|---|---|---|
| `isForeground: Boolean` | `ActivityLifecycleCallbacks` registered in `HandoffApp.onCreate` | true when ≥1 Activity is in started state |
| `currentRoute: String?` | `NavController.OnDestinationChangedListener` in `MainActivity` | starts with `terminal/` |
| `activeTerminalTab: Pair<String, Int>?` | `DisposableEffect` in `TerminalScreen` | matches the event's `(tmux_session, tmux_window)` |

All three must be true for the poster to suppress. `TerminalScreen.matches`
alone is insufficient because it stays true after navigating away to
SessionsScreen / Settings — only `currentRoute` settles that.

When suppressed, the cursor still advances. The event is "delivered" in
the UX sense (the user *did* see it — by virtue of looking at the tab).

### Deep-link

`MainActivity.ACTION_OPEN_TAB` carries `EXTRA_DEEPLINK_SESSION` and
`EXTRA_DEEPLINK_WINDOW`. `onNewIntent` (and the cold-start `onCreate`
path) populates a `pendingDeepLink` flow; a `LaunchedEffect` consumes it
once `config != null` and routes:

```kotlin
navController.navigate("terminal/$session/$window") {
    launchSingleTop = true
    popUpTo(startDest)
}
```

The notification's `PendingIntent` `requestCode` is the same per-tab id —
without that, Android would reuse a single PendingIntent for the channel
and replay the *first* event's extras on every notification (a classic
bug; we sidestep it by binding requestCode to the dedupe id).

## Adding a new source

The Claude Code plugin in `claude-plugin/handoff-notify/` is the canonical
example. Mirror its shape:

1. Receive whatever the upstream tool gives you (stdin JSON, env vars,
   exit code).
2. Extract `message`, `cwd`, an optional session id.
3. If running inside tmux (`$TMUX_PANE` set), call `tmux display -p
   '#S|#I'` to grab the session and window.
4. Shell out to `handoff notify` with the appropriate `--type`,
   `--message`, `--cwd`, `--tmux-session`, `--tmux-window`. Fail-open: if
   `handoff` isn't on `PATH`, the hook should still exit 0 so the
   upstream tool isn't blocked.

A barebones one-liner already works:

```bash
make build && handoff notify --type custom --message "build done"
```

For a tool with hooks (Codex CLI, Gemini CLI, future agents), wrap the
above in a script and ship it as a plugin in *that tool's* marketplace.
Don't add tool-specific logic to `bin/handoff` — see
[`memory/project_notify_pipeline_split.md`](https://github.com/SagiMedina/handoff)
for the architecture rule.

## Files

- `bin/handoff` — `cmd_notify`, `cmd_gate` `subscribe` arm.
- `lib/handoff-common.sh` — `events_log_init`, `events_log_append`,
  `events_log_next_id`, plus the `HANDOFF_EVENTS_*` constants.
- `lib/handoff-events-stream.py` — the long-lived gate stream helper.
- `claude-plugin/handoff-notify/` — Claude Code plugin (manifest, hooks
  wiring, `forward.sh` bridge script).
- `android/app/src/main/java/com/handoff/app/data/`:
  - `NotificationSubscriber.kt` — long-lived JSch session, NDJSON parser,
    backoff, cursor management.
  - `NotificationPoster.kt` — channel registration helpers, dedupe id
    derivation, suppression rule.
  - `NotificationCursorStore.kt` — SharedPreferences-backed cursor.
  - `ForegroundState.kt` — three `StateFlow`s the suppression rule
    depends on.
- `android/app/src/main/java/com/handoff/app/`:
  - `HandoffApp.kt` — registers the `ActivityLifecycleCallbacks`.
  - `MainActivity.kt` — `onNewIntent`, deep-link handler, route listener.
  - `service/HandoffConnectionService.kt` — owns the subscriber's
    lifecycle; registers both notification channels.
  - `service/BootReceiver.kt` — restarts the service on
    `BOOT_COMPLETED` and `MY_PACKAGE_REPLACED` if the user is paired,
    so the subscriber wakes up without the user reopening the app.
  - `ui/screens/TerminalScreen.kt` — `DisposableEffect` updates
    `activeTerminalTab` and clears stale notifications on enter.

## Reliability

The bridge survives the common drop scenarios:

| Event | What happens |
|---|---|
| Phone offline / Wi-Fi blip | Subscriber backs off (1s → 30s capped, resets on first received line) and reconnects. Mac queues events in `events.jsonl`; subscriber resumes with `since=<lastSeenId>` and drains the gap. |
| App backgrounded | Foreground service keeps process alive; subscriber stays connected. |
| App force-stopped | Process dies. Service restarts on next user app launch — events queued during the gap deliver on reconnect (within rotation bounds). |
| Phone reboot | `BootReceiver` fires on `BOOT_COMPLETED` after first unlock. If paired, the service auto-starts and the subscriber resumes from the persisted cursor. |
| APK upgrade | `BootReceiver` also handles `MY_PACKAGE_REPLACED`. No reopen needed. |
| Subscriber cursor below Mac's max id (long offline + ~10k events) | One-line warning, fresh-start from EOF — never replays a flood. |
| Mac reboot | Events log + counter persist; subscriber reconnects when Mac sshd is back; cursor resumes cleanly. |
| Multiple paired devices | Each runs its own subscriber with its own cursor; events broadcast to all (with per-device session-pattern filtering on the gate side). |
