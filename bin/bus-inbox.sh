#!/usr/bin/env bash
# bus-inbox.sh --me SLUG   (par Unix do bus-inbox.ps1)
# Leitor ONE-SHOT do inbox: lista handoffs AUTENTICADOS pra SLUG (mais antigo primeiro).
# Forjados vao pra rejected/. Saida por handoff valido:
#   BUS_FILE=<caminho> / BUS_BODY_BEGIN / <corpo> / BUS_BODY_END
# Nada pendente: BUS_EMPTY. Sem polling, sem background -- substitui o monitor no pull.
set -u
me=""; project=""; bus_root=""
base="${CLAUDE_BUS_ROOT:-/tmp/claude-bus}"
while [ $# -gt 0 ]; do
  case "$1" in
    --me|-Me) me="$2"; shift 2;;
    --project) project="$2"; shift 2;;
    --bus-root) bus_root="$2"; shift 2;;
    *) shift;;
  esac
done
[ -n "$me" ] || { echo "uso: bus-inbox.sh --me SLUG [--project P]" >&2; exit 1; }
# Raiz: --bus-root explicito vence; senao base + projeto (subpasta, exceto 'default').
if [ -z "$bus_root" ]; then
  if [ -n "$project" ] && [ "$project" != "default" ]; then bus_root="$base/$project"; else bus_root="$base"; fi
fi

# Marcador "visto por ultimo" na BASE (global): bus-inbox roda em todo /bus, mantem
# o "armado" do dashboard fresco mesmo se a IA pular o bus-name na religacao.
sid="${CLAUDE_CODE_SESSION_ID:-}"
[ -n "$sid" ] && { mkdir -p "$base/seen"; date +%s > "$base/seen/$sid"; }

inbox="$bus_root/inbox"; rejected="$bus_root/rejected"
mkdir -p "$inbox"
# segredo compartilhado (get-or-create; mv -n evita corrida na 1a criacao) -- mesmo bloco
# do bus-send.sh / paridade com o Get-BusSecret do bus-inbox.ps1.
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
