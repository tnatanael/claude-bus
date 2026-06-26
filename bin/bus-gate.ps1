# bus-gate.ps1 -- Hook UserPromptSubmit do BUS. Gate PRE-API do /bus.
# Objetivo: prevenir overload da API da conta Claude (limite e da CONTA, nao do
# projeto) e economizar contexto. Por isso o lock e UNICO e GLOBAL na maquina
# (na base, nao por projeto): se qualquer especialista de qualquer projeto esta
# trabalhando, os outros deferem.
#
# Regras (so para prompt que comeca com /bus; o resto passa direto):
#   - lock global tomado por OUTRA sessao (fresco)        -> exit 2 (defer, custo 0)
#   - inbox tem handoff pendente pra mim                  -> acquire lock + exit 0 (trabalha)
#   - inbox vazia e seen velho (>3h, possivel pos-restart)-> exit 0 (deixa re-armar o cron)
#   - inbox vazia e seen fresco                           -> exit 2 (skip de graca)
# Sempre regrava seen/<sid> (prova de vida pro dashboard, mesmo deferindo).
# Fail-open: qualquer erro -> exit 0 (NUNCA trava um prompt real).

$SEEN_STALE_MIN = 180     # >3h sem rodar -> deixa passar pro modelo re-armar
$LEASE_MIN      = 30      # lease bootstrap; o modelo pode refinar p/ estimate dentro do turno

