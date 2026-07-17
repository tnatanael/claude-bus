# bus-schedule.ps1 -- cria/lista/remove HANDOFFS AGENDADOS via Tarefa Agendada do Windows.
# Cada agendamento injeta um handoff operador->destino no inbox do BUS na cadencia escolhida,
# SEM acordar modelo (o disparo e puro bus-send, como o /bus-message). Artefatos duraveis em
# ~/.claude/bus-schedules/<slug>/ (fora do %TEMP%, que o Storage Sense limpa). Par Unix: bus-schedule.sh.
#
# Uso:
#   -Action create -Slug <s> -Project <p> -Dest <d> -Cadence daily|weekly [-Days Mon,Wed,Fri] -Time HH:mm -BodyFile <arq>
#   -Action list
#   -Action remove -Slug <s>
#
# Os wrappers (_send.ps1, run-hidden.vbs) sao FIXOS e leem o schedule.meta do proprio dir --
# entao editar o body.txt NAO exige re-registrar a tarefa (o bus-send le o body fresco a cada disparo).
param(
  [Parameter(Mandatory=$true)][ValidateSet('create','list','remove')][string]$Action,
  [string]$Slug='', [string]$Project='', [string]$Dest='',
  [string]$Cadence='daily', [string]$Days='', [string]$Time='', [string]$BodyFile=''
)
$ErrorActionPreference='Stop'
try { [Console]::OutputEncoding=[System.Text.Encoding]::UTF8 } catch {}
$homeDir = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
$schedRoot  = Join-Path $homeDir '.claude\bus-schedules'
$taskFolder = '\claude-bus\'
$enc = New-Object System.Text.UTF8Encoding($false)
function TaskName([string]$s) { 'bus-schedule-' + $s }

