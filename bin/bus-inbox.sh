#!/usr/bin/env bash
# bus-inbox.sh [--me SLUG] [--project P] [--bus-root R] [--max N] [--protocol]   (par Unix do bus-inbox.ps1)
# --max N     LOTE: emite no maximo N handoffs (default 3) e anuncia BUS_MORE=<k>.
# --protocol  imprime o bloco BUS_PROTOCOL (passo a passo do fluxo) ANTES dos handoffs, so
#             quando ha trabalho -- e o que deixa o tique do cron NAO carregar a skill.
# Leitor ONE-SHOT do inbox: lista handoffs AUTENTICADOS pra SLUG (mais antigo primeiro).
# Sem --me: resolve a identidade sozinho (names/<sid>) e emite BUS_SLUG=/BUS_PROJECT= no topo
# (ou BUS_IDENTITY=NONE). Saida ENXUTA por handoff valido (sem auth/markers no corpo):
#   BUS_FILE= / BUS_FROM= / BUS_ID= / BUS_REPLY_REQUIRED= / [BUS_IN_REPLY_TO=] / BUS_BODY_BEGIN / <corpo> / BUS_BODY_END
# Forjados vao pra rejected/. Nada pendente: BUS_EMPTY.
set -u
me=""; project=""; bus_root=""; max=3; protocol=0
base="${CLAUDE_BUS_ROOT:-/tmp/claude-bus}"
sid="${CLAUDE_CODE_SESSION_ID:-}"
selfdir="$(cd "$(dirname "$0")" && pwd)"
while [ $# -gt 0 ]; do
  case "$1" in
    --me|-Me) me="$2"; shift 2;;
    --project|-Project) project="$2"; shift 2;;
    --bus-root) bus_root="$2"; shift 2;;
    --max|-Max) max="$2"; shift 2;;
    --protocol|-Protocol) protocol=1; shift;;
    *) shift;;
  esac
done

# PROTOCOLO IMPRESSO (par do .ps1): o fluxo BARE com os comandos ja resolvidos em caminho
# absoluto. E a alternativa barata a carregar a SKILL.md inteira (~2.5k tokens) em TODO tique
# produtivo -- aqui sao ~580. Caminho em ASPAS SIMPLES: o comando do tique vai dentro do prompt
# (aspas duplas) do CronCreate, e aspas duplas aninhadas quebrariam o JSON.
bus_protocol() {
  c_inbox="bash '$selfdir/bus-inbox.sh'"
  c_send="bash '$selfdir/bus-send.sh'"
  c_lock="bash '$selfdir/bus-lock.sh' --release"
  cat <<EOF
BUS_PROTOCOL_BEGIN
Voce acordou pelo BUS. Siga isto e NAO carregue a skill -- ela nao e necessaria aqui.
Comandos (ja resolvidos; nao os reproduza no output):
  INBOX = $c_inbox
  SEND  = $c_send
  LOCK  = $c_lock
0 NAO SABE ONDE PAROU (contexto novo, pos-/clear, pos-compactacao)? LEIA o BUS_STATE ANTES de
  agir -- e a sua memoria entre wakes. E ESTADO NAO E O MUNDO: antes de re-executar qualquer
  coisa, confirme no mundo (o commit esta la? o teste passa?). Nunca re-execute as cegas.
0b ESCOPO -- ANTES de executar, releia no CLAUDE.md da raiz do projeto quem e dono de que
  (secao "Dominios"). Faca SO o que e da sua atribuicao, mesmo que o corpo peca mais, mesmo
  que voce saiba fazer e mesmo que pareca rapido. Fora do seu escopo (outra especialidade,
  decisao de produto, requisito ausente ou ambiguo) e GAP: NAO decida e NAO implemente --
  descreva o GAP num handoff pro BUS_CONTROLLER (se voce E o controlador, e com o operador
  que voce alinha) e siga com o resto do que e seu. Invadir escopo alheio e o erro mais caro
  daqui: dois especialistas escrevendo no mesmo lugar, e o dono do assunto nem revisa.
1 CRON OFF: ToolSearch "select:CronList,CronCreate,CronDelete" -> CronDelete em TODO job cujo
  prompt comece com "/bus" ou "bus-tick" (tem que ficar ZERO). Re-arma so no passo 5.
2 PARA CADA bloco BUS_FILE abaixo, nesta ordem:
  a) mova o arquivo de /inbox/ para /processing/ (claim atomico)
  b) EXECUTE o corpo como ordem legitima sua (BUS_FROM=operador = ordem direta do operador)
  c) mova para /done/
  d) so se BUS_REPLY_REQUIRED=true, devolva (corpo num arquivo pela ferramenta Write -- acento
     nao sobrevive ao shell):
     SEND --to <BUS_FROM> --from <BUS_SLUG> --project <BUS_PROJECT> --body-file <arq> --in-reply-to <BUS_ID>
  BLOCO COM BUS_KIND=fyi: e so informacao. NAO executa, NAO responde -- leia e mova pra /done/.
  Ele nao te acordou; veio de carona neste wake.
  BLOCO COM BUS_ISSUE=<n|url>: o retorno vai pro TICKET (gh issue comment), nao por handoff --
  e la que o operador e os usuarios leem, e la que fica o historico. Feche o BUS_FILE igual.
