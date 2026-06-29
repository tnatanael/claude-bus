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
# Fail-open BLINDADO: erro inesperado NAO trava prompt nao-/bus; mas pra /bus de sessao
# conhecida, tenta ADQUIRIR o lock mesmo apos o erro -- se outro o segura (fresco) defere
# (nao sobrepoe), senao adquire e passa COM o lock. Preserva o invariante mesmo sob falha.
# Forense: acquire/steal/defer-race/fail-open vao pra <base>/.bus-gate.log (best-effort).

$SEEN_STALE_MIN = 180     # >3h sem rodar -> deixa passar pro modelo re-armar
$LEASE_MIN      = 30      # lease bootstrap; o modelo pode refinar p/ estimate dentro do turno

function BusLog($base, $sid, $slug, $decision) {
  # append best-effort ao log forense; NUNCA lanca (logar nao pode afetar o gate).
  try {
    $lf = Join-Path $base '.bus-gate.log'
    try { $fi = Get-Item -LiteralPath $lf -ErrorAction SilentlyContinue; if ($fi -and $fi.Length -gt 524288) { Remove-Item -LiteralPath $lf -Force -ErrorAction SilentlyContinue } } catch {}
    $sidShort = if ($sid) { $sid.Substring(0, [Math]::Min(8, $sid.Length)) } else { '-' }
    $line = ("{0}`t{1}`t{2}`t{3}" -f ([datetimeoffset]::Now.ToString('o')), $decision, $sidShort, $slug)
    [System.IO.File]::AppendAllText($lf, $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
  } catch {}
}

try {
  $raw = [Console]::In.ReadToEnd()
  $data = $null
  try { $data = $raw | ConvertFrom-Json } catch {}
  $prompt = ''; $sid = ''; $slug = ''; $project = ''
  if ($data) { $prompt = [string]$data.prompt; $sid = [string]$data.session_id }

  # 1. So gateia /bus. Qualquer outro prompt passa na hora (fast-path, custo ~0).
  if ($prompt -notmatch '(?im)^\s*/bus(\s|$)') { exit 0 }
  if (-not $sid) { exit 0 }

  $base = $env:CLAUDE_BUS_ROOT
  if (-not $base) { $base = Join-Path $env:TEMP 'claude-bus' }

  # 2a. CRON vs MANUAL: o cron dispara bare "/bus" (sem args). Qualquer "/bus <args>" e
  # chamada MANUAL do operador -> deve RODAR (acquire+run, serializado pelo lock), nao
  # deferir em inbox vazio. Distincao limpa entre auto-recheck e intencao explicita.
  $isManual = ($prompt -match '(?im)^\s*/bus\s+\S')
  # Se traz prioridade (3o arg: /bus <slug> <projeto> <N>), grava em <projeto>/.priority
  # PRE-API -- assim um /bus manual com prioridade SEMPRE seta, mesmo que o gate defira
  # por lock depois. (O cron e bare, nunca manda prioridade.)
  $pm = [regex]::Match($prompt, '(?im)^\s*/bus\s+(\S+)\s+(\S+)\s+(\d+)\s*$')
  if ($pm.Success) {
    $pSlug = $pm.Groups[1].Value; $pProj = $pm.Groups[2].Value; $pPrio = $pm.Groups[3].Value
    try {
      $pRoot = if ($pProj -and $pProj -ne 'default') { Join-Path $base $pProj } else { $base }
      New-Item -ItemType Directory -Force -Path $pRoot | Out-Null
      $pf = Join-Path $pRoot '.priority'
      $keep = @()
      if (Test-Path -LiteralPath $pf) { $keep = @(Get-Content -LiteralPath $pf -EA SilentlyContinue | Where-Object { $_.Trim() -ne '' -and (($_ -split ':',2)[0]).Trim() -ne $pSlug }) }
      $keep += "${pSlug}:${pPrio}"
      [System.IO.File]::WriteAllText($pf, ($keep -join "`r`n") + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    } catch {}
  }

  # 2. Identidade do registro global names/<sid> (linha1=projeto, linha2=slug).
  $nameFile = Join-Path (Join-Path $base 'names') ($sid + '.txt')
  if (-not (Test-Path -LiteralPath $nameFile)) { exit 0 }   # nao registrado -> deixa registrar
  $nl = @(Get-Content -LiteralPath $nameFile)
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

  # 3b. CHAMADA MANUAL (/bus <args>) = CONFIG, NAO processa. Passa direto (exit 0): o modelo
  # so registra identidade/seta prioridade/re-arma o cron e PARA (sem ler o inbox). Nao usa o
  # lock (config nao processa, nao precisa serializar). A prioridade do 3o arg ja foi gravada
  # no passo 2a (rede). SO o BARE /bus (cron ou manual) processa o inbox.
  if ($isManual) { exit 0 }

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

  if ($myPending) {   # bare /bus com trabalho -> processa (serializado pelo lock)
    # acquire: cria exclusivo; se ja existe e e MEU ou EXPIRADO, sobrescreve (steal).
    $obj = (@{ sid=$sid; slug=$slug; project=$project; since=$now.ToString('o'); expiry=$now.AddMinutes($LEASE_MIN).ToString('o') } | ConvertTo-Json -Compress)
    $enc = New-Object System.Text.UTF8Encoding($false)
    $acquired = $false; $how = 'acquire'
    try {
      $fs = [System.IO.File]::Open($lockFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
      $b = [System.Text.Encoding]::UTF8.GetBytes($obj); $fs.Write($b,0,$b.Length); $fs.Close(); $acquired = $true
    } catch {
      try {
        $L2 = (Get-Content -LiteralPath $lockFile -Raw) | ConvertFrom-Json
        $exp2 = [datetimeoffset]::Parse($L2.expiry)
        if ($L2.sid -eq $sid -or $now -ge $exp2) {
          [System.IO.File]::WriteAllText($lockFile, $obj, $enc); $acquired = $true; $how = 'acquire-steal'
        }
      } catch {}
    }
    if ($acquired) { BusLog $base $sid $slug $how; exit 0 }
    [Console]::Error.WriteLine('BUS: lock tomado na corrida -- deferido.')
    BusLog $base $sid $slug 'defer-race'
    exit 2
  }

  # 6. Inbox vazia -- so chega aqui o BARE /bus sem trabalho (manual/config ja saiu no passo 3b).
  if ($seenAgeMin -gt $SEEN_STALE_MIN) { exit 0 }   # gap > 3h -> deixa re-armar o cron
  [Console]::Error.WriteLine('BUS: nada pendente -- pulando (cron segue armado, custo zero).')
  exit 2

} catch {
  # Fail-open BLINDADO. Nunca trava prompt nao-/bus nem sem sid. Mas pra /bus de sessao
  # conhecida: tenta ADQUIRIR o lock mesmo apos o erro; se outro o segura (fresco) -> defere
  # (nao sobrepoe); senao adquire e passa COM o lock. Preserva o invariante mesmo sob falha.
  $base2 = $env:CLAUDE_BUS_ROOT; if (-not $base2) { $base2 = Join-Path $env:TEMP 'claude-bus' }
  try {
    if ($prompt -match '(?im)^\s*/bus(\s|$)' -and $sid) {
      $lf = Join-Path $base2 '.bus-lock'; $nw = [datetimeoffset]::Now
      $obj2 = (@{ sid=$sid; slug=$slug; project=$project; since=$nw.ToString('o'); expiry=$nw.AddMinutes($LEASE_MIN).ToString('o') } | ConvertTo-Json -Compress)
      $enc2 = New-Object System.Text.UTF8Encoding($false); $got = $false
      try {
        $fx = [System.IO.File]::Open($lf, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $bx = [System.Text.Encoding]::UTF8.GetBytes($obj2); $fx.Write($bx,0,$bx.Length); $fx.Close(); $got = $true
      } catch {
        try {
          $LX = (Get-Content -LiteralPath $lf -Raw) | ConvertFrom-Json
          if ($LX.sid -eq $sid -or $nw -ge ([datetimeoffset]::Parse($LX.expiry))) {
            [System.IO.File]::WriteAllText($lf, $obj2, $enc2); $got = $true
          }
        } catch {}
      }
      if ($got) { BusLog $base2 $sid $slug 'failopen-acquire'; exit 0 }
      BusLog $base2 $sid $slug 'failopen-defer'; exit 2
    }
  } catch {}
  BusLog $base2 $sid $slug 'failopen-pass'
  exit 0
}
