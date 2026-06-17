# bus-monitor.ps1
# Watches the BUS inbox for handoffs addressed to this specialist and exits (waking
# the session) on a handoff, on yield, or if the host kills it. The skill ALWAYS
# relaunches on exit. Bad-token handoffs go to rejected\ and never wake the session.
# Polling is in the shell (free), not in the model.

param(
  [Parameter(Mandatory=$true)][string]$Me,
  [string]$BusRoot = (Join-Path $env:TEMP 'claude-bus'),
  [int]$PollSeconds = 2,
  [int]$YieldSeconds = 1800
)

# Forca UTF-8 no stdout: sem isso o PS 5.1 corrompe acentos do corpo na captura do harness.
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

# Singleton (1/2) best-effort: ao iniciar, mata outros monitores do MESMO slug por
# linha de comando (exceto este e o pai). Pode perder corrida; o lock-PID (2/2) cobre.
try {
  $self   = $PID
  $parent = (Get-CimInstance Win32_Process -Filter ("ProcessId=" + $self) -ErrorAction SilentlyContinue).ParentProcessId
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessId -ne $self -and $_.ProcessId -ne $parent -and $_.CommandLine -like '*bus-monitor.ps1*' -and $_.CommandLine -like ('*-Me ' + $Me + '*') } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
} catch {}

$inbox    = Join-Path $BusRoot 'inbox'
$rejected = Join-Path $BusRoot 'rejected'
$presence = Join-Path $BusRoot 'presence'
$state    = Join-Path $BusRoot 'state'
New-Item -ItemType Directory -Force -Path $inbox | Out-Null
New-Item -ItemType Directory -Force -Path $presence | Out-Null
New-Item -ItemType Directory -Force -Path $state | Out-Null
$beat  = Join-Path $presence ($Me + '.alive')
$owner = Join-Path $presence ($Me + '.owner')
$sid   = $env:CLAUDE_CODE_SESSION_ID
$statefile = if ($sid) { Join-Path $state ($sid + '.state') } else { '' }

# Singleton (2/2) cooperativo por lock-PID: gravo meu PID como dono do slug. A cada
# loop, se o .owner nao for mais o meu PID, outro monitor assumiu e eu saio (exit).
# Pega duplicados/zumbis que o kill acima nao alcancou -- sem precisar matar ninguem.
[System.IO.File]::WriteAllText($owner, [string]$PID, (New-Object System.Text.UTF8Encoding($false)))

$secret   = Get-BusSecret $BusRoot
$prefix   = 'to-' + $Me + '__'
$deadline = (Get-Date).AddSeconds($YieldSeconds)

while ($true) {
  [System.IO.File]::WriteAllText($beat, (Get-Date).ToString('o'))   # heartbeat
  # lock-PID: se outro monitor do mesmo slug assumiu o .owner, eu me retiro
  $own = (Get-Content -LiteralPath $owner -Raw -ErrorAction SilentlyContinue)
  if ($own -and ($own.Trim() -ne [string]$PID)) { exit 0 }

  $hit = Get-ChildItem -LiteralPath $inbox -File -ErrorAction SilentlyContinue |
         Where-Object { $_.Extension -eq '.handoff' -and $_.Name.StartsWith($prefix) } |
         Sort-Object LastWriteTime |
         Select-Object -First 1

  if ($hit) {
    $raw = Get-Content -LiteralPath $hit.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if ($raw -and ($raw -match '###BUS-END')) {
      $header = ($raw -split '(?m)^---\s*$', 2)[0]
      $authok = ($header -match '(?m)^auth:\s*(\S+)\s*$') -and ($matches[1] -eq $secret)
      if ($authok) {
        # so entrega quando a sessao estiver free (nao engole o wake no meio de um turno)
        while ($statefile -ne '' -and (Test-Path -LiteralPath $statefile) -and (((Get-Content -LiteralPath $statefile -Raw -ErrorAction SilentlyContinue) -replace '\s','') -eq 'busy')) {
          [System.IO.File]::WriteAllText($beat, (Get-Date).ToString('o'))
          Start-Sleep -Seconds $PollSeconds
        }
        Write-Output 'BUS_EVENT=handoff'
        Write-Output ('BUS_FILE=' + $hit.FullName)
        Write-Output 'BUS_BODY_BEGIN'
        Write-Output $raw
        Write-Output 'BUS_BODY_END'
        exit 0
      } else {
        New-Item -ItemType Directory -Force -Path $rejected | Out-Null
        Move-Item -LiteralPath $hit.FullName -Destination (Join-Path $rejected $hit.Name) -Force -ErrorAction SilentlyContinue
      }
    }
  }

  if ((Get-Date) -ge $deadline) { Write-Output 'BUS_EVENT=yield'; exit 0 }
  Start-Sleep -Seconds $PollSeconds
}
