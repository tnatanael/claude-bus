#!/usr/bin/env bash
# bus-hook.sh busy|free
# Wrapper de hook cross-platform: detecta o SO e marca o estado da sessao chamando o
# bus-state correspondente. Acionado pelos hooks UserPromptSubmit (busy) e Stop (free).
state="${1:-}"
root="${CLAUDE_PLUGIN_ROOT:-}"
[ -z "$root" ] && root="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)"

case "${OSTYPE:-}$(uname -s 2>/dev/null)" in
  *msys*|*cygwin*|*MINGW*|*Windows*)
    powershell -NoProfile -ExecutionPolicy Bypass -File "$root/bin/bus-state.ps1" -Set "$state" ;;
  *)
    bash "$root/bin/bus-state.sh" "$state" ;;
esac