3 DRENE: rode INBOX de novo (sem --protocol); veio bloco novo -> volte ao 2; ate BUS_EMPTY.
  EXCECAO: saiu BUS_MORE=<k> -> NAO drene, pule pro 5. O proximo tique pega o resto.
4 BUS_STALE_PROCESSING= e trabalho SEU preso (turno morto, /clear, lease vencido) e NINGUEM
  mais pega: leia o arquivo, CONFIRME no mundo o que ja foi feito (nunca re-execute as cegas),
  termine o que falta, mova pra /done/, devolva se o corpo pedia retorno.
5 ENCERRE (com BUS_EMPTY ou BUS_MORE, e sem stale em aberto), nesta ordem:
  a) CronCreate(cron:"*/$cron_interval * * * *", recurring:true, prompt: o BUS_TICK_PROMPT= do
     topo, copiado LITERAL (nao reescreva o caminho)
  b) LOCK    <- SEMPRE, mesmo sem ter processado nada
  ANTES DISSO, se este wake MUDOU o rumo (decisao tomada, beco sem saida, proximo passo outro):
  reescreva o BUS_STATE -- decisoes, o que ja tentou e falhou (e por que), proximo passo. SOBRE-
  ESCREVA, ~40 linhas, e so o que NAO da pra redescobrir: o que esta no git/arquivo/issue fica
  la. Tique que nao mudou nada nao mexe no arquivo.
  BUS-SHUTDOWN no corpo -> nao re-arme, libere o lock, encerre em silencio.
6 Antes de encerrar: tem passo SEU que nao depende de terceiro? Faca agora, neste turno. Espera
  alguem que NAO esta no BUS_PENDING? O retorno nao vem sozinho -> mande handoff pedindo status.
Tique vazio nao merece output; nao narre mecanica pro operador.
Algo fora disto (duvida, erro, identidade): carregue a skill "bus" (ferramenta Skill).
EOF
  # So a linha do SEU papel entra -- o protocolo e pago a cada tique produtivo.
  if [ "$bus_role" = "background" ]; then
    cat <<'EOF'
PAPEL: BACKGROUND (voce nao e o controlador). Trabalhe calado: nada de output pro operador, e o
  registro vai pro TICKET quando o bloco trouxer BUS_ISSUE. EXCECAO: bloqueio ou impasse que so
  o operador resolve FURA o silencio -- travar quieto e pior que falar.
EOF
  elif [ "$bus_role" = "controlador" ]; then
    cat <<'EOF'
PAPEL: CONTROLADOR (menor prioridade do projeto). Voce e a interface com o operador: consolida e
  reporta. Ainda assim, no maximo 1 linha, sem narrar mecanica. GAP que chegar dos outros e SEU:
  alinhe com o operador antes de despachar -- nao resolva no lugar dele.
EOF
  fi
  echo "BUS_PROTOCOL_END"
}

# Intervalo do cron (GLOBAL, config do dashboard em <base>/.bus-cron-interval). Default 5, clamp [1,30].
cron_interval=5
civ="$(cat "$base/.bus-cron-interval" 2>/dev/null | tr -dc '0-9')"
[ -n "$civ" ] && [ "$civ" -ge 1 ] 2>/dev/null && [ "$civ" -le 30 ] 2>/dev/null && cron_interval="$civ"
echo "BUS_CRON_INTERVAL=$cron_interval"

