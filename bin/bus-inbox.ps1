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
  [Parameter(Mandatory=$true)][string]$Me,
  [string]$Project = '',
  [string]$BusRoot = ''
)
# Raiz do projeto resolvida AQUI (nao pelo agente): -BusRoot explicito vence; senao
# base (CLAUDE_BUS_ROOT ou %TEMP%\claude-bus) + o projeto como subpasta (exceto
# 'default'). Assim o agente passa so -Project <nome> e nunca monta caminho com
# %TEMP%/$env:TEMP -- que quebra se o comando rodar via Bash.
if ($BusRoot -eq '') {
  $base = $env:CLAUDE_BUS_ROOT
  if (-not $base) { $base = Join-Path $env:TEMP 'claude-bus' }
  if ($Project -ne '' -and $Project -ne 'default') { $BusRoot = Join-Path $base $Project }
  else { $BusRoot = $base }
}
# UTF-8 no stdout: senao o PS 5.1 corrompe acentos do corpo na captura do harness.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

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
  $header = ($raw -split '(?m)^---\s*$', 2)[0]
  $authok = ($header -match '(?m)^auth:\s*(\S+)\s*$') -and ($matches[1] -eq $secret)
  if (-not $authok) {
    New-Item -ItemType Directory -Force -Path $rejected | Out-Null
    Move-Item -LiteralPath $hit.FullName -Destination (Join-Path $rejected $hit.Name) -Force -ErrorAction SilentlyContinue
    continue
  }
  $found++
  Write-Output ('BUS_FILE=' + $hit.FullName)
  Write-Output 'BUS_BODY_BEGIN'
  Write-Output $raw
  Write-Output 'BUS_BODY_END'
}
if ($found -eq 0) { Write-Output 'BUS_EMPTY' }
