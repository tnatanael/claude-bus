#!/usr/bin/env bash
# bus-lock.sh --release  -> libera o lock GLOBAL do BUS se for desta sessao (no-op se nao for).
# O lock e UNICO por maquina (na base do BUS), porque o limite de API e da CONTA Claude,
# nao do projeto: um especialista trabalhando segura todos os outros, de qualquer projeto.
# Par Unix do bus-lock.ps1. NAO TESTADO no Unix ainda -- validar.
set -u
base="${CLAUDE_BUS_ROOT:-/tmp/claude-bus}"
lock="$base/.bus-lock"
sid="${CLAUDE_CODE_SESSION_ID:-}"
release=0
while [ $# -gt 0 ]; do case "$1" in --release|-Release) release=1;; esac; shift; done
if [ "$release" = "1" ]; then
  if [ -f "$lock" ] && [ -n "$sid" ]; then
    lsid="$(sed -n 's/.*"sid":"\([^"]*\)".*/\1/p' "$lock")"
    if [ "$lsid" = "$sid" ]; then rm -f "$lock"; echo 'LOCK_RELEASED'; else echo 'LOCK_NOT_MINE'; fi
  else
    echo 'LOCK_ABSENT'
  fi
fi