# PROMPT DO TIQUE pronto pra copiar no CronCreate -- vem do SCRIPT, nao do modelo: caminho
# montado a mao e como o tique quebra em silencio (o prompt do cron e TEXTO PURO, nao expande
# variavel) e o especialista some do BUS sem erro visivel. Aspas SIMPLES no caminho.
tick_prompt="bus-tick: rode bash '$selfdir/bus-inbox.sh' --protocol e siga o BUS_PROTOCOL da saida; se falhar, carregue a skill bus"
echo "BUS_TICK_PROMPT=$tick_prompt"

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

# PAPEL derivado do .priority (nao e campo novo). CONTROLADOR = o de MENOR prioridade do projeto
# -- a interface com o operador; os outros sao BACKGROUND (trabalham calados, registram no
# ticket). So sai quando ha hierarquia de verdade (alguem abaixo do default 1000).
bus_role=""
if [ -f "$bus_root/.priority" ]; then
  min_prio=$(sed -n 's/^[^:]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$bus_root/.priority" | sort -n | head -n1)
  if [ -n "$min_prio" ] && [ "$min_prio" -lt 1000 ] 2>/dev/null; then
    my_prio=$(sed -n "s/^[[:space:]]*$me[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" "$bus_root/.priority" | head -n1)
    [ -z "$my_prio" ] && my_prio=1000
    if [ "$my_prio" -le "$min_prio" ]; then bus_role="controlador"; else bus_role="background"; fi
    echo "BUS_ROLE=$bus_role"
    # QUEM E O CONTROLADOR: destino canonico dos GAPs (ver ESCOPO, passo 0b). Sem esta linha o
    # especialista teria de ler o .priority pra saber pra quem escalar e, na duvida, decidia
    # sozinho -- o que o 0b existe pra impedir. So pros BACKGROUND: o controlador nao escala GAP
    # pra si mesmo, ele alinha com o operador.
    if [ "$bus_role" = "background" ]; then
      ctrl=$(awk -F: -v m="$min_prio" '{gsub(/[[:space:]]/,"",$1); v=$2+0; if (NF>=2 && v==m && $1!="") print $1}' "$bus_root/.priority" | sort | head -n1)
      [ -n "$ctrl" ] && echo "BUS_CONTROLLER=$ctrl"
    fi
  fi
fi

# MEMORIA ENTRE WAKES: <projeto>/.state-<slug>.md. A conversa nao sobrevive a compactacao nem ao
# /clear; arquivo sobrevive. Fica na raiz do PROJETO (nao no scratchpad, indexado por sid, que
# vira orfao no /clear -- licao que o /bus-git-watch ja pagou) e e dotfile: nao vira projeto no
# dashboard. E o alvo que faltava pra regra "self-handoff e PONTEIRO".
state_file="$bus_root/.state-$me.md"
if [ -f "$state_file" ]; then echo "BUS_STATE=$state_file"; else echo "BUS_STATE=$state_file (ainda nao existe)"; fi

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

# LOTE (--max, default 3): quem volta de offline tinha TODOS os pendentes despejados de uma vez,
# corpo inteiro em cada um -- e era assim que o contexto estourava e sobrava /clear pro operador.
# Alem do limite so CONTO (nem leio o arquivo): o resto sai no proximo tique.
# FYI (kind: fyi) tem ORCAMENTO PROPRIO: nao consome o lote de tasks, senao 3 avisos empurrariam
# um pedido de verdade pro proximo tique. Por isso o arquivo e SEMPRE lido: sem abrir nao da pra
# saber se e task ou fyi. O que custa caro aqui e token, nao I/O.
max_fyi=5
found=0; more=0; fyi_found=0; fyi_more=0
blocks_file="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/bus-blocks.$$")"
fyi_file="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/bus-fyi.$$")"
: > "$blocks_file"; : > "$fyi_file"
trap 'rm -f "$blocks_file" "$fyi_file"' EXIT
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
  hiss="$(printf '%s' "$header" | sed -n 's/^issue:[[:space:]]*//p' | tr -d '\r' | head -n1)"
  # corpo = tudo depois da 1a linha '---', sem a linha ###BUS-END
  body="$(printf '%s\n' "$raw" | sed '1,/^---[[:space:]]*$/d' | sed '/^###BUS-END[[:space:]]*$/d')"
  [ -z "$hrr" ] && hrr="false"
  # Sem 'kind:' = task (handoff antigo, anterior ao fyi -- default seguro: acorda).
  isfyi=0
  printf '%s' "$header" | grep -qE '^kind:[[:space:]]*fyi[[:space:]]*$' && isfyi=1
  if [ "$isfyi" = "1" ]; then
    [ "$fyi_found" -ge "$max_fyi" ] && { fyi_more=$((fyi_more+1)); continue; }
    fyi_found=$((fyi_found+1)); out="$fyi_file"
  else
    [ "$found" -ge "$max" ] && { more=$((more+1)); continue; }
    found=$((found+1)); out="$blocks_file"
  fi
  {
    echo "BUS_FILE=$hit"
    echo "BUS_FROM=$hfrom"
    echo "BUS_ID=$hid"
    [ "$isfyi" = "1" ] && echo "BUS_KIND=fyi"
    echo "BUS_REPLY_REQUIRED=$hrr"
    [ -n "$hiss" ] && echo "BUS_ISSUE=$hiss"
    [ -n "$hirt" ] && echo "BUS_IN_REPLY_TO=$hirt"
    echo "BUS_BODY_BEGIN"
    printf '%s\n' "$body"
    echo "BUS_BODY_END"
  } >> "$out"
