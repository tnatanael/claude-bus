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
  # SLOTS: o projeto pode ter ate 3 (.bus-lock, .bus-lock-2, .bus-lock-3). Nao basta olhar o
  # slot 1 -- eu posso estar em qualquer um deles. Procuro o que tem o MEU sid; nao achando,
  # fico com o slot 1 (que e onde o LOCK_ABSENT/NOT_MINE faz sentido reportar).
  $lock = Join-Path $projRoot '.bus-lock'
  if ($sid) {
    foreach ($cand in @((Join-Path $projRoot '.bus-lock'), (Join-Path $projRoot '.bus-lock-2'), (Join-Path $projRoot '.bus-lock-3'))) {
      if (-not (Test-Path -LiteralPath $cand)) { continue }
      try {
        $LS = (Get-Content -LiteralPath $cand -Raw) | ConvertFrom-Json
        if ([string]$LS.sid -eq $sid) { $lock = $cand; break }
      } catch {}
    }
  }
  # IDENTIDADE PERDIDA (ex.: o operador apagou o names/<sid> ou a sessao trocou de sid num
  # /clear): sem projeto resolvido, o caminho acima aponta pra RAIZ BASE e o -Release responde
  # LOCK_ABSENT olhando no lugar errado -- enquanto o lock real segue preso no projeto, travando
  # todo mundo. Nesse caso varro os projetos atras de um lock que seja MEU (por sid) e uso ele.
  if (-not $Project -and $sid -and -not (Test-Path -LiteralPath $lock)) {
    foreach ($d in (Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue)) {
      if ($d.Name -in @('names','seen','inbox','processing','done','rejected','monitor','presence','state')) { continue }
      foreach ($cand in @((Join-Path $d.FullName '.bus-lock'), (Join-Path $d.FullName '.bus-lock-2'), (Join-Path $d.FullName '.bus-lock-3'))) {
        if (-not (Test-Path -LiteralPath $cand)) { continue }
        try {
          $LC = (Get-Content -LiteralPath $cand -Raw) | ConvertFrom-Json
          if ([string]$LC.sid -eq $sid) { $lock = $cand; $Project = $d.Name; break }
        } catch {}
      }
      if ($Project) { break }
    }
  }
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
