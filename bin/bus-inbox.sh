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

# --- PROFUNDIDADE DA FRENTE (BUS_THREAD_DEPTH) ------------------------------------------
# Par do .ps1. POR QUE: um loop de investigacao entre 2-3 especialistas e INVISIVEL de dentro --
# cada rodada e localmente correta, mas o agregado vira desperdicio (caso real: 106 handoffs,
# 77% do trafego do dia, num defeito de impacto ZERO pro usuario). COMO: conta quantos handoffs
# os DOIS slugs trocaram nas ULTIMAS 24H nas 4 pastas, lendo SO O NOME (nao abre arquivo -- o
# done/ tem milhares). Limiar espelhado no SS5.1 da SKILL: mudou aqui, mude la.
THREAD_ALERT_AT=8
cut_ts="$(date -d '24 hours ago' '+%Y%m%d-%H%M%S' 2>/dev/null || date -v-24H '+%Y%m%d-%H%M%S' 2>/dev/null || echo '00000000-000000')"
pair_depth() {   # $1 = peer -> imprime quantos handoffs voce e ele trocaram nas ultimas 24h
  peer="$1"; n=0
  for fold in inbox processing done rejected; do
    for pf in "$bus_root/$fold"/to-*.handoff; do
      [ -e "$pf" ] || continue
      pbn="$(basename "$pf")"
      pto="${pbn#to-}"; pto="${pto%%__*}"
      prest="${pbn#*__from-}"; pfrom="${prest%%__*}"
      pid="${prest#*__}"; pts="${pid%%-*}-$(printf '%s' "${pid#*-}" | cut -c1-6)"
      case "$pto|$pfrom" in
        "$me|$peer"|"$peer|$me") ;;
        *) continue;;
      esac
      [ "$pts" \< "$cut_ts" ] && continue          # fora da janela de 24h
      n=$((n+1))
    done
  done
  echo "$n"
}

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
  depth="$(pair_depth "$hfrom")"
  [ -z "$depth" ] || [ "$depth" -lt 1 ] 2>/dev/null && depth=1
  echo "BUS_THREAD_DEPTH=$depth"
  # ALERTA so em frente entre ESPECIALISTAS (instrucao do operador nao e frente em loop).
  if [ "$hfrom" != "operador" ] && [ "$depth" -ge "$THREAD_ALERT_AT" ] 2>/dev/null; then
    echo "BUS_THREAD_ALERT=$hfrom:$depth -- PARE de aprofundar esta frente e peca alinhamento (SKILL SS5.1)"
  fi
  echo "BUS_BODY_BEGIN"
  printf '%s\n' "$body"
  echo "BUS_BODY_END"
done
[ "$found" -eq 0 ] && echo "BUS_EMPTY"
# INBOX GERAL do projeto: destinos distintos com handoff pendente (o "olhar o inbox geral, nao
# so o seu"). So o nome do arquivo (escrita atomica). VAZIO = bus parado: se voce termina
# esperando resposta e isto esta vazio, o retorno NAO vem sozinho -> peca o status ("fio vivo").
pend=""
for f in "$inbox"/to-*.handoff; do
  [ -e "$f" ] || continue
  bn="$(basename "$f")"; d="${bn#to-}"; d="${d%%__*}"
  case ",$pend," in *",$d,"*) ;; *) pend="${pend:+$pend,}$d";; esac
done
echo "BUS_PENDING=$pend"
exit 0
