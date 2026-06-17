#!/usr/bin/env bash
# bus-who.sh [fresh_seconds]   (par Unix do bus-who.ps1)
# Lista quem tem monitor vivo, pelo frescor do heartbeat em presence/<slug>.alive.
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
  # mtime do arquivo: Linux usa 'stat -c %Y', macOS usa 'stat -f %m'
  mt=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null)
  age=$(( now - mt ))
  slug=$(basename "$f" .alive)
  if   [ "$age" -le "$fresh" ]; then st="ATIVO"
  elif [ "$age" -le 1800 ];     then st="ocupado/incerto"
  else                               st="OFFLINE"
  fi
  printf '%-18s %-16s (ultimo beat: %ss atras)\n' "$slug" "$st" "$age"
done
[ "$found" -eq 0 ] && echo "Nenhuma presenca registrada."
exit 0   # nao herdar o status 1 do teste acima quando ha presencas
