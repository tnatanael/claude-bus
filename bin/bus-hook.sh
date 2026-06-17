#!/usr/bin/env bash
# bus-hook.sh busy|free|beat
# Wrapper de hook cross-platform: detecta o SO e roteia para o script certo.
#   busy | free  -> bus-state (marca o estado da sessao; hooks UserPromptSubmit/Stop)
#   beat         -> bus-beat  (refresca o heartbeat de presenca; hook PostToolUse)
arg="${1:-}"
root="${CLAUDE_PLUGIN_ROOT:-}"
[ -z "$root" ] && root="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)"

is_win=0
case "${OSTYPE:-}$(uname -s 2>/dev/null)" in *msys*|*cygwin*|*MINGW*|*Windows*) is_win=1 ;; esac

if [ "$arg" = "beat" ]; then
  if [ "$is_win" -eq 1 ]; then
    powershell -NoProfile -ExecutionPolicy Bypass -File "$root/bin/bus-beat.ps1"
  else
    bash "$root/bin/bus-beat.sh"
  fi
else
  if [ "$is_win" -eq 1 ]; then
    powershell -NoProfile -ExecutionPolicy Bypass -File "$root/bin/bus-state.ps1" -Set "$arg"
  else
    bash "$root/bin/bus-state.sh" "$arg"
  fi
fi