try {
  $raw = [Console]::In.ReadToEnd()
  $data = $null
  try { $data = $raw | ConvertFrom-Json } catch {}
  $prompt = ''; $sid = ''
  if ($data) { $prompt = [string]$data.prompt; $sid = [string]$data.session_id }

  # 1. So gateia /bus. Qualquer outro prompt passa na hora (fast-path, custo ~0).
  if ($prompt -notmatch '(?im)^\s*/bus(\s|$)') { exit 0 }
  if (-not $sid) { exit 0 }

  $base = $env:CLAUDE_BUS_ROOT
  if (-not $base) { $base = Join-Path $env:TEMP 'claude-bus' }

  # 2. Identidade do registro global names/<sid> (linha1=projeto, linha2=slug).
  $nameFile = Join-Path (Join-Path $base 'names') ($sid + '.txt')
  if (-not (Test-Path -LiteralPath $nameFile)) { exit 0 }   # nao registrado -> deixa registrar
  $nl = @(Get-Content -LiteralPath $nameFile)
  $project = ''; $slug = ''
  if ($nl.Count -ge 2) { $project = $nl[0].Trim(); $slug = $nl[1].Trim() }
  elseif ($nl.Count -eq 1) { $project = 'default'; $slug = $nl[0].Trim() }
  if (-not $slug) { exit 0 }

  # 3. seen: mede idade antiga, depois regrava agora (prova de vida).
  $seenDir = Join-Path $base 'seen'
  New-Item -ItemType Directory -Force -Path $seenDir | Out-Null
  $seenFile = Join-Path $seenDir $sid
  $seenAgeMin = [double]::PositiveInfinity
  if (Test-Path -LiteralPath $seenFile) {
    $seenAgeMin = ((Get-Date) - (Get-Item -LiteralPath $seenFile).LastWriteTime).TotalMinutes
  }
  [System.IO.File]::WriteAllText($seenFile, (Get-Date).ToString('o'), (New-Object System.Text.UTF8Encoding($false)))

  # 4. Lock GLOBAL (1 por maquina). Tomado por outro e fresco -> defer.
  $lockFile = Join-Path $base '.bus-lock'
  $now = [datetimeoffset]::Now
  if (Test-Path -LiteralPath $lockFile) {
    try {
      $L = (Get-Content -LiteralPath $lockFile -Raw) | ConvertFrom-Json
      $exp = [datetimeoffset]::Parse($L.expiry)
      if ($now -lt $exp -and $L.sid -ne $sid) {
        [Console]::Error.WriteLine('BUS: outro especialista esta trabalhando (lock global) -- deferido p/ o proximo ciclo.')
        exit 2
      }
    } catch {}   # lock corrompido/ilegivel -> trata como livre
  }

  # 5. PRIORIDADES do projeto: arquivo <projroot>/.priority, linhas "slug:N" (default 1000;
  # quanto MENOR, mais cede a vez). Depois varre o inbox: eu tenho pendente? e algum
  # especialista de prioridade MAIOR tem pendente?
  $projRoot = $base
  if ($project -and $project -ne 'default') { $projRoot = Join-Path $base $project }
  $prio = @{}
  $prioFile = Join-Path $projRoot '.priority'
  if (Test-Path -LiteralPath $prioFile) {
    foreach ($ln in @(Get-Content -LiteralPath $prioFile -ErrorAction SilentlyContinue)) {
      $kv = $ln -split ':', 2
      if ($kv.Count -eq 2) { $n = 0; if ([int]::TryParse($kv[1].Trim(), [ref]$n)) { $prio[$kv[0].Trim()] = $n } }
    }
  }
  $myPrio = if ($prio.ContainsKey($slug)) { $prio[$slug] } else { 1000 }

  $inbox = Join-Path $projRoot 'inbox'
  $myPending = $false; $higherPending = $false
  if (Test-Path -LiteralPath $inbox) {
    foreach ($c in (Get-ChildItem -LiteralPath $inbox -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -eq '.handoff' -and $_.Name -like 'to-*' })) {
      $txt = Get-Content -LiteralPath $c.FullName -Raw -ErrorAction SilentlyContinue
      if (-not ($txt -and ($txt -match '###BUS-END'))) { continue }
      $toSlug = if ($c.Name -match '^to-(.+?)__') { $matches[1] } else { '' }
      if ($toSlug -eq $slug) { $myPending = $true }
      elseif ($toSlug -ne '') {
        $xPrio = if ($prio.ContainsKey($toSlug)) { $prio[$toSlug] } else { 1000 }
        if ($xPrio -gt $myPrio) { $higherPending = $true }
      }
    }
  }

  # 5b. PRIORIDADE: se EU tenho trabalho e existe handoff p/ alguem de prioridade MAIOR,
  # CEDO a vez (defiro). Igual ou menor nao bloqueia. So vale quando EU tenho trabalho --
  # senao a logica normal de re-arme/empty segue valendo. (PO/coordenador: prioridade baixa
  # -> processa por ultimo.)
  if ($myPending -and $higherPending) {
    [Console]::Error.WriteLine('BUS: prioridade menor -- ha handoff p/ especialista de prioridade maior; cedendo a vez.')
    exit 2
  }

  if ($myPending) {
    # acquire: cria exclusivo; se ja existe e e MEU ou EXPIRADO, sobrescreve (steal).
    $obj = (@{ sid=$sid; slug=$slug; project=$project; since=$now.ToString('o'); expiry=$now.AddMinutes($LEASE_MIN).ToString('o') } | ConvertTo-Json -Compress)
    $enc = New-Object System.Text.UTF8Encoding($false)
    $acquired = $false
    try {
      $fs = [System.IO.File]::Open($lockFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
      $b = [System.Text.Encoding]::UTF8.GetBytes($obj); $fs.Write($b,0,$b.Length); $fs.Close(); $acquired = $true
    } catch {
      try {
        $L2 = (Get-Content -LiteralPath $lockFile -Raw) | ConvertFrom-Json
        $exp2 = [datetimeoffset]::Parse($L2.expiry)
        if ($L2.sid -eq $sid -or $now -ge $exp2) {
          [System.IO.File]::WriteAllText($lockFile, $obj, $enc); $acquired = $true
        }
      } catch {}
    }
    if ($acquired) { exit 0 }
    [Console]::Error.WriteLine('BUS: lock tomado na corrida -- deferido.')
    exit 2
  }

  # 6. Inbox vazia.
  if ($seenAgeMin -gt $SEEN_STALE_MIN) { exit 0 }   # gap > 3h -> deixa re-armar o cron
  [Console]::Error.WriteLine('BUS: nada pendente -- pulando (cron segue armado, custo zero).')
  exit 2

} catch {
  exit 0   # fail-open
}
