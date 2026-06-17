# bus-monitor.ps1
# Watches the BUS inbox for handoffs addressed to this specialist.
# It exits (which wakes the Claude session) when ONE of these happens:
#   - a complete, AUTHENTICATED handoff addressed to $Me is found -> BUS_EVENT=handoff
#   - the yield deadline is reached                               -> BUS_EVENT=yield
#   - the OS/host kills the background task (timeout)             -> exits, no marker
# The skill ALWAYS relaunches the monitor on any exit, so every case is recoverable.
#
# Handoffs whose "auth:" token does not match the shared secret are moved to
# rejected\ and never wake the session (blocks casual injection via %TEMP%).
#
# Polling happens here in the shell (free), NOT in the model. The session only
# wakes on real work (a handoff) or on the periodic yield.

param(
  [Parameter(Mandatory=$true)][string]$Me,
  [string]$BusRoot = (Join-Path $env:TEMP 'claude-bus'),
  [int]$PollSeconds = 2,
  [int]$YieldSeconds = 1800
)

# Forca UTF-8 no stdout: sem isso o PS 5.1 emite no encoding do console e os acentos
# do corpo do handoff chegam corrompidos (mojibake) na captura do harness.
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

# Singleton: ao iniciar, mata qualquer outro monitor do MESMO slug (exceto este
# processo e seu wrapper/pai). Evita o acumulo de processos zumbis quando a sessao
# relanca o monitor sem o antigo ter morrido de verdade.
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
$beat = Join-Path $presence ($Me + '.alive')
$sid  = $env:CLAUDE_CODE_SESSION_ID
$statefile = if ($sid) { Join-Path $state ($sid + '.state') } else { '' }

$secret   = Get-BusSecret $BusRoot
$prefix   = 'to-' + $Me + '__'
$deadline = (Get-Date).AddSeconds($YieldSeconds)

while ($true) {
  # heartbeat de presenca: e assim que outras sessoes sabem que estou escutando
  [System.IO.File]::WriteAllText($beat, (Get-Date).ToString('o'))
  $hit = Get-ChildItem -LiteralPath $inbox -File -ErrorAction SilentlyContinue |
         Where-Object { $_.Extension -eq '.handoff' -and $_.Name.StartsWith($prefix) } |
         Sort-Object LastWriteTime |
         Select-Object -First 1

  if ($hit) {
    $raw = Get-Content -LiteralPath $hit.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    # The end tag is a defensive integrity check on top of the atomic rename.
    if ($raw -and ($raw -match '###BUS-END')) {
      $header = ($raw -split '(?m)^---\s*$', 2)[0]
      $authok = ($header -match '(?m)^auth:\s*(\S+)\s*$') -and ($matches[1] -eq $secret)
      if ($authok) {
        # So ENTREGA quando a sessao estiver free (state != busy), pra o wake nao
        # chegar no meio de um turno ocupado e ser engolido. O handoff fica intacto
        # no inbox enquanto espera; o heartbeat continua pra nao parecer morto.
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
        # Bad/missing token: quarantine and keep watching. Do NOT wake the session.
        New-Item -ItemType Directory -Force -Path $rejected | Out-Null
        Move-Item -LiteralPath $hit.FullName -Destination (Join-Path $rejected $hit.Name) -Force -ErrorAction SilentlyContinue
      }
    }
  }

  if ((Get-Date) -ge $deadline) {
    Write-Output 'BUS_EVENT=yield'
    exit 0
  }

  Start-Sleep -Seconds $PollSeconds
}
