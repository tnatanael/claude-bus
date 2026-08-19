#!/usr/bin/env bash
# bus-send.sh --to X --from Y (--body-file F | --body "...") [--reply] [--in-reply-to ID]
# Par Unix do bus-send.ps1: escreve um handoff com escrita atomica (tmp + mv) e token
# de auth. NAO TESTADO no Unix ainda -- validar.
set -u
base="${CLAUDE_BUS_ROOT:-/tmp/claude-bus}"
to=""; from=""; body=""; bodyfile=""; reply="false"; inreply=""; project=""; bus_root=""; kind="task"; issue=""
while [ $# -gt 0 ]; do
  case "$1" in
    --to) to="$2"; shift 2;;
    --from) from="$2"; shift 2;;
    --body) body="$2"; shift 2;;
    --body-file) bodyfile="$2"; shift 2;;
    --reply) reply="true"; shift;;
    --fyi) kind="fyi"; shift;;
    --issue) issue="$2"; shift 2;;
    --in-reply-to) inreply="$2"; shift 2;;
    --project) project="$2"; shift 2;;
    --bus-root) bus_root="$2"; shift 2;;
    *) shift;;
  esac
done
# --fyi: handoff que NAO acorda o destino. Fica no inbox e vai de carona no proximo wake real
# dele -- que e quando a informacao ainda serve, porque so ai ele vai FAZER alguma coisa.
# Marcacao: tem algo a FAZER por causa disto? task. E so pra SABER? fyi. Na duvida, task.
if [ "$kind" = "fyi" ] && [ "$reply" = "true" ]; then
  echo "FYI_COM_REPLY: --fyi e --reply se contradizem (fyi nao acorda ninguem, a resposta nunca vem). Escolha um." >&2
  exit 1
fi
# Raiz: --bus-root explicito vence; senao base + projeto (subpasta, exceto 'default').
if [ -z "$bus_root" ]; then
  if [ -n "$project" ] && [ "$project" != "default" ]; then bus_root="$base/$project"; else bus_root="$base"; fi
fi

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
  printf 'kind: %s\n' "$kind"
  # --issue amarra o handoff a uma issue do GitHub: quem recebe responde NO TICKET, nao por
  # handoff de volta -- e la que o operador e os usuarios leem, e la fica o historico (o BUS
  # vive no /tmp e esquece). Na pratica quem preenche e o carteiro do /bus-git-watch.
  [ -n "$issue" ] && printf 'issue: %s\n' "$issue"
  printf 'in_reply_to: %s\n' "$inreply"
  printf -- '---\n'
  printf '%s\n' "$body"
  printf '###BUS-END\n'
} > "$tmp"
mv "$tmp" "$final"   # rename atomico no mesmo filesystem

echo "SENT=$final"
echo "ID=$id"

# AVISO DE CORPO INFLADO (nao bloqueia -- recusar jogaria fora trabalho ja feito). O valor e o
# laco de feedback DENTRO da sessao. Medido: self-handoff com 1835 bytes de media cujo corpo
# dizia "checkpoint em <arquivo>, leia dali" -- descrevendo um arquivo que ia ser aberto igual.
body_len=$(printf '%s' "$body" | wc -c | tr -d ' ')
if [ "$to" = "$from" ] && [ "$body_len" -gt 800 ]; then
  echo "BUS_BODY_WARN=self-handoff com $body_len bytes. Self-handoff e PONTEIRO: onde esta o checkpoint, qual o proximo passo, o que NAO refazer. O conteudo mora no arquivo de checkpoint."
elif [ "$body_len" -gt 4096 ]; then
  echo "BUS_BODY_WARN=corpo com $body_len bytes. Um spec completo pode passar disso; conteudo colado de arquivo/commit/issue, nao -- mande o caminho e o que olhar la."
fi
