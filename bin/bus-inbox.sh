#!/usr/bin/env bash
# bus-inbox.sh --me SLUG   (par Unix do bus-inbox.ps1)
# Leitor ONE-SHOT do inbox: lista handoffs AUTENTICADOS pra SLUG (mais antigo primeiro).
# Forjados vao pra rejected/. Saida por handoff valido:
#   BUS_FILE=<caminho> / BUS_BODY_BEGIN / <corpo> / BUS_BODY_END
# Nada pendente: BUS_EMPTY. Sem polling, sem background -- substitui o monitor no pull.
set -u
me=""
bus_root="${CLAUDE_BUS_ROOT:-/tmp/claude-bus}"
while [ $# -gt 0 ]; do
  case "$1" in
    --me|-Me) me="$2"; shift 2;;
    --bus-root) bus_root="$2"; shift 2;;
    *) shift;;
  esac
done
[ -n "$me" ] || { echo "uso: bus-inbox.sh --me SLUG" >&2; exit 1; }

inbox="$bus_root/inbox"; rejected="$bus_root/rejected"
mkdir -p "$inbox"
secret=""; [ -f "$bus_root/.bus-secret" ] && secret="$(tr -d ' \r\n' < "$bus_root/.bus-secret")"

# Minuto aleatorio (0-59) pro cron de auto-recheck do /bus: cada sessao arma num
# minuto diferente pra nao baterem todas na API no mesmo instante (rate limit).
echo "BUS_CRON_MINUTE=$((RANDOM % 60))"

found=0
for hit in $(ls -tr "$inbox"/to-"$me"__*.handoff 2>/dev/null); do
  [ -e "$hit" ] || continue
  raw="$(cat "$hit" 2>/dev/null)"
  printf '%s' "$raw" | grep -q '###BUS-END' || continue   # escrita ainda em curso
  header="$(printf '%s' "$raw" | sed '/^---$/q')"
  ha="$(printf '%s' "$header" | sed -n 's/^auth:[[:space:]]*//p' | tr -d ' \r\n')"
  if [ -z "$secret" ] || [ "$ha" != "$secret" ]; then
    mkdir -p "$rejected"; mv -f "$hit" "$rejected/" 2>/dev/null || true
    continue
  fi
  found=$((found+1))
  echo "BUS_FILE=$hit"
  echo "BUS_BODY_BEGIN"
  printf '%s\n' "$raw"
  echo "BUS_BODY_END"
done
[ "$found" -eq 0 ] && echo "BUS_EMPTY"
exit 0
