#!/usr/bin/env bash
# bus-send.sh --to X --from Y (--body-file F | --body "...") [--reply] [--in-reply-to ID]
# Par Unix do bus-send.ps1: escreve um handoff com escrita atomica (tmp + mv) e token
# de auth. NAO TESTADO no Unix ainda -- validar.
set -u
bus_root="${CLAUDE_BUS_ROOT:-/tmp/claude-bus}"
to=""; from=""; body=""; bodyfile=""; reply="false"; inreply=""
while [ $# -gt 0 ]; do
  case "$1" in
    --to) to="$2"; shift 2;;
    --from) from="$2"; shift 2;;
    --body) body="$2"; shift 2;;
    --body-file) bodyfile="$2"; shift 2;;
    --reply) reply="true"; shift;;
    --in-reply-to) inreply="$2"; shift 2;;
    *) shift;;
  esac
done

[ -n "$to" ] && [ -n "$from" ] || { echo "uso: bus-send.sh --to X --from Y (--body-file F | --body ...) [--reply] [--in-reply-to ID]" >&2; exit 1; }
[ -n "$bodyfile" ] && [ -f "$bodyfile" ] && body="$(cat "$bodyfile")"
[ -n "$body" ] || { echo "corpo vazio: passe --body ou --body-file" >&2; exit 1; }

# segredo compartilhado (get-or-create; mv -n evita corrida na 1a criacao)
mkdir -p "$bus_root"
secret_file="$bus_root/.bus-secret"
if [ ! -f "$secret_file" ]; then
  if command -v openssl >/dev/null 2>&1; then s="$(openssl rand -hex 32)"
  else s="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"; fi
  tmpsec="$secret_file.$$.tmp"; printf '%s' "$s" > "$tmpsec"
  mv -n "$tmpsec" "$secret_file" 2>/dev/null || true
  [ -f "$tmpsec" ] && rm -f "$tmpsec"
fi
secret="$(tr -d ' \r\n' < "$secret_file")"

inbox="$bus_root/inbox"; mkdir -p "$inbox"
id="$(date +%Y%m%d-%H%M%S)-$(head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')"
final="$inbox/to-${to}__from-${from}__${id}.handoff"
tmp="$final.tmp"

{
  printf '###BUS-START\n'
  printf 'id: %s\n' "$id"
  printf 'from: %s\n' "$from"
  printf 'to: %s\n' "$to"
  printf 'auth: %s\n' "$secret"
  printf 'reply_required: %s\n' "$reply"
  printf 'in_reply_to: %s\n' "$inreply"
  printf -- '---\n'
  printf '%s\n' "$body"
  printf '###BUS-END\n'
} > "$tmp"
mv "$tmp" "$final"   # rename atomico no mesmo filesystem

echo "SENT=$final"
echo "ID=$id"