# --- templates FIXOS (leem o schedule.meta do proprio dir -> zero baking/escaping) ---
$SEND_PS1 = @'
$ErrorActionPreference = 'Stop'
$dir = $PSScriptRoot
$m = @{}
foreach ($ln in (Get-Content -LiteralPath (Join-Path $dir 'schedule.meta') -Encoding UTF8)) { $kv = $ln -split '=', 2; if ($kv.Count -eq 2) { $m[$kv[0].Trim()] = $kv[1].Trim() } }
$log = Join-Path $dir 'send.log'
$stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
try {
  $body = Join-Path $dir 'body.txt'
  if (-not (Test-Path -LiteralPath $body)) { throw 'body.txt ausente' }
  # bus-send usa exit -> isola num PS FILHO pra nao matar este wrapper; le o $LASTEXITCODE.
  $out = & powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $m['busSend'] -To $m['dest'] -From operador -Project $m['project'] -BusRoot $m['busRoot'] -BodyFile $body 2>&1
  $code = $LASTEXITCODE
  Add-Content -LiteralPath $log -Value "$stamp exit=$code $($out -join ' | ')" -Encoding UTF8
  exit $code
} catch {
  Add-Content -LiteralPath $log -Value "$stamp ERRO $($_.Exception.Message)" -Encoding UTF8
  exit 1
}
'@
$RUN_VBS = @'
Option Explicit
Dim sh, dir, ps
Set sh = CreateObject("WScript.Shell")
dir = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
ps = "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & dir & "_send.ps1"""
WScript.Quit sh.Run(ps, 0, True)
'@

if ($Action -eq 'create') {
  if (-not $Slug -or -not $Project -or -not $Dest -or -not $Time) { throw 'create exige -Slug -Project -Dest -Time' }
  if ($Time -notmatch '^([01]?\d|2[0-3]):[0-5]\d$') { throw "Time invalido (HH:mm 24h): $Time" }
  if (-not (Test-Path -LiteralPath $BodyFile)) { throw "BodyFile ausente: $BodyFile" }
  if ($Cadence -eq 'weekly' -and -not $Days) { throw 'weekly exige -Days (ex.: Mon,Wed,Fri)' }
  $base = $env:CLAUDE_BUS_ROOT; if (-not $base) { $base = Join-Path $env:TEMP 'claude-bus' }
  $busRoot = if ($Project -ne 'default') { Join-Path $base $Project } else { $base }
  $busSend = Join-Path $PSScriptRoot 'bus-send.ps1'
  $dir = Join-Path $schedRoot $Slug
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  Copy-Item -LiteralPath $BodyFile -Destination (Join-Path $dir 'body.txt') -Force
  $metaLines = [string[]]@("slug=$Slug", "project=$Project", "dest=$Dest", "busSend=$busSend", "busRoot=$busRoot", "cadence=$Cadence", "time=$Time", "days=$Days")
  [System.IO.File]::WriteAllLines((Join-Path $dir 'schedule.meta'), $metaLines, $enc)
  [System.IO.File]::WriteAllText((Join-Path $dir '_send.ps1'), $SEND_PS1, $enc)
  [System.IO.File]::WriteAllText((Join-Path $dir 'run-hidden.vbs'), $RUN_VBS, $enc)
  # gatilho (a data e ignorada no Daily/Weekly; so o horario conta)
  $at = [datetime]$Time
  if ($Cadence -eq 'weekly') {
    $dow = $Days -split '\s*,\s*'
    $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $dow -At $at
  } else {
    $trigger = New-ScheduledTaskTrigger -Daily -At $at
  }
  # principal Interactive/Limited + usuario atual (S4U/"run whether logged on" e rejeitado); StartWhenAvailable
  # roda quando a maquina voltar se estava desligada; ExecutionTimeLimit curto; IgnoreNew evita empilhar.
  $act = New-ScheduledTaskAction -Execute 'C:\Windows\System32\wscript.exe' -Argument ('"' + (Join-Path $dir 'run-hidden.vbs') + '"') -WorkingDirectory $dir
  $prin = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
  $set = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 15) -MultipleInstances IgnoreNew
  Register-ScheduledTask -TaskName (TaskName $Slug) -TaskPath $taskFolder -Action $act -Trigger $trigger -Principal $prin -Settings $set -Description "BUS handoff agendado operador->$Dest (projeto $Project). Fonte: $dir" -Force | Out-Null
  Write-Output "CREATED=$Slug"
  Write-Output ("TASK=" + $taskFolder + (TaskName $Slug))
  Write-Output ("DIR=" + $dir)
  $info = Get-ScheduledTaskInfo -TaskName (TaskName $Slug) -TaskPath $taskFolder -ErrorAction SilentlyContinue
  if ($info) { Write-Output ("NEXT=" + $info.NextRunTime) }
}
elseif ($Action -eq 'list') {
  $any = $false
  if (Test-Path -LiteralPath $schedRoot) {
    foreach ($d in (Get-ChildItem -LiteralPath $schedRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
      $mf = Join-Path $d.FullName 'schedule.meta'; if (-not (Test-Path $mf)) { continue }
      $any = $true
      $m = @{}; foreach ($ln in (Get-Content $mf -Encoding UTF8)) { $kv = $ln -split '=', 2; if ($kv.Count -eq 2) { $m[$kv[0].Trim()] = $kv[1].Trim() } }
      $info = Get-ScheduledTaskInfo -TaskName (TaskName $d.Name) -TaskPath $taskFolder -ErrorAction SilentlyContinue
      $next = if ($info) { $info.NextRunTime } else { '(tarefa ausente!)' }
      $last = if ($info -and $info.LastRunTime) { "$($info.LastRunTime) exit=$($info.LastTaskResult)" } else { '-' }
      $cad = if ($m['cadence'] -eq 'weekly') { "weekly $($m['days'])" } else { 'daily' }
      Write-Output ("[{0}] {1} -> {2} | {3} @ {4} | next={5} | last={6}" -f $d.Name, $m['project'], $m['dest'], $cad, $m['time'], $next, $last)
      $lf = Join-Path $d.FullName 'send.log'
      if (Test-Path $lf) { $t = Get-Content $lf -Tail 1 -ErrorAction SilentlyContinue; if ($t) { Write-Output ("    log: $t") } }
    }
  }
  if (-not $any) { Write-Output '(nenhum agendamento)' }
}
elseif ($Action -eq 'remove') {
  if (-not $Slug) { throw 'remove exige -Slug' }
  try { Unregister-ScheduledTask -TaskName (TaskName $Slug) -TaskPath $taskFolder -Confirm:$false -ErrorAction Stop; Write-Output ("TASK_REMOVED=" + (TaskName $Slug)) }
  catch { Write-Output ("TASK_AUSENTE=" + (TaskName $Slug)) }
  $dir = Join-Path $schedRoot $Slug
  if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force; Write-Output "DIR_REMOVED=$dir" }
  else { Write-Output "DIR_AUSENTE=$dir" }
}
