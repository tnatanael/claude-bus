# bus-gate.ps1 -- Hook UserPromptSubmit do BUS. Gate PRE-API do /bus.
# Objetivo: prevenir overload da API da conta Claude e economizar contexto. O lock e
# POR PROJETO (<projeto>/.bus-lock): serializa DENTRO de cada projeto (1 sessao ativa por
# projeto), mas projetos diferentes rodam em PARALELO -- permite 2+ frentes ao mesmo tempo.
# Tambem intercepta /bus-message (enfileira instrucao do operador SEM acordar o modelo).
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

function Get-GateSecret([string]$root) {
  # le (ou cria) o .bus-secret do projeto -- mesma logica do bus-send/bus-inbox.
  New-Item -ItemType Directory -Force -Path $root | Out-Null
  $path = Join-Path $root '.bus-secret'
  if (-not (Test-Path -LiteralPath $path)) {
    $val = [guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')
    $tmp = $path + '.' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.tmp'
    [System.IO.File]::WriteAllText($tmp, $val, (New-Object System.Text.UTF8Encoding($false)))
    try { Move-Item -LiteralPath $tmp -Destination $path -ErrorAction Stop }
    catch { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
  }
  return (Get-Content -LiteralPath $path -Raw -Encoding UTF8).Trim()
}

function Enqueue-OpMessage($base, $sid, $body) {
  # /bus-message: escreve um handoff operador->proprio-slug no inbox do projeto da sessao.
  # Retorna 'OK:<slug>:<projeto>', ou 'NO_SID'/'NO_IDENTITY' se a sessao nao se registrou.
  if (-not $sid) { return 'NO_SID' }
  $nf = Join-Path (Join-Path $base 'names') ($sid + '.txt')
  if (-not (Test-Path -LiteralPath $nf)) { return 'NO_IDENTITY' }
  $nl = @(Get-Content -LiteralPath $nf)
  $proj = 'default'; $slug = ''
  if ($nl.Count -ge 2) { $proj = $nl[0].Trim(); $slug = $nl[1].Trim() }
  elseif ($nl.Count -eq 1) { $proj = 'default'; $slug = $nl[0].Trim() }
  if (-not $slug) { return 'NO_IDENTITY' }
  $projRoot = if ($proj -and $proj -ne 'default') { Join-Path $base $proj } else { $base }
  $secret = Get-GateSecret $projRoot
  $inbox = Join-Path $projRoot 'inbox'
  New-Item -ItemType Directory -Force -Path $inbox | Out-Null
  $id = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,6)
  $final = Join-Path $inbox ('to-' + $slug + '__from-operador__' + $id + '.handoff')
  $tmp = $final + '.tmp'
  $lines = @('###BUS-START', 'id: ' + $id, 'from: operador', 'to: ' + $slug, 'auth: ' + $secret, 'reply_required: false', 'in_reply_to: ', '---', $body, '###BUS-END')
  [System.IO.File]::WriteAllText($tmp, (($lines -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
  Move-Item -LiteralPath $tmp -Destination $final
  return ('OK:' + $slug + ':' + $proj)
}

try {
  # Le o stdin como UTF-8 EXPLICITO: [Console]::In usa o code page do console (nao UTF-8) no
  # PS 5.1 -> acentos do prompt JSON (ex.: "e" com acento) corrompiam no /bus-message. O
  # StreamReader UTF-8 decodifica os bytes certos. Fallback pro reader padrao se falhar.
  $raw = ''
  try {
    $sr = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), [System.Text.Encoding]::UTF8)
    $raw = $sr.ReadToEnd(); $sr.Close()
  } catch { try { $raw = [Console]::In.ReadToEnd() } catch {} }
  $data = $null
  try { $data = $raw | ConvertFrom-Json } catch {}
  $prompt = ''; $sid = ''; $slug = ''; $project = ''
  if ($data) { $prompt = [string]$data.prompt; $sid = [string]$data.session_id }

  # 0. /bus-message <texto>: o operador enfileira uma instrucao pro proprio especialista
  # da sessao. O HOOK escreve o handoff (operador->slug) e BLOQUEIA o prompt (exit 2) ->
  # NAO acorda o modelo, custo ZERO de token. O especialista processa no proximo /bus.
  $bm = [regex]::Match($prompt, '(?is)^\s*/bus-message\s+(.+)$')
  if ($bm.Success) {
    $baseM = $env:CLAUDE_BUS_ROOT; if (-not $baseM) { $baseM = Join-Path $env:TEMP 'claude-bus' }
    try {
      $r = Enqueue-OpMessage $baseM $sid ($bm.Groups[1].Value.Trim())
      if ($r -like 'OK:*') {
        $pp = $r.Substring(3) -split ':', 2
        BusLog $baseM $sid $pp[0] 'op-message'
        [Console]::Error.WriteLine('BUS: mensagem enfileirada para ' + $pp[0] + ' (' + $pp[1] + ') -- sera processada no proximo /bus.')
      } else {
        [Console]::Error.WriteLine('BUS: esta sessao ainda nao se registrou no BUS -- rode /bus <slug> [projeto] primeiro, depois /bus-message.')
      }
    } catch { [Console]::Error.WriteLine('BUS: erro ao enfileirar a mensagem -- ' + $_.Exception.Message) }
    exit 2
  }

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
  # Raiz do projeto (usada no lock POR PROJETO e nas prioridades).
  $projRoot = if ($project -and $project -ne 'default') { Join-Path $base $project } else { $base }

  # 3. seen: mede idade antiga, depois regrava agora (prova de vida).
  $seenDir = Join-Path $base 'seen'
  New-Item -ItemType Directory -Force -Path $seenDir | Out-Null
  $seenFile = Join-Path $seenDir $sid
  $seenAgeMin = [double]::PositiveInfinity
  if (Test-Path -LiteralPath $seenFile) {
    $seenAgeMin = ((Get-Date) - (Get-Item -LiteralPath $seenFile).LastWriteTime).TotalMinutes
  }
  [System.IO.File]::WriteAllText($seenFile, (Get-Date).ToString('o'), (New-Object System.Text.UTF8Encoding($false)))

  # 3a. MANUTENCAO da estrutura do BUS (pre-API, ZERO trabalho do modelo). O BUS vive no %TEMP%,
  # que o Storage Sense do Windows limpa por IDADE (mtime). O gate GARANTE as pastas (recria as
  # que sumirem) e RENOVA o mtime de .bus-secret/names/.priority/pastas -> nao envelhecem, nao
  # sao apagados -> secret NAO rotaciona, sessao NAO perde registro/prioridade, modelo nao
  # reconstroi estrutura.
  # CONCORRENCIA (ate ~20 especialistas/projeto tocando os MESMOS arquivos): so tocamos o que ja
  # esta ENVELHECENDO (mtime > 6h) e cada operacao e isolada. Assim quase todo tique so LE o mtime
  # (barato, sem contencao); o toque real (escrita) sai ~4x/dia por projeto. Storage Sense limpa
  # por DIAS, entao 6h e folgado. Toque so mexe no mtime (metadado), nunca no conteudo.
  try {
    $mRoot = if ($project -and $project -ne 'default') { Join-Path $base $project } else { $base }
    foreach ($d in 'inbox','processing','done','rejected') {
      $dp = Join-Path $mRoot $d
      try { if (-not (Test-Path -LiteralPath $dp)) { New-Item -ItemType Directory -Force -Path $dp | Out-Null } } catch {}
    }
    $mCut = (Get-Date).AddHours(-6); $mNow = Get-Date
    foreach ($mp in @((Join-Path $mRoot '.bus-secret'), (Join-Path $mRoot '.priority'), (Join-Path $mRoot '.bus-paused'), (Join-Path $base '.bus-cron-interval'), $nameFile, (Join-Path $mRoot 'inbox'), (Join-Path $mRoot 'processing'), (Join-Path $mRoot 'done'), (Join-Path $mRoot 'rejected'))) {
      try { $mi = Get-Item -LiteralPath $mp -ErrorAction SilentlyContinue; if ($mi -and $mi.LastWriteTime -lt $mCut) { $mi.LastWriteTime = $mNow } } catch {}
    }
  } catch {}

  # 3b. CHAMADA MANUAL (/bus <args>) = CONFIG, NAO processa. Passa direto (exit 0): o modelo
  # so registra identidade/seta prioridade/re-arma o cron e PARA (sem ler o inbox). Nao usa o
  # lock (config nao processa, nao precisa serializar). A prioridade do 3o arg ja foi gravada
  # no passo 2a (rede). SO o BARE /bus (cron ou manual) processa o inbox.
  if ($isManual) { exit 0 }

  # 3c. PAUSA por projeto: se <projeto>/.bus-paused existe, o projeto esta PAUSADO -> nao pega
  # NOVOS handoffs (defer, custo zero). Quem ja esta processando (segurando o lock) termina o
  # turno normalmente -- o gate so age ANTES de acordar o modelo. Config (/bus <args>) e
  # /bus-message ja passaram antes daqui, entao seguem funcionando com o projeto pausado.
  if (Test-Path -LiteralPath (Join-Path $projRoot '.bus-paused')) {
    [Console]::Error.WriteLine('BUS: projeto ' + $project + ' PAUSADO -- deferido ate dar play no dashboard.')
    BusLog $base $sid $slug 'defer-paused'
    exit 2
  }

  # 4. Lock POR PROJETO (<projeto>/.bus-lock): serializa DENTRO do projeto; projetos
  # diferentes rodam em PARALELO. Tomado por OUTRA sessao do MESMO projeto e fresco -> defer.
  $lockFile = Join-Path $projRoot '.bus-lock'
  $now = [datetimeoffset]::Now
  if (Test-Path -LiteralPath $lockFile) {
    try {
      $L = (Get-Content -LiteralPath $lockFile -Raw) | ConvertFrom-Json
      $exp = [datetimeoffset]::Parse($L.expiry)
      if ($now -lt $exp -and $L.sid -ne $sid) {
        [Console]::Error.WriteLine('BUS: outro especialista esta trabalhando (lock global) -- deferido p/ o proximo ciclo.')
        BusLog $base $sid $slug ("defer-lock>" + ([string]$L.slug))
        exit 2
      }
    } catch {}   # lock corrompido/ilegivel -> trata como livre
  }

  # 5. PRIORIDADES do projeto: arquivo <projroot>/.priority, linhas "slug:N" (default 1000;
  # quanto MENOR, mais cede a vez). Depois varre o inbox: eu tenho pendente? e algum
  # especialista de prioridade MAIOR tem pendente?
  # $projRoot ja resolvido acima (passo 2).
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
  $myPending = $false; $higherPending = $false; $higherSlug = ''
  if (Test-Path -LiteralPath $inbox) {
    foreach ($c in (Get-ChildItem -LiteralPath $inbox -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -eq '.handoff' -and $_.Name -like 'to-*' })) {
      $txt = Get-Content -LiteralPath $c.FullName -Raw -ErrorAction SilentlyContinue
      if (-not ($txt -and ($txt -match '###BUS-END'))) { continue }
      $toSlug = if ($c.Name -match '^to-(.+?)__') { $matches[1] } else { '' }
      if ($toSlug -eq $slug) { $myPending = $true }
      elseif ($toSlug -ne '') {
        $xPrio = if ($prio.ContainsKey($toSlug)) { $prio[$toSlug] } else { 1000 }
        if ($xPrio -gt $myPrio) { $higherPending = $true; if (-not $higherSlug) { $higherSlug = $toSlug } }
      }
    }
  }

  # 5b. PRIORIDADE: se EU tenho trabalho e existe handoff p/ alguem de prioridade MAIOR,
  # CEDO a vez (defiro). Igual ou menor nao bloqueia. So vale quando EU tenho trabalho --
  # senao a logica normal de re-arme/empty segue valendo. (PO/coordenador: prioridade baixa
  # -> processa por ultimo.)
  if ($myPending -and $higherPending) {
    [Console]::Error.WriteLine('BUS: prioridade menor -- ha handoff p/ especialista de prioridade maior; cedendo a vez.')
    BusLog $base $sid $slug ("defer-prio>" + $higherSlug)
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
      $lockRoot2 = if ($project -and $project -ne 'default') { Join-Path $base2 $project } else { $base2 }
      $lf = Join-Path $lockRoot2 '.bus-lock'; $nw = [datetimeoffset]::Now
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
