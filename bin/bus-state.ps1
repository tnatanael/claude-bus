# bus-state.ps1
# Marca o estado busy/free DESTA sessao (indexado por CLAUDE_CODE_SESSION_ID).
# Quem escreve: os hooks do Claude Code (UserPromptSubmit -> busy, Stop -> free) e
# o proprio Claude ao processar um handoff. Quem le: o bus-monitor.ps1, que so
# ENTREGA um handoff (acorda a sessao) quando o estado e 'free' -- assim o wake nao
# chega no meio de um turno ocupado e nao e engolido.
#   -Set busy | free

param(
  [Parameter(Mandatory=$true)][ValidateSet('busy','free')][string]$Set,
  [string]$BusRoot = (Join-Path $env:TEMP 'claude-bus')
)

$sid = $env:CLAUDE_CODE_SESSION_ID
if (-not $sid) { exit 0 }   # sem id de sessao nao ha o que marcar

$dir = Join-Path $BusRoot 'state'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText((Join-Path $dir ($sid + '.state')), $Set, $enc)
