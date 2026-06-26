#!/usr/bin/env bash
# bus-gate.sh -- Hook UserPromptSubmit do BUS (par Unix do bus-gate.ps1). Gate PRE-API do /bus.
# Le o JSON do stdin (campos prompt, session_id). Lock GLOBAL (1 por maquina; o limite de
# API e da CONTA Claude, nao do projeto: um trabalhando segura todos, de qualquer projeto).
# Regras (so para prompt que comeca com /bus; o resto passa direto):
#   - lock global tomado por OUTRA sessao (fresco)         -> exit 2 (defer, custo 0)
#   - inbox tem handoff pendente pra mim                   -> acquire lock + exit 0
#   - inbox vazia e seen velho (>3h, possivel pos-restart) -> exit 0 (deixa re-armar o cron)
#   - inbox vazia e seen fresco                            -> exit 2 (skip de graca)
# Sempre regrava seen/<sid> (prova de vida pro dashboard). Fail-open: erro -> exit 0.
# O acquire do lock e ATOMICO (noclobber/O_EXCL, par do CreateNew/FileShare.None do .ps1).
# Demais partes best-effort no Unix -- validar (parsing JSON via sed assume prompts simples;
# o lock guarda exp_epoch p/ comparacao numerica e expiry ISO p/ o dashboard).
SEEN_STALE_MIN=180
LEASE_MIN=30

main() {
  raw="$(cat)"
  prompt="$(printf '%s' "$raw" | sed -n 's/.*"prompt"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  sid="$(printf '%s' "$raw" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"

  # 1. so gateia /bus; qualquer outro prompt passa (fast-path)
  [[ "$prompt" =~ ^[[:space:]]*/bus([[:space:]]|$) ]] || exit 0
  [ -n "$sid" ] || exit 0

  base="${CLAUDE_BUS_ROOT:-/tmp/claude-bus}"
  namefile="$base/names/$sid.txt"
  [ -f "$namefile" ] || exit 0
  project="$(sed -n '1p' "$namefile" | tr -d ' \r\n')"
  slug="$(sed -n '2p' "$namefile" | tr -d ' \r\n')"
  if [ -z "$slug" ]; then slug="$project"; project="default"; fi   # 1 linha = so slug
  [ -n "$slug" ] || exit 0

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

  # 3. lock GLOBAL: tomado por outro e fresco -> defer
  lock="$base/.bus-lock"
  if [ -f "$lock" ]; then
    lexp="$(sed -n 's/.*"exp_epoch":\([0-9]*\).*/\1/p' "$lock")"
    lsid="$(sed -n 's/.*"sid":"\([^"]*\)".*/\1/p' "$lock")"
    if [ -n "$lexp" ] && [ "$now" -lt "$lexp" ] && [ "$lsid" != "$sid" ]; then
      echo 'BUS: outro especialista esta trabalhando (lock global) -- deferido.' >&2
      exit 2
    fi
  fi

  # 4. PRIORIDADES do projeto: arquivo <projroot>/.priority, linhas "slug:N" (default 1000;
  # quanto MENOR, mais cede a vez).
  projroot="$base"
  if [ -n "$project" ] && [ "$project" != "default" ]; then projroot="$base/$project"; fi
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
  inbox="$projroot/inbox"
  mypending=0; higherpending=0
  if [ -d "$inbox" ]; then
    for f in "$inbox"/to-*.handoff; do
      [ -e "$f" ] || continue
      grep -q '###BUS-END' "$f" 2>/dev/null || continue
      bn="$(basename "$f")"; toslug="${bn#to-}"; toslug="${toslug%%__*}"   # entre 'to-' e o 1o '__'
      if [ "$toslug" = "$slug" ]; then mypending=1
      elif [ -n "$toslug" ]; then
        xp="$(getprio "$toslug")"
        [ "$xp" -gt "$myprio" ] 2>/dev/null && higherpending=1
      fi
    done
  fi

  # 4b. PRIORIDADE: cedo a vez (defiro) se EU tenho trabalho e existe handoff p/ alguem de
  # prioridade MAIOR. Igual/menor nao bloqueia. So vale quando EU tenho trabalho.
  if [ "$mypending" = "1" ] && [ "$higherpending" = "1" ]; then
    echo 'BUS: prioridade menor -- ha handoff p/ especialista de prioridade maior; cedendo a vez.' >&2
    exit 2
  fi

  if [ "$mypending" = "1" ]; then
    exp=$(( now + LEASE_MIN * 60 ))
    iso_now="$(date -d "@$now" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date -r "$now" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || echo "$now")"
    iso_exp="$(date -d "@$exp" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date -r "$exp" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || echo "$exp")"
    obj="{\"sid\":\"$sid\",\"slug\":\"$slug\",\"project\":\"$project\",\"since\":\"$iso_now\",\"expiry\":\"$iso_exp\",\"exp_epoch\":$exp}"
    # acquire ATOMICO: noclobber faz '>' usar O_EXCL (cria so se nao existir, sem TOCTOU);
    # par do CreateNew/FileShare.None do .ps1.
    if ( set -o noclobber; printf '%s' "$obj" > "$lock" ) 2>/dev/null; then
      exit 0
    fi
    # ja existe: rouba so se for MEU ou EXPIRADO
    lexp="$(sed -n 's/.*"exp_epoch":\([0-9]*\).*/\1/p' "$lock")"
    lsid="$(sed -n 's/.*"sid":"\([^"]*\)".*/\1/p' "$lock")"
    if [ "$lsid" = "$sid" ] || { [ -n "$lexp" ] && [ "$now" -ge "$lexp" ]; }; then
      printf '%s' "$obj" > "$lock"; exit 0
    fi
    echo 'BUS: lock tomado na corrida -- deferido.' >&2
    exit 2
  fi

  # 5. inbox vazia
  if [ "$seen_age_min" -gt "$SEEN_STALE_MIN" ]; then exit 0; fi
  echo 'BUS: nada pendente -- pulando (cron segue armado, custo zero).' >&2
  exit 2
}
main
exit 0
