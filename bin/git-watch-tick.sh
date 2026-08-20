#!/usr/bin/env bash
# git-watch-tick.sh --repo <owner/repo> --project <projeto> [--ghconf <dir>] [--commit]
#
# UMA passada do vigia de issues do /bus-git-watch: le o GitHub, compara com o baseline em
# disco e sai. Sem laco, sem sleep, ~2s -- e o que permite a vigia ser um CRON em vez de uma
# tarefa de fundo. TAREFA DE FUNDO VIVA IMPEDE O TIQUE DO BUS DE CHEGAR NA SESSAO: medido em
# 20/08/2026 no rh-proxima, a sessao que segurava o monitor rodou 1 tique o dia inteiro
# enquanto os pares rodaram de 99 a 235 -- e some do BUS sem erro visivel, que e o pior modo
# de falha daqui.
#
# Saidas (o prompt do cron manda o modelo seguir isto):
#   GITWATCH_BASELINE_GRAVADO   1a vez: gravou o snapshot e nao ha o que comparar   exit 0
#   GITWATCH_SEM_NOVIDADE       nada mudou -- encerre calado                        exit 0
#   MUDOU_NO_GITHUB             + antes/agora + issues abertas + ultimo comentario  exit 0
#   GITWATCH_CEGO               nao conseguiu LER (auth/rate limit/404)             exit 2
#   GITWATCH_ERRO_USO           faltou --repo ou --project                          exit 1
#
# CEGO NAO E MUDANCA. Quando a API falha ela devolve um CORPO DE ERRO: nao-vazio e diferente
# do baseline. Comparar string crua faz isso virar "mudou" e dispara handoff sem evento nenhum
# -- aconteceu duas vezes em producao (conta do gh trocada por outra sessao; 404 transitorio).
# Por isso snap() VALIDA O PROPRIO FORMATO e falha com return 1 em vez de devolver lixo.
#
# O baseline NAO e atualizado sozinho quando muda: quem fecha o ciclo e o modelo, com --commit,
# DEPOIS de processar os eventos. Se o script avancasse o baseline no ato, um evento processado
# pela metade (turno morto, /clear no meio) sumiria do radar pra sempre.
set -u

repo=""; project=""; ghconf=""; commit=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)    repo="$2"; shift 2;;
    --project) project="$2"; shift 2;;
    --ghconf)  ghconf="$2"; shift 2;;
    --commit)  commit=1; shift;;
    *) shift;;
  esac
done
if [ -z "$repo" ] || [ -z "$project" ]; then
  echo "GITWATCH_ERRO_USO: use --repo <owner/repo> --project <projeto>"; exit 1
fi

base="${CLAUDE_BUS_ROOT:-/tmp/claude-bus}"
if [ "$project" = "default" ]; then projroot="$base"; else projroot="$base/$project"; fi
mkdir -p "$projroot" 2>/dev/null

# CONTA ISOLADA DO gh (passo 2 da skill): nunca 'gh auth switch', que reescreve o hosts.yml
# GLOBAL e troca a conta de todas as sessoes. Aqui so apontamos o GH_CONFIG_DIR pra copia do
# projeto, se ela existir; senao vale a conta global do ambiente.
[ -z "$ghconf" ] && ghconf="$projroot/ghconf"
[ -d "$ghconf" ] && export GH_CONFIG_DIR="$ghconf"

slug=$(printf '%s' "$repo" | tr '/' '-')
basefile="$projroot/.git-watch-$slug.base"

snap() {
  local issues cid
  # LIMITE 200: acima disso o gh corta pelos mais RECENTES e uma issue velha sai do snapshot
  # sozinha. Repo passando de 200 issues: suba aqui e refaca o baseline (--commit).
  issues=$(gh issue list --repo "$repo" --state all --limit 200 --json number,state -q '.[] | "\(.number):\(.state)"' 2>/dev/null | sort | tr '\n' ' ')
  cid=$(gh api "repos/$repo/issues/comments" --paginate -q '.[].id' 2>/dev/null | sort -n | tail -1)
  # Repo SEM issue nenhuma e legitimo (issues="") -- mas ai o cid tambem tem de estar vazio.
  # Qualquer outra coisa que nao case com "<n>:<ESTADO> " repetido e resposta de erro: cego.
  if [ -n "$issues" ]; then
    echo "$issues" | grep -qE '^([0-9]+:[A-Z]+ )+$' || return 1
  fi
  [ -z "$cid" ] || echo "$cid" | grep -qE '^[0-9]+$' || return 1
  printf '%s%s' "$issues" "$cid"
}

CUR=$(snap) || { echo "GITWATCH_CEGO: leitura invalida -- ISTO NAO E MUDANCA."; echo "Confira a ferramenta antes de concluir: gh auth status / gh api rate_limit (GH_CONFIG_DIR=${GH_CONFIG_DIR:-global})."; exit 2; }

echo "GITWATCH_REPO=$repo"
echo "GITWATCH_BASE_FILE=$basefile"

if [ "$commit" = "1" ]; then
  printf '%s' "$CUR" > "$basefile"
  echo "GITWATCH_BASELINE_ATUALIZADO"
  echo "agora: $CUR"
  exit 0
fi

if [ ! -f "$basefile" ]; then
  printf '%s' "$CUR" > "$basefile"
  echo "GITWATCH_BASELINE_GRAVADO"
  echo "agora: $CUR"
  exit 0
fi

BASE=$(cat "$basefile")
if [ "$CUR" = "$BASE" ]; then
  echo "GITWATCH_SEM_NOVIDADE"
  exit 0
fi

echo "MUDOU_NO_GITHUB"
echo "antes: $BASE"
echo "agora: $CUR"
echo "--- issues abertas ---"
gh issue list --repo "$repo" --state open --json number,title,updatedAt -q '.[] | "#\(.number) \(.title) (atualizada \(.updatedAt))"' 2>/dev/null
echo "--- ultimo comentario ---"
gh api "repos/$repo/issues/comments" --paginate -q 'max_by(.id) | "issue \(.issue_url | split("/") | last) por \(.user.login): \(.body[0:500])"' 2>/dev/null
echo "--- fim ---"
echo "So depois de despachar os handoffs e atualizar o estado: rode de novo com --commit."
exit 0
