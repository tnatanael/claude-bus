# bus-send.ps1
# Writes a handoff into the BUS inbox using an atomic temp+rename, so a monitor
# on the other side never reads a half-written file. Body is written as UTF-8
# WITHOUT BOM (preserves PT-BR accents, no BOM garbage at the top of the file).
#
# Every handoff carries a shared-secret token ("auth:"). The monitor discards any
# file whose token does not match, blocking casual/opportunistic injection from
# other processes that can write to %TEMP% but do not know the secret.
#
# Prefer -BodyFile (a file written by the Write tool) over -Body for anything
# multi-line or with accents: it avoids all shell quoting/escaping pitfalls.

param(
  [Parameter(Mandatory=$true)][string]$To,
  [Parameter(Mandatory=$true)][string]$From,
  [string]$Body = '',
  [string]$BodyFile = '',
  [switch]$ReplyRequired,
  [switch]$Fyi,
  [string]$Issue = '',
  [string]$InReplyTo = '',
  [string]$Project = '',
  [string]$BusRoot = ''
)
# -Fyi: handoff que NAO acorda o destino (kind: fyi). Fica no inbox e e entregue de carona no
# proximo wake real dele -- que e exatamente quando a informacao ainda serve, porque so ai ele
# vai FAZER alguma coisa. Regra de marcacao: se o outro tem algo a FAZER por causa disto, e
# task; se e so pra ele SABER, e fyi; na duvida, task (task errada custa um wake, fyi errada
# custa atraso). Destravar alguem ("pode pushar") e TASK, nao fyi.
if ($Fyi -and $ReplyRequired) {
  Write-Error 'FYI_COM_REPLY: -Fyi e -ReplyRequired se contradizem (fyi nao acorda ninguem, entao a resposta nunca vem). Escolha um.'
  exit 1
}
# Raiz do projeto resolvida AQUI (-Project), pra o agente nunca montar caminho com
# %TEMP%/$env:TEMP (quebra via Bash). -BusRoot explicito vence.
if ($BusRoot -eq '') {
  $base = $env:CLAUDE_BUS_ROOT
  if (-not $base) { $base = Join-Path $env:TEMP 'claude-bus' }
  if ($Project -ne '' -and $Project -ne 'default') { $BusRoot = Join-Path $base $Project }
  else { $BusRoot = $base }
}

function Get-BusSecret([string]$root) {
  New-Item -ItemType Directory -Force -Path $root | Out-Null
  $path = Join-Path $root '.bus-secret'
  if (-not (Test-Path -LiteralPath $path)) {
    $val = [guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')
    $tmp = $path + '.' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.tmp'
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tmp, $val, $enc)
    try { Move-Item -LiteralPath $tmp -Destination $path -ErrorAction Stop }
    catch { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
  }
  return (Get-Content -LiteralPath $path -Raw -Encoding UTF8).Trim()
}

if ($BodyFile -ne '' -and (Test-Path -LiteralPath $BodyFile)) {
  $Body = Get-Content -LiteralPath $BodyFile -Raw -Encoding UTF8
}
if ($Body -eq '') { Write-Error 'Empty body: pass -Body or -BodyFile.'; exit 1 }

$secret = Get-BusSecret $BusRoot
$inbox  = Join-Path $BusRoot 'inbox'
New-Item -ItemType Directory -Force -Path $inbox | Out-Null

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$rand  = [guid]::NewGuid().ToString('N').Substring(0,6)
$id    = $stamp + '-' + $rand
$rr    = if ($ReplyRequired) { 'true' } else { 'false' }

$name  = 'to-' + $To + '__from-' + $From + '__' + $id + '.handoff'
$final = Join-Path $inbox $name
$tmp   = $final + '.tmp'

$kind  = if ($Fyi) { 'fyi' } else { 'task' }

# -Issue: amarra o handoff a uma issue do GitHub (numero ou URL). Quem recebe responde NO
# TICKET, nao por handoff de volta -- e la que o operador e os usuarios finais leem, e e la que
# fica o historico (o BUS vive no %TEMP% e esquece). Quem preenche isto na pratica e o carteiro
# do /bus-git-watch, que ja tem a issue na mao quando despacha.
$lines = @(
  '###BUS-START'
  'id: '             + $id
  'from: '           + $From
  'to: '             + $To
  'auth: '           + $secret
  'reply_required: ' + $rr
  'kind: '           + $kind
)
if ($Issue -ne '') { $lines += ('issue: ' + $Issue) }
$lines += @(
  'in_reply_to: '    + $InReplyTo
  '---'
  $Body
  '###BUS-END'
)
$text = ($lines -join "`r`n") + "`r`n"

$enc = New-Object System.Text.UTF8Encoding($false)   # $false = no BOM
[System.IO.File]::WriteAllText($tmp, $text, $enc)
Move-Item -LiteralPath $tmp -Destination $final       # atomic rename on same volume

Write-Output ('SENT=' + $final)
Write-Output ('ID=' + $id)

# AVISO DE CORPO INFLADO (nao bloqueia -- recusar aqui jogaria fora trabalho ja feito). O valor
# e o laco de feedback DENTRO da sessao: quem manda 11 self-handoffs seguidos corrige do 2o em
# diante. Medido: self-handoff com media de 1835 bytes cujo proprio corpo dizia "checkpoint em
# <arquivo>, leia dali" -- 1,8KB descrevendo um arquivo que o modelo ia abrir de qualquer jeito.
$bodyLen = [System.Text.Encoding]::UTF8.GetByteCount($Body)
if ($To -eq $From -and $bodyLen -gt 800) {
  Write-Output ('BUS_BODY_WARN=self-handoff com ' + $bodyLen + ' bytes. Self-handoff e PONTEIRO: onde esta o checkpoint, qual o proximo passo, o que NAO refazer. O conteudo mora no arquivo de checkpoint.')
} elseif ($bodyLen -gt 4096) {
  Write-Output ('BUS_BODY_WARN=corpo com ' + $bodyLen + ' bytes. Um spec completo pode passar disso; conteudo colado de arquivo/commit/issue, nao -- mande o caminho e o que olhar la.')
}
