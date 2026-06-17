#!/usr/bin/env bash
# bus-beat.sh : refresh this session's presence heartbeat from ACTIVITY (called by
# a PostToolUse hook), not only from the monitor. The monitor exits when it
# delivers a handoff and is only relaunched at end of turn, so during long
# processing the heartbeat would otherwise freeze and the dashboard would wrongly
# show an actively-working session as offline. Touching presence on every tool use
# keeps a working session "alive" regardless of the monitor.
# Resolves the slug from CLAUDE_CODE_SESSION_ID -> names/<sid>.txt. No-op if unnamed.
set -u
bus_root="${CLAUDE_BUS_ROOT:-/tmp/claude-bus}"
sid="${CLAUDE_CODE_SESSION_ID:-}"
[ -z "$sid" ] && exit 0
name_file="$bus_root/names/$sid.txt"
[ -s "$name_file" ] || exit 0
slug="$(tr -d ' \r\n' < "$name_file")"
[ -n "$slug" ] || exit 0
mkdir -p "$bus_root/presence"
touch "$bus_root/presence/$slug.alive"
exit 0
