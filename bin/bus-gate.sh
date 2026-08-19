#!/usr/bin/env bash
# bus-gate.sh -- Hook UserPromptSubmit do BUS (par Unix do bus-gate.ps1). Gate PRE-API do /bus.
# Le o JSON do stdin (campos prompt, session_id). Lock POR PROJETO (<projeto>/.bus-lock):
# serializa DENTRO do projeto; projetos diferentes rodam em PARALELO. Tambem intercepta
# /bus-message (enfileira instrucao do operador SEM acordar o modelo) e a PAUSA por projeto.
# Regras (so para prompt que comeca com /bus; o resto passa direto):
#   - lock global tomado por OUTRA sessao (fresco)         -> BLOQUEIA (defer, custo 0)
#   - inbox tem handoff pendente pra mim                   -> acquire lock + exit 0
#   - inbox vazia e seen velho (>3h, possivel pos-restart) -> exit 0 (deixa re-armar o cron)
#   - inbox vazia e seen fresco                            -> BLOQUEIA (skip de graca)
# Sempre regrava seen/<sid> (prova de vida pro dashboard). Fail-open: erro -> exit 0.
# O acquire do lock e ATOMICO (noclobber/O_EXCL, par do CreateNew/FileShare.None do .ps1).
# Demais partes best-effort no Unix -- validar (parsing JSON via sed assume prompts simples;
# o lock guarda exp_epoch p/ comparacao numerica e expiry ISO p/ o dashboard).
SEEN_STALE_MIN=180
LEASE_MIN=60      # auto-libera o lock se a sessao travar/cair (o dashboard mostra o restante)

# Forense: acquire/steal/defer-race vao pra <base>/.bus-gate.log (best-effort, nunca quebra).
# (Bash nao tem o fail-open por-excecao do .ps1: aqui um erro nao vira "exit 0 sem lock" -- o
# fluxo so segue, e o acquire ja e atomico via noclobber. Logo nao ha catch a blindar.)
bus_block() {   # $1 = mensagem OPCIONAL (vai no stopReason)
  # BLOQUEIA o prompt sem sujar a conversa. Par do BusBlock do .ps1. Medido no app 2026-08-12:
  # exit 2 gera card PERMANENTE (com a linha de comando); {"continue":false} so um aviso
  # TRANSITORIO. Os dois bloqueiam igual -- custo ZERO de API (o modelo NAO acorda).
  # Com mensagem = aviso com texto (so onde o operador espera retorno); sem = mudo.
  if [ -n "${1:-}" ]; then
    m=$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')
    printf '{"continue":false,"stopReason":"%s"}\n' "$m"
  else
    # SEM mensagem = defer automatico -> decision:block, que APAGA o prompt E a injecao da SKILL.
    # (continue:false nao apaga: a skill ja entrou no historico antes de o hook decidir. Medido
    # em 12/08/2026: 353 injecoes numa sessao com ZERO acquires. Ver bus-gate.ps1 p/ os numeros.)
    printf '{"continue":false}\n'
  fi
  exit 0
}

buslog() {  # $1=base $2=sid $3=slug $4=decision
  lf="$1/.bus-gate.log"
  { [ -f "$lf" ] && [ "$(wc -c < "$lf" 2>/dev/null || echo 0)" -gt 524288 ] && : > "$lf"; } 2>/dev/null
  printf '%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null)" "$4" "$(printf '%s' "$2" | cut -c1-8)" "$3" >> "$lf" 2>/dev/null || true
}

