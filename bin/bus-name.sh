#!/usr/bin/env bash
# bus-name.sh [slug]   (par Unix do bus-name.ps1)
# Sem arg: ecoa o slug salvo desta sessao, ou 'NONE'. Com arg: grava e ecoa.
# Indexado por CLAUDE_CODE_SESSION_ID, pra religacoes do /bus nao redigitarem o nome.
set -u
bus_root="${CLAUDE_BUS_ROOT:-/tmp/claude-bus}"
sid="${CLAUDE_CODE_SESSION_ID:-}"

[ -z "$sid" ] && { echo "NONE"; exit 0; }

dir="$bus_root/names"
mkdir -p "$dir"
f="$dir/$sid.txt"

if [ -n "${1:-}" ]; then
  printf '%s' "$1" > "$f"
  echo "$1"
elif [ -s "$f" ]; then
  cat "$f"
else
  echo "NONE"
fi
