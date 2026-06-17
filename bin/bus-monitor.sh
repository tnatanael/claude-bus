#!/usr/bin/env bash
# bus-monitor.sh --me SLUG [--poll N] [--yield N]
# Par Unix do bus-monitor.ps1: polling do inbox, valida token, espera 'free' antes de
# entregar, carimba heartbeat e garante singleton (kill best-effort + lock-PID).
set -u
me=""; poll=2; yield=1800
bus_root="${CLAUDE_BUS_ROOT:-/tmp/claude-bus}"
while [ $# -gt 0 ]; do
  case "$1" in
    --me|-Me) me="$2"; shift 2;;
    --poll) poll="$2"; shift 2;;
    --yield) yield="$2"; shift 2;;
    --bus-root) bus_root="$2"; shift 2;;
    *) shift;;
  esac
done
[ -n "$me" ] || { echo "uso: bus-monitor.sh --me SLUG" >&2; exit 1; }

# Singleton (1/2) best-effort: mata outros monitores do MESMO slug por linha de comando.
self=$$; parent=$PPID
for p in $(pgrep -f "bus-monitor\.sh" 2>/dev/null || true); do
  [ "$p" = "$self" ] || [ "$p" = "$parent" ] && continue
  args="$(ps -p "$p" -o args= 2>/dev/null || true)"
  case "$args" in *"--me $me"*|*"-Me $me"*) kill "$p" 2>/dev/null || true ;; esac
done

inbox="$bus_root/inbox"; presence="$bus_root/presence"; state="$bus_root/state"; rejected="$bus_root/rejected"
mkdir -p "$inbox" "$presence" "$state"
beat="$presence/$me.alive"
owner="$presence/$me.owner"
sid="${CLAUDE_CODE_SESSION_ID:-}"
statefile=""; [ -n "$sid" ] && statefile="$state/$sid.state"

# Singleton (2/2) cooperativo por lock-PID: gravo meu PID como dono. No loop, se o
# .owner nao for mais o meu PID, outro monitor assumiu e eu saio.
printf '%s' "$$" > "$owner"

deadline=$(( $(date +%s) + yield ))

while true; do
  touch "$beat"   # heartbeat de presenca
  # lock-PID: se outro monitor do mesmo slug assumiu o .owner, eu me retiro
  [ -f "$owner" ] && [ "$(tr -d ' \r\n' < "$owner" 2>/dev/null)" != "$$" ] && exit 0
  # re-le o segredo a cada iteracao (cobre o monitor que sobe antes do .bus-secret existir)
  secret=""; [ -f "$bus_root/.bus-secret" ] && secret="$(tr -d ' \r\n' < "$bus_root/.bus-secret")"
  hit="$(ls -tr "$inbox"/to-"$me"__*.handoff 2>/dev/null | head -n1)"
  if [ -n "$hit" ] && [ -e "$hit" ]; then
    raw="$(cat "$hit" 2>/dev/null)"
    if printf '%s' "$raw" | grep -q '###BUS-END'; then
      header="$(printf '%s' "$raw" | sed '/^---$/q')"
      ha="$(printf '%s' "$header" | sed -n 's/^auth:[[:space:]]*//p' | tr -d ' \r\n')"
      if [ -n "$secret" ] && [ "$ha" = "$secret" ]; then
        while [ -n "$statefile" ] && [ -f "$statefile" ] && [ "$(tr -d ' \r\n' < "$statefile" 2>/dev/null)" = "busy" ]; do
          touch "$beat"; sleep "$poll"
        done
        echo "BUS_EVENT=handoff"
        echo "BUS_FILE=$hit"
        echo "BUS_BODY_BEGIN"
        printf '%s\n' "$raw"
        echo "BUS_BODY_END"
        exit 0
      else
        mkdir -p "$rejected"; mv -f "$hit" "$rejected/" 2>/dev/null || true
      fi
    fi
  fi
  [ "$(date +%s)" -ge "$deadline" ] && { echo "BUS_EVENT=yield"; exit 0; }
  sleep "$poll"
done
