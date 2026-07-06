# bus-lock.ps1 -Release  -> libera o lock do PROJETO desta sessao se for dela (no-op se nao).
# O lock e POR PROJETO (<projeto>/.bus-lock): serializa DENTRO do projeto, mas projetos
# diferentes rodam em paralelo. O projeto e resolvido do names/<sid> (ou -Project explicito).
param([switch]$Release, [string]$Project = '')
try {
  $base = $env:CLAUDE_BUS_ROOT; if (-not $base) { $base = Join-Path $env:TEMP 'claude-bus' }
  $sid  = $env:CLAUDE_CODE_SESSION_ID
  # Projeto: -Project explicito vence; senao resolve do registro global names/<sid>.
  if ($Project -eq '' -and $sid) {
    $nf = Join-Path (Join-Path $base 'names') ($sid + '.txt')
    if (Test-Path -LiteralPath $nf) {
      $nl = @(Get-Content -LiteralPath $nf)
      if ($nl.Count -ge 2) { $Project = $nl[0].Trim() } elseif ($nl.Count -eq 1) { $Project = 'default' }
    }
  }
  $projRoot = if ($Project -and $Project -ne 'default') { Join-Path $base $Project } else { $base }
  $lock = Join-Path $projRoot '.bus-lock'
  if ($Release) {
    if ((Test-Path -LiteralPath $lock) -and $sid) {
      $L = $null
      try { $L = (Get-Content -LiteralPath $lock -Raw) | ConvertFrom-Json } catch {}
      if ($L -and $L.sid -eq $sid) {
        Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
        try { [System.IO.File]::AppendAllText((Join-Path $base '.bus-gate.log'), ("{0}`trelease`t{1}`t{2}`r`n" -f ([datetimeoffset]::Now.ToString('o')), $sid.Substring(0,[Math]::Min(8,$sid.Length)), [string]$L.slug), (New-Object System.Text.UTF8Encoding($false))) } catch {}
        Write-Output 'LOCK_RELEASED'
      } else {
        Write-Output 'LOCK_NOT_MINE'
      }
    } else {
      Write-Output 'LOCK_ABSENT'
    }
  }
} catch { Write-Output 'LOCK_ERR' }
