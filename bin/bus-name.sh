#!/usr/bin/env bash
# bus-name.sh [project] [slug] [priority]   (par Unix do bus-name.ps1)
# ORDEM: PROJETO primeiro, slug depois (v0.7.0 -- era slug/projeto ate a 0.6.x), igual ao
# comando do operador: /bus <projeto> <slug> [prioridade].
# Sem args: ecoa o registrado (PROJECT=/SLUG=) ou 'NONE'.
# Com args: grava (projeto OBRIGATORIO -> NEED_PROJECT; slug obrigatorio -> NEED_SLUG) e ecoa.
# Devolve INVERTED (+HINT) se o slug informado ja e um PROJETO e o projeto informado nao existe
# -- provavel ordem antiga; nao grava nada nesse caso.
# [priority] (>=0) faz upsert de "slug:N" no <projroot>/.priority (default 1000; menor cede mais).
# Compat: 1 linha antiga = projeto 'default'.
# names/ fica na raiz BASE (registro global); o isolamento por projeto e nas pastas de handoff.
set -u
bus_root="${CLAUDE_BUS_ROOT:-/tmp/claude-bus}"
sid="${CLAUDE_CODE_SESSION_ID:-}"
[ -z "$sid" ] && { echo "NONE"; exit 0; }
dir="$bus_root/names"; mkdir -p "$dir"
f="$dir/$sid.txt"

# "visto por ultimo": todo /bus passa por aqui -> regrava. O dashboard usa o frescor
# pra inferir se o cron da sessao esta REALMENTE armado (cron dispara /bus a cada 5 min).
seen_dir="$bus_root/seen"; mkdir -p "$seen_dir"
date +%s > "$seen_dir/$sid"

# Intervalo do cron (GLOBAL, config do dashboard em <base>/.bus-cron-interval). Default 5, clamp [1,30].
cron_interval=5
civ="$(cat "$bus_root/.bus-cron-interval" 2>/dev/null | tr -dc '0-9')"
[ -n "$civ" ] && [ "$civ" -ge 1 ] 2>/dev/null && [ "$civ" -le 30 ] 2>/dev/null && cron_interval="$civ"
# BUS_TICK_PROMPT: string EXATA do prompt do cron, montada pelo SCRIPT. O prompt do cron e
# texto puro (nao expande variavel) -- caminho montado pelo modelo quebra o tique em silencio.
selfdir="$(cd "$(dirname "$0")" && pwd)"
tick_prompt="bus-tick: rode bash '$selfdir/bus-inbox.sh' --protocol e siga o BUS_PROTOCOL da saida; se falhar, carregue a skill bus"
emit() { echo "PROJECT=$1"; echo "SLUG=$2"; echo "BUS_CRON_INTERVAL=$cron_interval"; echo "BUS_TICK_PROMPT=$tick_prompt"; }

# TRAVA ANTI-INVERSAO (ver cabecalho): o slug informado ja e um PROJETO e o projeto informado
# nao existe -> quase certamente teclaram a ordem antiga. Nao grava; devolve INVERTED.
is_project() {
  n="$1"
  [ -z "$n" ] && return 1
  case "$n" in names|seen|inbox|processing|done|rejected|presence|state) return 1;; esac
  [ -d "$bus_root/$n" ] && return 0
  for nf in "$dir"/*.txt; do
    [ -e "$nf" ] || continue
    [ -n "$(sed -n '2p' "$nf")" ] && [ "$(sed -n '1p' "$nf")" = "$n" ] && return 0
  done
  return 1
}

if [ -n "${1:-}" ]; then
  proj="$1"; slug="${2:-}"
  if [ "$proj" = "default" ]; then
    echo "NEED_PROJECT"   # projeto e OBRIGATORIO (o 'default' foi removido)
    exit 0
  fi
  if [ -z "$slug" ]; then
    echo "NEED_SLUG"      # /bus <projeto> <slug> -- faltou o slug
    exit 0
  fi
  if is_project "$slug" && ! is_project "$proj"; then
    echo "INVERTED"
    echo "HINT=a ordem e /bus <projeto> <slug>; \"$slug\" ja e um PROJETO. Voce quis /bus $slug $proj ?"
    exit 0
  fi
  printf '%s\n%s' "$proj" "$slug" > "$f"
  # EVICCAO DE GHOST: este (projeto, slug) agora e DESTA sessao. Apaga names/<outroSid> com o
  # MESMO (projeto, slug) + o seen dele -- sessao morta re-registrada NAO vira ghost no BUS.
  for nf in "$dir"/*.txt; do
    [ -e "$nf" ] || continue
    bn="$(basename "$nf" .txt)"; [ "$bn" = "$sid" ] && continue
    np="$(sed -n '1p' "$nf")"; ns="$(sed -n '2p' "$nf")"
    [ -z "$ns" ] && { ns="$np"; np="default"; }   # compat: 1 linha = slug, projeto default
    if [ "$np" = "$proj" ] && [ "$ns" = "$slug" ]; then rm -f "$nf" "$seen_dir/$bn"; fi
  done
  # LOCK ORFAO DO MESMO SLUG (auto-cura do /clear): a sessao ganha sid NOVO, mas o .bus-lock
  # ficou com o sid ANTIGO -> o -Release responde LOCK_NOT_MINE e o PROJETO fica preso ate o
  # lease. O slug e exclusivo (eviccao acima), entao lock em nome dele so pode ser meu.
  if [ "$proj" = "default" ]; then projroot_l="$bus_root"; else projroot_l="$bus_root/$proj"; fi
  # Varre TODOS os slots: o orfao pode estar em qualquer um deles.
  for lock_l in "$projroot_l/.bus-lock" "$projroot_l/.bus-lock-2" "$projroot_l/.bus-lock-3"; do
    [ -f "$lock_l" ] || continue
    ll_slug="$(sed -n 's/.*"slug":"\([^"]*\)".*/\1/p' "$lock_l")"
    ll_sid="$(sed -n 's/.*"sid":"\([^"]*\)".*/\1/p' "$lock_l")"
    if [ "$ll_slug" = "$slug" ] && [ "$ll_sid" != "$sid" ]; then
      rm -f "$lock_l"
      echo "LOCK_ORFAO_LIBERADO=$(printf '%s' "$ll_sid" | cut -c1-8)"
      printf '%s\tlock-orfao-liberado\t%s\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null)" "$(printf '%s' "$ll_sid" | cut -c1-8)" "$slug" >> "$bus_root/.bus-gate.log" 2>/dev/null || true
    fi
  done
  prio="${3:-}"
  case "$prio" in
    ''|*[!0-9]*) : ;;                                  # so se for numero
    *)
      if [ "$proj" = "default" ]; then projroot="$bus_root"; else projroot="$bus_root/$proj"; fi
      mkdir -p "$projroot"; pf="$projroot/.priority"; tmp="$pf.$$.tmp"
      : > "$tmp"
      [ -f "$pf" ] && grep -v "^[[:space:]]*$slug[[:space:]]*:" "$pf" >> "$tmp" 2>/dev/null
      printf '%s:%s\n' "$slug" "$prio" >> "$tmp"
      mv -f "$tmp" "$pf"
    ;;
  esac
  emit "$proj" "$slug"
elif [ -s "$f" ]; then
  proj="$(sed -n '1p' "$f")"; slug="$(sed -n '2p' "$f")"
  if [ -n "$slug" ]; then emit "$proj" "$slug"
  elif [ -n "$proj" ]; then emit "default" "$proj"   # compat: 1 linha = so slug
  else echo "NONE"; fi
else
  echo "NONE"
fi
