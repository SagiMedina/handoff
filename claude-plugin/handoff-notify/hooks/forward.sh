#!/usr/bin/env bash
# Claude Code → Handoff bridge.
# Reads the hook event JSON from stdin, infers tmux session/window from
# $TMUX_PANE, and shells out to `handoff notify`. Fails open: any error here
# must never block Claude.

set -uo pipefail

type="${1:-notify}"
payload="$(cat 2>/dev/null || true)"

# Tiny stdin-JSON field extractor (consistent with how lib/handoff-common.sh
# already shells out to python3 for JSON work).
extract() {
    HANDOFF_HOOK_PAYLOAD="$payload" HANDOFF_HOOK_KEY="$1" python3 -c '
import json, os, sys
raw = os.environ.get("HANDOFF_HOOK_PAYLOAD", "") or "{}"
try:
    d = json.loads(raw)
except Exception:
    d = {}
v = d.get(os.environ["HANDOFF_HOOK_KEY"], "")
if v is None:
    v = ""
sys.stdout.write(str(v))
' 2>/dev/null || true
}

msg=$(extract message)
sid=$(extract session_id)
cwd=$(extract cwd)

# Sensible defaults for the two events we wire by default. The Notification
# hook usually carries a message ("Claude needs your permission to use Bash");
# Stop carries none.
if [[ -z "$msg" ]]; then
    case "$type" in
        stop)   msg="Claude finished" ;;
        notify) msg="Claude is waiting" ;;
        *)      msg="Claude: $type" ;;
    esac
fi

# Friendlier title than the default per-tab generic "Claude • main:#0".
case "$type" in
    stop)   title="Claude finished" ;;
    notify) title="Claude is waiting" ;;
    *)      title="" ;;
esac

args=(--type "$type" --message "$msg" --source claude-code)
[[ -n "$title" ]] && args+=(--title "$title")
[[ -n "$sid"   ]] && args+=(--claude-session-id "$sid")
[[ -n "$cwd"   ]] && args+=(--cwd "$cwd")

# Tab inference. The handoff CLI also infers from $TMUX_PANE, but the hook
# inherits Claude Code's environment — explicitly pass through so a future
# change to handoff's defaults can't desync the two.
if [[ -n "${TMUX_PANE:-}" ]] && command -v tmux >/dev/null 2>&1; then
    tab="$(tmux display -p -t "${TMUX_PANE}" '#S|#I' 2>/dev/null || true)"
    if [[ -n "$tab" ]]; then
        ts="${tab%%|*}"; tw="${tab#*|}"; tw="${tw%%|*}"
        [[ -n "$ts" ]] && args+=(--tmux-session "$ts")
        [[ -n "$tw" ]] && args+=(--tmux-window "$tw")
    fi
fi

# Locate the handoff binary, in this priority order:
#   1. $HANDOFF_BIN (explicit override)
#   2. handoff on PATH (typical brew install)
#   3. ${CLAUDE_PLUGIN_ROOT}/../../bin/handoff (set by the Claude Code plugin
#      manager when this script is invoked through it)
#   4. ../../bin/handoff resolved from this script's own filesystem path
#      (works for dev installs and direct-settings.json wiring, neither of
#      which sets CLAUDE_PLUGIN_ROOT)
# Fail-open: if none are found, the hook still exits 0 so Claude isn't blocked.
hb=""
if [[ -n "${HANDOFF_BIN:-}" && -x "${HANDOFF_BIN}" ]]; then
    hb="$HANDOFF_BIN"
elif command -v handoff >/dev/null 2>&1; then
    hb="$(command -v handoff)"
elif [[ -n "${CLAUDE_PLUGIN_ROOT:-}" && -x "${CLAUDE_PLUGIN_ROOT}/../../bin/handoff" ]]; then
    hb="${CLAUDE_PLUGIN_ROOT}/../../bin/handoff"
else
    # Resolve the script's own dir, following symlinks so this works even
    # when ~/.claude/plugins/cache/.../forward.sh is a symlink to the repo.
    src="${BASH_SOURCE[0]}"
    while [[ -L "$src" ]]; do
        dir="$(cd -P "$(dirname "$src")" && pwd)"
        src="$(readlink "$src")"
        [[ "$src" != /* ]] && src="$dir/$src"
    done
    self_dir="$(cd -P "$(dirname "$src")" && pwd)"
    # hooks/ → handoff-notify/ → claude-plugin/ → repo root → bin/handoff
    candidate="$self_dir/../../../bin/handoff"
    if [[ -x "$candidate" ]]; then
        hb="$candidate"
    fi
fi
if [[ -z "$hb" ]]; then
    exit 0
fi
"$hb" notify "${args[@]}" >/dev/null 2>&1 || true
exit 0
