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
  [string]$InReplyTo = '',
  [string]$Project = '',
  [string]$BusRoot = ''
)
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

$lines = @(
  '###BUS-START'
  'id: '             + $id
  'from: '           + $From
  'to: '             + $To
  'auth: '           + $secret
  'reply_required: ' + $rr
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
