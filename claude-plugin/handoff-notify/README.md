# handoff-notify

Forward Claude Code's `Notification` and `Stop` hook events to a paired phone
via [Handoff](https://github.com/SagiMedina/handoff).

When Claude pauses to wait for input or finishes a response, your phone gets a
push notification with the tmux tab it came from. Tapping it deep-links into
the Handoff app at the right tab. If you're already viewing that tab on your
phone, the notification is suppressed.

## Install

```
/plugin marketplace add SagiMedina/handoff
/plugin install handoff-notify@handoff
```

This plugin requires the `handoff` CLI on your `PATH`. If it isn't installed,
the hooks fail open silently — Claude is never blocked.

### Manual install (no marketplace)

Useful when the marketplace path isn't available (e.g. the repo isn't on
GitHub yet, or you want a hermetic setup that doesn't depend on the
plugin manager). Append two blocks under `hooks` in
`~/.claude/settings.json`, replacing `<absolute path to repo>` with where
you cloned this repository:

```json
{
  "hooks": {
    "Notification": [
      {
        "hooks": [
          { "type": "command",
            "command": "<absolute path to repo>/claude-plugin/handoff-notify/hooks/forward.sh notify",
            "timeout": 5 }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          { "type": "command",
            "command": "<absolute path to repo>/claude-plugin/handoff-notify/hooks/forward.sh stop",
            "timeout": 5 }
        ]
      }
    ]
  }
}
```

If you already have other Notification/Stop hooks (e.g. iTerm2 attention
requests), keep them — append new array entries rather than replacing.
Multiple blocks under the same event all fire.

Run `/reload-plugins` (or restart Claude Code) and the next Notification
or Stop event should ping your phone.

## What it does

Two hooks are wired:

- **Notification** — fires when Claude is waiting for input, e.g. a permission
  prompt. Emitted as `type=notify`.
- **Stop** — fires when Claude's main agent finishes its response. Emitted as
  `type=stop`.

Each hook calls:

```
handoff notify --type <notify|stop> \
               --message <hook-payload-or-default> \
               --tmux-session <inferred from $TMUX_PANE> \
               --tmux-window  <inferred from $TMUX_PANE> \
               --claude-session-id <hook session_id> \
               --cwd <hook cwd> \
               --source claude-code
```

`handoff notify` writes a single NDJSON line to `~/.handoff/events.jsonl`.
Paired phones holding an open `handoff gate subscribe` channel receive the
event within ~250 ms and post a system notification.

## Adding more events

By default only Notification and Stop are wired. To also push subagent stops,
edit `${CLAUDE_PLUGIN_ROOT}/hooks/hooks.json` and add:

```json
"SubagentStop": [
  {"hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/hooks/forward.sh subagent-stop","timeout":5}]}
]
```

Be aware that subagent stops can be chatty if you delegate a lot.

## Uninstall

```
/plugin uninstall handoff-notify
```

The hooks vanish immediately. The events log on disk (`~/.handoff/events.jsonl`)
is left intact — `handoff` may still want it for other notification sources.
