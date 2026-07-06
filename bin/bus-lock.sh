#!/usr/bin/env bash
# bus-lock.sh --release  -> libera o lock do PROJETO desta sessao se for dela (no-op se nao).
# O lock e POR PROJETO (<projeto>/.bus-lock): serializa DENTRO do projeto, mas projetos
# diferentes rodam em paralelo. O projeto e resolvido do names/<sid> (ou --project explicito).
# Par Unix do bus-lock.ps1. NAO TESTADO no Unix ainda -- validar.
set -u
base="${CLAUDE_BUS_ROOT:-/tmp/claude-bus}"
sid="${CLAUDE_CODE_SESSION_ID:-}"
release=0
project=""
while [ $# -gt 0 ]; do
  case "$1" in
    --release|-Release) release=1;;
    --project|-Project) shift; project="${1:-}";;
  esac
  shift
done
# Projeto: --project explicito vence; senao resolve do names/<sid> (linha1=projeto, linha2=slug).
if [ -z "$project" ] && [ -n "$sid" ]; then
  nf="$base/names/$sid.txt"
  if [ -f "$nf" ]; then
    l2="$(sed -n '2p' "$nf" | tr -d '[:space:]')"
    if [ -n "$l2" ]; then project="$(sed -n '1p' "$nf" | tr -d '[:space:]')"; else project="default"; fi
  fi
fi
if [ -n "$project" ] && [ "$project" != "default" ]; then projRoot="$base/$project"; else projRoot="$base"; fi
lock="$projRoot/.bus-lock"
if [ "$release" = "1" ]; then
  if [ -f "$lock" ] && [ -n "$sid" ]; then
    lsid="$(sed -n 's/.*"sid":"\([^"]*\)".*/\1/p' "$lock")"
    lslug="$(sed -n 's/.*"slug":"\([^"]*\)".*/\1/p' "$lock")"
    if [ "$lsid" = "$sid" ]; then
      rm -f "$lock"
      printf '%s\trelease\t%s\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null)" "$(printf '%s' "$sid" | cut -c1-8)" "$lslug" >> "$base/.bus-gate.log" 2>/dev/null || true
      echo 'LOCK_RELEASED'
    else echo 'LOCK_NOT_MINE'; fi
  else
    echo 'LOCK_ABSENT'
  fi
fi
