#!/usr/bin/env bash
# bus-schedule.sh -- cria/lista/remove HANDOFFS AGENDADOS via crontab (par Unix do bus-schedule.ps1).
# Cada agendamento injeta um handoff operador->destino no inbox do BUS na cadencia escolhida, SEM
# acordar modelo. Artefatos duraveis em ~/.claude/bus-schedules/<slug>/. NAO testado a fundo no
# Unix (crontab indisponivel no ambiente de dev Windows) -- validar. Linha do cron marcada com
# '# bus-schedule:<slug>' pra o list/remove acharem.
#
# Uso:
#   bus-schedule.sh create --slug <s> --project <p> --dest <d> --cadence daily|weekly [--days mon,wed,fri] --time HH:mm --body-file <arq>
#   bus-schedule.sh list
#   bus-schedule.sh remove --slug <s>
set -u
action="${1:-}"; [ $# -gt 0 ] && shift
slug=""; project=""; dest=""; cadence="daily"; days=""; time=""; bodyfile=""
while [ $# -gt 0 ]; do
  case "$1" in
    --slug) slug="${2:-}"; shift 2;;
    --project) project="${2:-}"; shift 2;;
    --dest) dest="${2:-}"; shift 2;;
    --cadence) cadence="${2:-}"; shift 2;;
    --days) days="${2:-}"; shift 2;;
    --time) time="${2:-}"; shift 2;;
    --body-file) bodyfile="${2:-}"; shift 2;;
    *) shift;;
  esac
done
homeDir="${HOME:-${USERPROFILE:-/root}}"
schedRoot="$homeDir/.claude/bus-schedules"
selfDir="$(cd "$(dirname "$0")" && pwd)"
busSend="$selfDir/bus-send.sh"
base="${CLAUDE_BUS_ROOT:-/tmp/claude-bus}"

case "$action" in
  create)
    [ -n "$slug" ] && [ -n "$project" ] && [ -n "$dest" ] && [ -n "$time" ] || { echo "create exige --slug --project --dest --time" >&2; exit 1; }
    echo "$time" | grep -qE '^([01]?[0-9]|2[0-3]):[0-5][0-9]$' || { echo "time invalido (HH:mm 24h): $time" >&2; exit 1; }
    [ -f "$bodyfile" ] || { echo "body-file ausente: $bodyfile" >&2; exit 1; }
    [ "$cadence" = "weekly" ] && [ -z "$days" ] && { echo "weekly exige --days (ex.: mon,wed,fri)" >&2; exit 1; }
    if [ "$project" != "default" ]; then busRoot="$base/$project"; else busRoot="$base"; fi
    dir="$schedRoot/$slug"; mkdir -p "$dir"
    cp -f "$bodyfile" "$dir/body.txt"
    { echo "slug=$slug"; echo "project=$project"; echo "dest=$dest"; echo "busSend=$busSend"; echo "busRoot=$busRoot"; echo "cadence=$cadence"; echo "time=$time"; echo "days=$days"; } > "$dir/schedule.meta"
    cat > "$dir/_send.sh" <<'SENDEOF'
#!/usr/bin/env bash
dir="$(cd "$(dirname "$0")" && pwd)"
meta="$dir/schedule.meta"; log="$dir/send.log"; body="$dir/body.txt"
stamp="$(date '+%Y-%m-%d %H:%M:%S')"
g() { sed -n "s/^$1=//p" "$meta" | head -n1; }
if [ ! -f "$body" ]; then echo "$stamp ERRO body.txt ausente" >> "$log"; exit 1; fi
out="$(bash "$(g busSend)" --to "$(g dest)" --from operador --project "$(g project)" --bus-root "$(g busRoot)" --body-file "$body" 2>&1)"; code=$?
echo "$stamp exit=$code $out" >> "$log"
exit $code
SENDEOF
    chmod +x "$dir/_send.sh"
    hh=$((10#${time%%:*})); mm=$((10#${time##*:}))
    if [ "$cadence" = "weekly" ]; then dow="$(echo "$days" | tr '[:upper:]' '[:lower:]')"; else dow="*"; fi
    line="$mm $hh * * $dow \"$dir/_send.sh\" # bus-schedule:$slug"
    ( crontab -l 2>/dev/null | grep -v "# bus-schedule:$slug\$"; echo "$line" ) | crontab -
    echo "CREATED=$slug"; echo "DIR=$dir"; echo "CRON=$line"
    ;;
  list)
    any=0
    if [ -d "$schedRoot" ]; then
      for d in "$schedRoot"/*/; do
        [ -f "${d}schedule.meta" ] || continue
        any=1; s="$(basename "$d")"; mf="${d}schedule.meta"
        gg() { sed -n "s/^$1=//p" "$mf" | head -n1; }
        cad="$(gg cadence)"; [ "$cad" = "weekly" ] && cad="weekly $(gg days)"
        cl="$(crontab -l 2>/dev/null | grep "# bus-schedule:$s\$" || true)"
        echo "[$s] $(gg project) -> $(gg dest) | $cad @ $(gg time) | cron: ${cl:-(ausente!)}"
        [ -f "${d}send.log" ] && echo "    log: $(tail -n1 "${d}send.log")"
      done
    fi
    [ "$any" = "0" ] && echo "(nenhum agendamento)"
    ;;
  remove)
    [ -n "$slug" ] || { echo "remove exige --slug" >&2; exit 1; }
    crontab -l 2>/dev/null | grep -v "# bus-schedule:$slug\$" | crontab - 2>/dev/null || true
    echo "CRON_REMOVED=$slug"
    dir="$schedRoot/$slug"
    if [ -d "$dir" ]; then rm -rf "$dir"; echo "DIR_REMOVED=$dir"; else echo "DIR_AUSENTE=$dir"; fi
    ;;
  *) echo "uso: bus-schedule.sh create|list|remove ..." >&2; exit 1;;
esac
