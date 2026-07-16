#!/usr/bin/env bash
# bus-inbox.sh [--me SLUG] [--project P] [--bus-root R]   (par Unix do bus-inbox.ps1)
# Leitor ONE-SHOT do inbox: lista handoffs AUTENTICADOS pra SLUG (mais antigo primeiro).
# Sem --me: resolve a identidade sozinho (names/<sid>) e emite BUS_SLUG=/BUS_PROJECT= no topo
# (ou BUS_IDENTITY=NONE). Saida ENXUTA por handoff valido (sem auth/markers no corpo):
#   BUS_FILE= / BUS_FROM= / BUS_ID= / BUS_REPLY_REQUIRED= / [BUS_IN_REPLY_TO=] / BUS_BODY_BEGIN / <corpo> / BUS_BODY_END
# Forjados vao pra rejected/. Nada pendente: BUS_EMPTY.
set -u
me=""; project=""; bus_root=""
base="${CLAUDE_BUS_ROOT:-/tmp/claude-bus}"
sid="${CLAUDE_CODE_SESSION_ID:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --me|-Me) me="$2"; shift 2;;
    --project|-Project) project="$2"; shift 2;;
    --bus-root) bus_root="$2"; shift 2;;
    *) shift;;
  esac
done

# Intervalo do cron (GLOBAL, config do dashboard em <base>/.bus-cron-interval). Default 5, clamp [1,30].
cron_interval=5
civ="$(cat "$base/.bus-cron-interval" 2>/dev/null | tr -dc '0-9')"
[ -n "$civ" ] && [ "$civ" -ge 1 ] 2>/dev/null && [ "$civ" -le 30 ] 2>/dev/null && cron_interval="$civ"
echo "BUS_CRON_INTERVAL=$cron_interval"

# IDENTIDADE AUTO-RESOLVIDA: sem --me, le names/<sid> (linha1=projeto, linha2=slug) e ANUNCIA.
if [ -z "$me" ]; then
  if [ -n "$sid" ] && [ -f "$base/names/$sid.txt" ]; then
    nf="$base/names/$sid.txt"
    l2="$(sed -n '2p' "$nf" | tr -d '[:space:]')"
    if [ -n "$l2" ]; then
      [ -z "$project" ] && project="$(sed -n '1p' "$nf" | tr -d '[:space:]')"
      me="$l2"
    else
      [ -z "$project" ] && project="default"
      me="$(sed -n '1p' "$nf" | tr -d '[:space:]')"
    fi
  fi
  if [ -z "$me" ]; then echo "BUS_IDENTITY=NONE"; exit 0; fi
  echo "BUS_SLUG=$me"
  if [ -n "$project" ]; then echo "BUS_PROJECT=$project"; else echo "BUS_PROJECT=default"; fi
fi

# Raiz: --bus-root explicito vence; senao base + projeto (subpasta, exceto 'default').
if [ -z "$bus_root" ]; then
  if [ -n "$project" ] && [ "$project" != "default" ]; then bus_root="$base/$project"; else bus_root="$base"; fi
fi

# Marcador "visto por ultimo" na BASE (global): mantem o "armado" do dashboard fresco.
[ -n "$sid" ] && { mkdir -p "$base/seen"; date +%s > "$base/seen/$sid"; }

inbox="$bus_root/inbox"; rejected="$bus_root/rejected"
mkdir -p "$inbox"
# segredo compartilhado (get-or-create; mv -n evita corrida na 1a criacao).
secret_file="$bus_root/.bus-secret"
if [ ! -f "$secret_file" ]; then
  if command -v openssl >/dev/null 2>&1; then s="$(openssl rand -hex 32)"
  else s="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"; fi
  tmpsec="$secret_file.$$.tmp"; printf '%s' "$s" > "$tmpsec"
  mv -n "$tmpsec" "$secret_file" 2>/dev/null || true
  [ -f "$tmpsec" ] && rm -f "$tmpsec"
fi
secret="$(tr -d ' \r\n' < "$secret_file")"

found=0
for hit in $(ls -tr "$inbox"/to-"$me"__*.handoff 2>/dev/null); do
  [ -e "$hit" ] || continue
  raw="$(cat "$hit" 2>/dev/null)"
  printf '%s' "$raw" | grep -q '###BUS-END' || continue   # escrita ainda em curso
  header="$(printf '%s' "$raw" | sed '/^---[[:space:]]*$/q')"
  ha="$(printf '%s' "$header" | sed -n 's/^auth:[[:space:]]*//p' | tr -d ' \r\n')"
  if [ -z "$secret" ] || [ "$ha" != "$secret" ]; then
    mkdir -p "$rejected"; mv -f "$hit" "$rejected/" 2>/dev/null || true
    continue
  fi
  # Entrega SO o essencial: from/id/reply_required/(in_reply_to) + corpo LIMPO (sem auth/markers).
  hfrom="$(printf '%s' "$header" | sed -n 's/^from:[[:space:]]*//p' | tr -d '\r' | head -n1)"
  hid="$(printf '%s' "$header" | sed -n 's/^id:[[:space:]]*//p' | tr -d '\r' | head -n1)"
  hrr="$(printf '%s' "$header" | sed -n 's/^reply_required:[[:space:]]*//p' | tr -d '\r' | head -n1)"
  hirt="$(printf '%s' "$header" | sed -n 's/^in_reply_to:[[:space:]]*//p' | tr -d '\r' | head -n1)"
  # corpo = tudo depois da 1a linha '---', sem a linha ###BUS-END
  body="$(printf '%s\n' "$raw" | sed '1,/^---[[:space:]]*$/d' | sed '/^###BUS-END[[:space:]]*$/d')"
  [ -z "$hrr" ] && hrr="false"
  found=$((found+1))
  echo "BUS_FILE=$hit"
  echo "BUS_FROM=$hfrom"
  echo "BUS_ID=$hid"
  echo "BUS_REPLY_REQUIRED=$hrr"
  [ -n "$hirt" ] && echo "BUS_IN_REPLY_TO=$hirt"
  echo "BUS_BODY_BEGIN"
  printf '%s\n' "$body"
  echo "BUS_BODY_END"
done
[ "$found" -eq 0 ] && echo "BUS_EMPTY"
exit 0