# /bus-message: escreve um handoff operador->proprio-slug no inbox do projeto da sessao.
# Ecoa 'OK:<slug>:<projeto>' ou 'NO_SID'/'NO_IDENTITY'.
enqueue_op_message() {  # $1=base $2=sid $3=body
  b="$1"; s="$2"; body="$3"
  [ -n "$s" ] || { echo "NO_SID"; return; }
  nf="$b/names/$s.txt"
  [ -f "$nf" ] || { echo "NO_IDENTITY"; return; }
  l2="$(sed -n '2p' "$nf" | tr -d '[:space:]')"
  if [ -n "$l2" ]; then proj="$(sed -n '1p' "$nf" | tr -d '[:space:]')"; slug="$l2"; else proj="default"; slug="$(sed -n '1p' "$nf" | tr -d '[:space:]')"; fi
  [ -n "$slug" ] || { echo "NO_IDENTITY"; return; }
  if [ "$proj" != "default" ]; then proot="$b/$proj"; else proot="$b"; fi
  sf="$proot/.bus-secret"; mkdir -p "$proot"
  if [ ! -f "$sf" ]; then
    if command -v openssl >/dev/null 2>&1; then sec="$(openssl rand -hex 32)"; else sec="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"; fi
    tsf="$sf.$$.tmp"; printf '%s' "$sec" > "$tsf"; mv -n "$tsf" "$sf" 2>/dev/null || true; [ -f "$tsf" ] && rm -f "$tsf"
  fi
  secret="$(tr -d ' \r\n' < "$sf")"
  inbox="$proot/inbox"; mkdir -p "$inbox"
  id="$(date '+%Y%m%d-%H%M%S')-$(od -An -N3 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || printf '%06d' $$)"
  final="$inbox/to-${slug}__from-operador__${id}.handoff"; tmp="$final.tmp"
  printf '###BUS-START\nid: %s\nfrom: operador\nto: %s\nauth: %s\nreply_required: false\nin_reply_to: \n---\n%s\n###BUS-END\n' "$id" "$slug" "$secret" "$body" > "$tmp"
  mv -f "$tmp" "$final"
  echo "OK:$slug:$proj"
}

