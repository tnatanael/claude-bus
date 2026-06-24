#!/usr/bin/env bash
# bus-name.sh [slug] [project]   (par Unix do bus-name.ps1)
# Sem args: ecoa o registrado (PROJECT=/SLUG=/BUS_CRON_MINUTE=) ou 'NONE'.
# Com args: grava (project default='default') e ecoa. Compat: 1 linha antiga = projeto 'default'.
# names/ fica na raiz BASE (registro global); o isolamento por projeto e nas pastas de handoff.
set -u
bus_root="${CLAUDE_BUS_ROOT:-/tmp/claude-bus}"
sid="${CLAUDE_CODE_SESSION_ID:-}"
[ -z "$sid" ] && { echo "NONE"; exit 0; }
dir="$bus_root/names"; mkdir -p "$dir"
f="$dir/$sid.txt"

# "visto por ultimo": todo /bus passa por aqui -> regrava. O dashboard usa o frescor
# pra inferir se o cron da sessao esta REALMENTE armado (cron dispara /bus de hora em hora).
seen_dir="$bus_root/seen"; mkdir -p "$seen_dir"
date +%s > "$seen_dir/$sid"

# minuto do cron DETERMINISTICO por sessao = soma dos bytes do sid mod 60 (bate com
# o dashboard, que calcula do sid). Estavel entre chamadas; ainda espalha as sessoes.
cronmin=0; i=0
while [ "$i" -lt "${#sid}" ]; do c=$(printf '%d' "'${sid:$i:1}"); cronmin=$((cronmin + c)); i=$((i + 1)); done
cronmin=$((cronmin % 60))
emit() { echo "PROJECT=$1"; echo "SLUG=$2"; echo "BUS_CRON_MINUTE=$cronmin"; }

if [ -n "${1:-}" ]; then
  proj="${2:-default}"; [ -z "$proj" ] && proj="default"
  printf '%s\n%s' "$proj" "$1" > "$f"
  emit "$proj" "$1"
elif [ -s "$f" ]; then
  proj="$(sed -n '1p' "$f")"; slug="$(sed -n '2p' "$f")"
  if [ -n "$slug" ]; then emit "$proj" "$slug"
  elif [ -n "$proj" ]; then emit "default" "$proj"   # compat: 1 linha = so slug
  else echo "NONE"; fi
else
  echo "NONE"
fi
