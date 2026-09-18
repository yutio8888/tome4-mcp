#!/usr/bin/env bash
# Reap (or pause) a finished isolated ToME play/test session.
#
# WHY: a [Test] agent may not start/stop processes, and a headless ToME under
# Xvfb renders unthrottled, so a session left behind after its report keeps
# burning 200-360% CPU for hours (observed: 3 sessions -> ~900% CPU, load 30 on
# a 16-core box). ALWAYS reap a round's session as soon as its report exists.
#
# Usage:
#   reap-session.sh <session>            # SIGKILL the whole process group (default)
#   reap-session.sh <session> --stop     # SIGSTOP it (preserve a live scene, ~0 CPU)
#   reap-session.sh <session> --cont     # SIGCONT a paused session
#   reap-session.sh --list               # list live sessions with CPU
#   reap-session.sh --all                # KILL every live session
#
# A session owns a process group (agent-play.py + t-engine + Xvfb + tome_mcp),
# so the group is signalled as a unit. Evidence (game.log, play-mcp.jsonl,
# result.json, the console .log) is NEVER deleted; only the FIFO is removed.
set -eu

ROOT=/workspace/t-engine4
SESS=$ROOT/tmp/tome-mcp-validation/sessions
SUPPORT=$ROOT/tmp/mcp-play-support

session_of() { # pid -> session name (from the session path in the cmdline)
    tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null \
        | sed -n 's|.*/sessions/\([^/]*\)/runtime/t-engine.*|\1|p'
}

live_pids() { # all live t-engine pids
    for d in "$SESS"/*/runtime/t-engine; do
        [ -x "$d" ] || continue
        s=$(basename "$(dirname "$(dirname "$d")")")
        p=$(pgrep -f "sessions/$s/runtime/t-engine" | head -1 || true)
        [ -n "$p" ] && echo "$s $p"
    done
}

cpu_of() { ps -o pcpu= -p "$1" 2>/dev/null | tr -d ' '; }

pgid_of() { ps -o pgid= -p "$1" 2>/dev/null | tr -d ' '; }

kill_group() { # session pid signal
    local s=$1 p=$2 sig=$3 g
    g=$(pgid_of "$p"); [ -n "$g" ] || g=$p
    kill -"$sig" -"$g" 2>/dev/null || kill -"$sig" "$p" 2>/dev/null || true
    printf '%-28s pid=%-8s pgid=%-8s %s\n' "$s" "$p" "$g" "$sig"
    [ "$sig" = KILL ] && rm -f "$SUPPORT/$s.cmd"
}

case "${1:-}" in
    --list|"")
        printf '%-30s %-10s %-8s %s\n' SESSION PID CPU% ELAPSED
        live_pids | while read -r s p; do
            printf '%-30s %-10s %-8s %s\n' "$s" "$p" "$(cpu_of "$p")" \
                "$(ps -o etime= -p "$p" | tr -d ' ')"
        done
        exit 0 ;;
    --all)
        live_pids | while read -r s p; do kill_group "$s" "$p" KILL; done
        exit 0 ;;
esac

S=${1:?usage: reap-session.sh <session>|--list|--all [--stop|--cont]}
case "${2:-}" in
    --stop) SIG=STOP ;;
    --cont) SIG=CONT ;;
    "")     SIG=KILL ;;
    *)      echo "reap-session.sh: unknown option $2" >&2; exit 2 ;;
esac

[ -d "$SESS/$S" ] || { echo "reap-session.sh: no such session $S" >&2; exit 2; }
P=$(pgrep -f "sessions/$S/runtime/t-engine" | head -1 || true)
if [ -z "$P" ]; then
    echo "reap-session.sh: $S has no live t-engine (already reaped)"
    rm -f "$SUPPORT/$S.cmd"
    exit 0
fi
kill_group "$S" "$P" "$SIG"
if [ "$SIG" = KILL ]; then
    sleep 3
    pgrep -f "sessions/$S/runtime/t-engine" >/dev/null 2>&1 \
        && echo "WARNING: $S still alive" || echo "reaped $S"
fi