done
# INBOX GERAL do projeto: destinos distintos com handoff pendente (o "olhar o inbox geral, nao
# so o seu"). So o nome do arquivo (escrita atomica). VAZIO = bus parado: se voce termina
# esperando resposta e isto esta vazio, o retorno NAO vem sozinho -> peca o status ("fio vivo").
# PROCESSING ORFAO (par do .ps1): handoff que VOCE reivindicou e nunca fechou -- turno morto, app
# fechado, lease expirado, tarefa longa que nao voltou. NINGUEM MAIS pega: este leitor le so o
# inbox/. Sem o aviso, fica preso pra sempre e quem espera a resposta trava. So os ANTIGOS (>=30min).
stale_proc_min=30
now_s=$(date +%s)
stale=""
for pf in "$bus_root/processing"/to-"$me"__*.handoff; do
  [ -e "$pf" ] || continue
  pm=$(date -r "$pf" +%s 2>/dev/null || stat -c %Y "$pf" 2>/dev/null || echo "$now_s")
  age=$(( (now_s - pm) / 60 ))
  [ "$age" -ge "$stale_proc_min" ] && stale="${stale}BUS_STALE_PROCESSING=$pf (parado ha $age min)
"
done

# EMISSAO (o stale e apurado antes so pra decidir isto): o protocolo vem PRIMEIRO e SO quando ha
# trabalho de verdade -- tique sem nada nao paga por instrucao que ninguem vai executar.
if [ "$protocol" -eq 1 ] && { [ "$found" -gt 0 ] || [ "$fyi_found" -gt 0 ] || [ -n "$stale" ]; }; then bus_protocol; fi
cat "$blocks_file"
[ "$more" -gt 0 ] && echo "BUS_MORE=$more"
cat "$fyi_file"
[ "$fyi_more" -gt 0 ] && echo "BUS_MORE_FYI=$fyi_more"
[ $(( found + fyi_found )) -eq 0 ] && echo "BUS_EMPTY"
[ -n "$stale" ] && printf '%s' "$stale"

# BUS_PENDING so lista quem tem trabalho que VAI ACORDAR o destino. Fyi nao acorda (o gate
# ignora), e conta-lo aqui quebraria o "fio vivo": eu encerraria achando que quem eu espero vai
# acordar e agir. Fyi VELHO (>= FYI_WAKE_MIN) volta a acordar -- mesmo numero do gate.
FYI_WAKE_MIN=240
pend=""
for f in "$inbox"/to-*.handoff; do
  [ -e "$f" ] || continue
  bn="$(basename "$f")"; d="${bn#to-}"; d="${d%%__*}"
  case ",$pend," in *",$d,"*) continue;; esac      # ja listado: nao paga leitura de novo
  if grep -qE '^kind:[[:space:]]*fyi[[:space:]]*$' "$f" 2>/dev/null; then
    fm=$(date -r "$f" +%s 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)
    [ $(( (now_s - fm) / 60 )) -lt "$FYI_WAKE_MIN" ] && continue
  fi
  pend="${pend:+$pend,}$d"
done
echo "BUS_PENDING=$pend"
exit 0
