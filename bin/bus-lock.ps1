# bus-lock.ps1 -Release  -> libera o lock GLOBAL do BUS se for desta sessao (no-op se nao for).
# O lock e UNICO por maquina (na base do BUS), porque o limite de API e da CONTA Claude,
# nao do projeto: um especialista trabalhando segura todos os outros, de qualquer projeto.
param([switch]$Release)
try {
  $base = $env:CLAUDE_BUS_ROOT; if (-not $base) { $base = Join-Path $env:TEMP 'claude-bus' }
  $lock = Join-Path $base '.bus-lock'
  $sid  = $env:CLAUDE_CODE_SESSION_ID
  if ($Release) {
    if ((Test-Path -LiteralPath $lock) -and $sid) {
      $L = $null
      try { $L = (Get-Content -LiteralPath $lock -Raw) | ConvertFrom-Json } catch {}
      if ($L -and $L.sid -eq $sid) {
        Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
        Write-Output 'LOCK_RELEASED'
      } else {
        Write-Output 'LOCK_NOT_MINE'
      }
    } else {
      Write-Output 'LOCK_ABSENT'
    }
  }
} catch { Write-Output 'LOCK_ERR' }
