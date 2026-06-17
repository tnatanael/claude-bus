#!/usr/bin/env bash
# bus-state.sh busy|free   (par Unix do bus-state.ps1)
# Marca o estado busy/free desta sessao (por CLAUDE_CODE_SESSION_ID). Quem le e o
# bus-monitor.sh, que so entrega um handoff (acorda a sessao) quando o estado e 'free'.
set -u
val="${1:-}"
bus_root="${CLAUDE_BUS_ROOT:-/tmp/claude-bus}"

[ -z "${CLAUDE_CODE_SESSION_ID:-}" ] && exit 0   # sem id de sessao nao ha o que marcar
if [ "$val" != "busy" ] && [ "$val" != "free" ]; then
  echo "uso: bus-state.sh busy|free" >&2
  exit 1
fi

mkdir -p "$bus_root/state"
printf '%s' "$val" > "$bus_root/state/$CLAUDE_CODE_SESSION_ID.state"
