#!/usr/bin/env bash
# bus-who.sh [fresh_seconds]   (par Unix do bus-who.ps1)
# Lista presenca por DOIS sinais: heartbeat (frescor) E processo do monitor vivo.
set -u
bus_root="${CLAUDE_BUS_ROOT:-/tmp/claude-bus}"
fresh="${1:-120}"
pres="$bus_root/presence"

[ -d "$pres" ] || { echo "Nenhuma presenca registrada."; exit 0; }

now=$(date +%s)
found=0
for f in "$pres"/*.alive; do
  [ -e "$f" ] || continue
  found=1
  mt=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null)
  age=$(( now - mt ))
  slug=$(basename "$f" .alive)
  if   [ "$age" -le "$fresh" ]; then st="ATIVO"
  elif [ "$age" -le 1800 ];     then st="ocupado/incerto"
  else                               st="OFFLINE"
  fi
  # sinal "duro": o processo do monitor existe? (mais confiavel que o heartbeat)
  if pgrep -f "bus-monitor.sh.*[Mm]e $slug" >/dev/null 2>&1; then proc="proc:vivo"; else proc="proc:MORTO"; fi
  printf '%-18s %-16s %-11s (ultimo beat: %ss atras)\n' "$slug" "$st" "$proc" "$age"
done
[ "$found" -eq 0 ] && echo "Nenhuma presenca registrada."
exit 0