main() {
  raw="$(cat)"
  prompt="$(printf '%s' "$raw" | sed -n 's/.*"prompt"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  sid="$(printf '%s' "$raw" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"

  # 0. /bus-message <texto>: o operador enfileira uma instrucao pro proprio especialista da
  # sessao. O HOOK escreve o handoff (operador->slug) e BLOQUEIA (bus_block) -> NAO acorda o modelo,
  # custo ZERO. (O parsing de JSON aqui e simples -- mensagem de 1 linha; o par .ps1 aceita multi.)
  if [[ "$prompt" =~ ^[[:space:]]*/bus-message[[:space:]]+(.+)$ ]]; then
    bm_msg="${BASH_REMATCH[1]}"
    bm_base="${CLAUDE_BUS_ROOT:-/tmp/claude-bus}"
    r="$(enqueue_op_message "$bm_base" "$sid" "$bm_msg")"
    case "$r" in
      OK:*) pp="${r#OK:}"; ps="${pp%%:*}"; pj="${pp#*:}"; buslog "$bm_base" "$sid" "$ps" "op-message"; bus_block "BUS: mensagem enfileirada para $ps ($pj) -- sera processada no proximo /bus.";;
      *) bus_block "BUS: esta sessao ainda nao se registrou no BUS -- rode /bus <projeto> <slug> primeiro, depois /bus-message.";;
    esac
    bus_block
  fi

  # 1. so gateia /bus; qualquer outro prompt passa (fast-path)
  # Gateia /bus (manual) E o TIQUE do cron (texto puro). Slash command EXPANDE a skill na
  # submissao, ANTES do hook -- por isso o tique deixou de ser "/bus". Ver bus-gate.ps1 passo 1.
  [[ "$prompt" =~ ^[[:space:]]*(/bus([[:space:]]|$)|bus-tick) ]] || exit 0
  [ -n "$sid" ] || exit 0

  base="${CLAUDE_BUS_ROOT:-/tmp/claude-bus}"

  # 2a. CRON vs MANUAL: o cron dispara bare "/bus" (sem args). Qualquer "/bus <args>" e
  # chamada MANUAL -> deve RODAR (acquire+run, serializado pelo lock), nao deferir em inbox
  # vazio. Se traz prioridade (3o arg), grava .priority PRE-API (manual c/ prioridade SEMPRE seta).
  ismanual=0
  set -- $prompt
  [ "$1" = "/bus" ] && [ -n "$2" ] && ismanual=1
  if [ "$1" = "/bus" ] && [ -n "$2" ] && [ -n "$3" ] && [ -n "$4" ] && [ -z "$5" ] && printf '%s' "$4" | grep -qE '^[0-9]+$'; then
    pproj="$2"; pslug="$3"; pprio="$4"   # ORDEM: PROJETO primeiro (v0.7.0)
    if [ "$pproj" = "default" ]; then proot="$base"; else proot="$base/$pproj"; fi
    mkdir -p "$proot"; pf="$proot/.priority"; tmp="$pf.$$.tmp"
    : > "$tmp"
    [ -f "$pf" ] && grep -v "^[[:space:]]*$pslug[[:space:]]*:" "$pf" >> "$tmp" 2>/dev/null
    printf '%s:%s\n' "$pslug" "$pprio" >> "$tmp"
    mv -f "$tmp" "$pf"
  fi

  namefile="$base/names/$sid.txt"
  [ -f "$namefile" ] || exit 0
  project="$(sed -n '1p' "$namefile" | tr -d ' \r\n')"
  slug="$(sed -n '2p' "$namefile" | tr -d ' \r\n')"
  if [ -z "$slug" ]; then slug="$project"; project="default"; fi   # 1 linha = so slug
  [ -n "$slug" ] || exit 0
  # raiz do projeto (lock POR PROJETO, pausa e prioridades)
  if [ -n "$project" ] && [ "$project" != "default" ]; then projroot="$base/$project"; else projroot="$base"; fi

  # 2. seen: idade antiga, depois regrava agora (prova de vida)
  seendir="$base/seen"; mkdir -p "$seendir"
  seenfile="$seendir/$sid"
  now=$(date +%s)
  seen_age_min=999999
  if [ -f "$seenfile" ]; then
    m=$(date -r "$seenfile" +%s 2>/dev/null || stat -c %Y "$seenfile" 2>/dev/null || echo "$now")
    seen_age_min=$(( (now - m) / 60 ))
  fi
  echo "$now" > "$seenfile"

  # 3a. MANUTENCAO da estrutura (pre-API, zero trabalho do modelo). O BUS vive em /tmp (Unix) /
  # %TEMP% (Win), limpos por IDADE. Garante as pastas (recria as que sumirem) e RENOVA o mtime de
  # .bus-secret/names/.priority/pastas -> nao envelhecem, nao sao apagados (secret nao rotaciona,
  # sessao nao perde registro/prioridade, modelo nao reconstroi estrutura).
  # CONCORRENCIA (~20 especialistas/projeto tocando os MESMOS arquivos): so toca o que ja envelheceu
  # (mtime > 6h); quase todo tique so LE o mtime (barato, sem contencao); o toque real (escrita) sai
  # ~4x/dia por projeto. Storage Sense limpa por DIAS, entao 6h e folgado. touch so mexe no mtime.
  mroot="$projroot"
  for d in inbox processing done rejected; do [ -d "$mroot/$d" ] || mkdir -p "$mroot/$d" 2>/dev/null; done
  mcut=$(( now - 6*3600 ))
  for mp in "$mroot/.bus-secret" "$mroot/.priority" "$mroot/.bus-paused" "$base/.bus-cron-interval" "$namefile" "$mroot/inbox" "$mroot/processing" "$mroot/done" "$mroot/rejected"; do
    if [ -e "$mp" ]; then
      mmt=$(date -r "$mp" +%s 2>/dev/null || stat -c %Y "$mp" 2>/dev/null || echo 0)
      [ "$mmt" -lt "$mcut" ] 2>/dev/null && touch "$mp" 2>/dev/null
    fi
  done

  # 3b. CHAMADA MANUAL (/bus <args>) = CONFIG, NAO processa. Passa direto (exit 0): o modelo
  # so registra/seta prioridade/re-arma e PARA (sem ler o inbox). Nao usa o lock (config nao
  # serializa). A prioridade do 3o arg ja foi gravada no 2a. SO o BARE /bus processa o inbox.
  [ "$ismanual" = "1" ] && exit 0

  # 3c. PAUSA por projeto: se <projeto>/.bus-paused existe -> nao pega NOVOS handoffs (defer).
  # Quem ja processa (segurando o lock) termina o turno; so os PROXIMOS ticks deferem. Config e
  # /bus-message ja passaram antes daqui.
  if [ -e "$projroot/.bus-paused" ]; then
    buslog "$base" "$sid" "$slug" "defer-paused"
    bus_block
  fi

  # 3. SLOTS DE LOCK POR PROJETO. Capacidade em <projeto>/.bus-slots (1..3, default 1 =
  # comportamento classico). O slot 1 mantem o nome '.bus-lock' DE PROPOSITO: gate antigo so
  # conhece esse arquivo, disputa o slot 1 e ignora os outros -- migracao em lote sem corromper.
  slot_cap=1
  sv="$(cat "$projroot/.bus-slots" 2>/dev/null | tr -dc '0-9')"
  [ -n "$sv" ] && [ "$sv" -ge 1 ] 2>/dev/null && [ "$sv" -le 3 ] 2>/dev/null && slot_cap="$sv"
  slot_files=""
  i=1
  while [ "$i" -le "$slot_cap" ]; do
    if [ "$i" = "1" ]; then slot_files="$projroot/.bus-lock"; else slot_files="$slot_files $projroot/.bus-lock-$i"; fi
    i=$((i+1))
  done
  # LIVRE = nao existe, expirou, e meu sid, ou traz o MEU slug com sid velho (auto-cura do
  # /clear: o slug e exclusivo, entao aquele lock so pode ser encarnacao anterior de mim).
  free_slots=0; holder_slug=""; sid_trocado=0
  for lk in $slot_files; do
    if [ ! -f "$lk" ]; then free_slots=$((free_slots+1)); continue; fi
    lexp="$(sed -n 's/.*"exp_epoch":\([0-9]*\).*/\1/p' "$lk")"
    lsid="$(sed -n 's/.*"sid":"\([^"]*\)".*/\1/p' "$lk")"
    lslug="$(sed -n 's/.*"slug":"\([^"]*\)".*/\1/p' "$lk")"
    if [ -z "$lexp" ] || [ "$now" -ge "$lexp" ] || [ "$lsid" = "$sid" ] || [ "$lslug" = "$slug" ]; then
      free_slots=$((free_slots+1))
      [ "$lslug" = "$slug" ] && [ "$lsid" != "$sid" ] && sid_trocado=1
    elif [ -z "$holder_slug" ]; then holder_slug="$lslug"
    fi
  done
  [ "$sid_trocado" = "1" ] && buslog "$base" "$sid" "$slug" "lock-sid-trocado"
  if [ "$free_slots" -eq 0 ]; then
    buslog "$base" "$sid" "$slug" "defer-lock>$holder_slug"
    bus_block
  fi

  # 4. PRIORIDADES do projeto: arquivo <projroot>/.priority, linhas "slug:N" (default 1000;
  # quanto MENOR, mais cede a vez). ($projroot ja resolvido acima.)
  priofile="$projroot/.priority"
  getprio() {   # $1 = slug -> imprime a prioridade (default 1000)
    if [ -f "$priofile" ]; then
      v="$(sed -n "s/^[[:space:]]*$1[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" "$priofile" | head -n1)"
      [ -n "$v" ] && { echo "$v"; return; }
    fi
    echo 1000
  }
  myprio="$(getprio "$slug")"

  # varre o inbox: eu tenho pendente? e algum especialista de prioridade MAIOR tem?
  # FYI (kind: fyi) NAO acorda ninguem: nao conta como pendente NEM na cessao de vez por
  # prioridade (senao um fyi pra alguem de prioridade maior faria todos cederem a vez pra um
  # fantasma). Sai de carona no proximo wake real do destino. ENVELHECE em FYI_WAKE_MIN, senao
  # fyi pra quem ficou ocioso nunca seria entregue e o remetente acharia que avisou.
  FYI_WAKE_MIN=240
  inbox="$projroot/inbox"
  mypending=0; higherpending=0; higherslug=""; higher_slugs=""
  if [ -d "$inbox" ]; then
    for f in "$inbox"/to-*.handoff; do
      [ -e "$f" ] || continue
      grep -q '###BUS-END' "$f" 2>/dev/null || continue
      if grep -qE '^kind:[[:space:]]*fyi[[:space:]]*$' "$f" 2>/dev/null; then
        fm=$(date -r "$f" +%s 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)
        [ $(( (now - fm) / 60 )) -lt "$FYI_WAKE_MIN" ] && continue
      fi
      bn="$(basename "$f")"; toslug="${bn#to-}"; toslug="${toslug%%__*}"   # entre 'to-' e o 1o '__'
      if [ "$toslug" = "$slug" ]; then mypending=1
      elif [ -n "$toslug" ]; then
        xp="$(getprio "$toslug")"
        # Acumula os DISTINTOS de prioridade maior com pendencia: e quantas vagas precisam
        # sobrar pra eles (ver 4b). Varios handoffs pro mesmo slug = 1 vaga so.
        if [ "$xp" -gt "$myprio" ] 2>/dev/null; then
          higherpending=1; [ -z "$higherslug" ] && higherslug="$toslug"
          case ",$higher_slugs," in *",$toslug,"*) ;; *) higher_slugs="${higher_slugs:+$higher_slugs,}$toslug";; esac
        fi
      fi
    done
  fi

  # 4b. PRIORIDADE: cedo a vez (defiro) se EU tenho trabalho e existe handoff p/ alguem de
  # prioridade MAIOR. Igual/menor nao bloqueia. So vale quando EU tenho trabalho.
  # CEDO A VEZ se as vagas livres NAO COBREM todos os de prioridade maior com pendencia.
  # A 1a versao olhava so "sobrou mais de uma vaga? nao cedo" -- ERRADO: presume que a vaga fica
  # RESERVADA ate o outro acordar, e nao fica (cada um tica no seu minuto, quem chega leva).
  # Medido: process-reviewer (prio 10) pegou vaga, outro pegou a segunda 11s depois, e o
  # dev-frontend -- a quem os dois deviam ceder -- so entrou 2 MINUTOS depois. Ver .ps1.
  higher_count=0
  [ -n "$higher_slugs" ] && higher_count=$(printf '%s' "$higher_slugs" | tr ',' '\n' | grep -c .)
  if [ "$mypending" = "1" ] && [ "$higherpending" = "1" ] && [ "$free_slots" -le "$higher_count" ]; then
    buslog "$base" "$sid" "$slug" "defer-prio>$higherslug"
    bus_block
  fi

  if [ "$mypending" = "1" ]; then   # bare /bus com trabalho -> processa (serializado pelo lock)
    exp=$(( now + LEASE_MIN * 60 ))
    iso_now="$(date -d "@$now" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date -r "$now" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || echo "$now")"
    iso_exp="$(date -d "@$exp" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date -r "$exp" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || echo "$exp")"
    obj="{\"sid\":\"$sid\",\"slug\":\"$slug\",\"project\":\"$project\",\"since\":\"$iso_now\",\"expiry\":\"$iso_exp\",\"exp_epoch\":$exp}"
    # Percorre os slots ate conseguir um. acquire ATOMICO: noclobber faz '>' usar O_EXCL (cria so
    # se nao existir, sem TOCTOU) -- par do CreateNew/FileShare.None do .ps1, e e o que torna N
    # slots seguro sem nenhum outro mecanismo.
    for lock in $slot_files; do
      if ( set -o noclobber; printf '%s' "$obj" > "$lock" ) 2>/dev/null; then
        buslog "$base" "$sid" "$slug" acquire
        exit 0
      fi
      # ja existe: rouba se for MEU sid, se EXPIROU, ou se for o MEU SLUG com sid velho (sessao
      # anterior morta por /clear -- o slug e exclusivo, entao aquele lock so pode ser meu).
      lexp="$(sed -n 's/.*"exp_epoch":\([0-9]*\).*/\1/p' "$lock")"
      lsid="$(sed -n 's/.*"sid":"\([^"]*\)".*/\1/p' "$lock")"
      lslug="$(sed -n 's/.*"slug":"\([^"]*\)".*/\1/p' "$lock")"
      if [ "$lsid" = "$sid" ] || { [ -n "$lexp" ] && [ "$now" -ge "$lexp" ]; } || [ "$lslug" = "$slug" ]; then
        how=acquire-steal
        [ "$lslug" = "$slug" ] && [ "$lsid" != "$sid" ] && how=acquire-sid-trocado
        printf '%s' "$obj" > "$lock"; buslog "$base" "$sid" "$slug" "$how"; exit 0
      fi
    done
    buslog "$base" "$sid" "$slug" defer-race
    bus_block
  fi

  # 5. inbox vazia -- so chega aqui o BARE /bus sem trabalho (manual/config ja saiu no 3b)
  if [ "$seen_age_min" -gt "$SEEN_STALE_MIN" ]; then exit 0; fi
  # SILENCIOSO: tick ocioso e o caso MAIS comum -- stderr aqui virava um card por tick no app.
  bus_block
}
main
exit 0
