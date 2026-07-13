# bus-inbox.ps1 -Me <slug>
# Leitor ONE-SHOT do inbox: lista os handoffs AUTENTICADOS enderecados a <slug>, do
# mais antigo pro mais novo. Forjados (token errado/ausente) vao pra rejected\ e nao
# saem. Cada handoff valido sai como um bloco:
#   BUS_FILE=<caminho>
#   BUS_BODY_BEGIN
#   <conteudo bruto do handoff>
#   BUS_BODY_END
# Se nao ha nada pendente: BUS_EMPTY. Sem polling, sem background, sem presenca --
# substitui o antigo monitor no modelo pull (o /bus chama isto uma vez e processa).
param(
  [string]$Me = '',
  [string]$Project = '',
  [string]$BusRoot = ''
)
# UTF-8 no stdout: senao o PS 5.1 corrompe acentos do corpo na captura do harness.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# Base global do BUS: names/ e seen/ ficam AQUI (fora do projeto). A raiz do projeto e
# resolvida depois; o agente passa so -Project <nome> e nunca monta caminho com
# %TEMP%/$env:TEMP -- que quebra se rodar via Bash. -BusRoot explicito vence.
$base = $env:CLAUDE_BUS_ROOT
if (-not $base) { $base = Join-Path $env:TEMP 'claude-bus' }
$sid = $env:CLAUDE_CODE_SESSION_ID

# IDENTIDADE AUTO-RESOLVIDA: se -Me nao veio, le o registro global names/<sid>
# (linha1=projeto, linha2=slug) -- igual o gate faz -- e ANUNCIA na saida. Assim o
# /bus bare nao precisa de uma chamada separada ao bus-name so pra saber quem e.
if ($Me -eq '') {
  if ($sid) {
    $nf = Join-Path (Join-Path $base 'names') ($sid + '.txt')
    if (Test-Path -LiteralPath $nf) {
      $nl = @(Get-Content -LiteralPath $nf)
      if ($nl.Count -ge 2) { if ($Project -eq '') { $Project = $nl[0].Trim() }; $Me = $nl[1].Trim() }
      elseif ($nl.Count -eq 1) { if ($Project -eq '') { $Project = 'default' }; $Me = $nl[0].Trim() }
    }
  }
  if ($Me -eq '') { Write-Output 'BUS_IDENTITY=NONE'; exit 0 }
  Write-Output ('BUS_SLUG=' + $Me)
  if ($Project -eq '') { Write-Output 'BUS_PROJECT=default' } else { Write-Output ('BUS_PROJECT=' + $Project) }
}

# Raiz do projeto: -BusRoot explicito vence; senao base + projeto (exceto 'default').
if ($BusRoot -eq '') {
  if ($Project -ne '' -and $Project -ne 'default') { $BusRoot = Join-Path $base $Project }
  else { $BusRoot = $base }
}

# Marcador "visto por ultimo" na BASE (global): mantem o "armado" do dashboard fresco a
# cada /bus (mesmo quando a IA pula o bus-name). O cron dispara /bus a cada 5 min.
if ($sid) {
  $seenDir = Join-Path $base 'seen'
  New-Item -ItemType Directory -Force -Path $seenDir | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $seenDir $sid), (Get-Date).ToString('o'), (New-Object System.Text.UTF8Encoding($false)))
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

$inbox    = Join-Path $BusRoot 'inbox'
$rejected = Join-Path $BusRoot 'rejected'
New-Item -ItemType Directory -Force -Path $inbox | Out-Null
$secret = Get-BusSecret $BusRoot
$prefix = 'to-' + $Me + '__'

$hits = Get-ChildItem -LiteralPath $inbox -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -eq '.handoff' -and $_.Name.StartsWith($prefix) } |
        Sort-Object LastWriteTime
$found = 0
foreach ($hit in $hits) {
  $raw = Get-Content -LiteralPath $hit.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
  # O end tag confirma que a escrita atomica terminou (nao pega arquivo a meio caminho).
  if (-not ($raw -and ($raw -match '###BUS-END'))) { continue }
  $split  = $raw -split '(?m)^---\s*$', 2
  $header = $split[0]
  $authok = ($header -match '(?m)^auth:\s*(\S+)\s*$') -and ($matches[1] -eq $secret)
  if (-not $authok) {
    New-Item -ItemType Directory -Force -Path $rejected | Out-Null
    Move-Item -LiteralPath $hit.FullName -Destination (Join-Path $rejected $hit.Name) -Force -ErrorAction SilentlyContinue
    continue
  }
  # Entrega SO o que o modelo precisa: quem enviou (from), o id (p/ -InReplyTo), se pede
  # retorno, e o CORPO ja limpo. Descarta auth (token/ruido), o "to" (e voce) e os
  # marcadores ###BUS-START/END -> menos tokens de contexto por leitura, parsing trivial.
  $hFrom = if ($header -match '(?m)^from:\s*(\S+)') { $matches[1] } else { '' }
  $hId   = if ($header -match '(?m)^id:\s*(\S+)') { $matches[1] } else { '' }
  $hRR   = if ($header -match '(?m)^reply_required:\s*(\S+)') { $matches[1] } else { 'false' }
  $hIRT  = if ($header -match '(?m)^in_reply_to:\s*(\S+)') { $matches[1] } else { '' }
  $body  = if ($split.Count -gt 1) { $split[1] } else { '' }
  $body  = ($body -replace '(?m)^\s*###BUS-END\s*$', '').Trim()
  $found++
  Write-Output ('BUS_FILE=' + $hit.FullName)
  Write-Output ('BUS_FROM=' + $hFrom)
  Write-Output ('BUS_ID=' + $hId)
  Write-Output ('BUS_REPLY_REQUIRED=' + $hRR)
  if ($hIRT) { Write-Output ('BUS_IN_REPLY_TO=' + $hIRT) }
  Write-Output 'BUS_BODY_BEGIN'
  Write-Output $body
  Write-Output 'BUS_BODY_END'
}
if ($found -eq 0) { Write-Output 'BUS_EMPTY' }
