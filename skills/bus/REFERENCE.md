# BUS — referência de mecânica (não injetada)

Este arquivo NÃO é injetado a cada `/bus` — o `SKILL.md` carrega só o núcleo operacional. Aqui fica o **porquê** de cada peça, pra debug/manutenção sem inflar o contexto de toda passada.

## Limitações operacionais (saíram do SKILL.md — não são regra de execução)
- **Projeto = isolamento.** Só vê/endereça quem está no mesmo projeto.
- **Sessão precisa estar ABERTA.** O cron é de sessão: morre com o app. Reabriu → `/bus <projeto> <slug>`, ou `/bus-reload` só pra religar o cron.
- **Entrega é automática:** o cron do destino processa sozinho — não anuncie nem peça `/bus` manual. Destino fechado → o handoff espera no inbox dele (visível no dashboard) até reabrir.
- **Sem auto-continuação:** o gate só libera o tique quando há trabalho **seu** (inbox **ou** preso em `processing/` há ≥30 min). Tarefa longa que não fecha num wake precisa de **self-handoff** — não existe "próximo tick" gratuito com inbox vazio.
- **Fim do fluxo:** quem declara é o **controlador (prio 0)**; inbox vazio dos outros ≠ projeto acabado.
- **`/bus-message <texto>`** enfileira instrução do operador **sem acordar o modelo** (o hook escreve o handoff e bloqueia o prompt). **`/bus-reload`** re-arma só o cron.

## Por que a SKILL é curta (e precisa continuar)
A SKILL é **re-injetada como mensagem de usuário a cada `/bus`**, e **cada cópia fica no histórico**. Medido em 12/08/2026 numa sessão real: **~60 injeções/hora** (tique de 1 min) — com a SKILL em 19 KB isso era **~286k tokens/hora só de re-injeção**, o que enche uma janela de 1 M em ~3h30 **antes de qualquer trabalho**. Sessões chegaram a ter **47% do transcript** só de cópias da SKILL, e o sintoma final é `Prompt is too long` com compactação em cascata (a compactação devolvia ~950 KB num teto de 1 M, estourando no turno seguinte). Por isso a SKILL foi cortada de 19 KB → ~9 KB (v0.7.9): **todo "porquê" mora aqui**, que não é injetado. **Regra:** antes de acrescentar parágrafo no `SKILL.md`, pergunte se é *execução* (fica) ou *explicação* (vem pra cá). Cada KB no SKILL custa ~250 tokens × centenas de passadas por dia.

## Por que economia de tokens importa aqui
O custo **fixo** de uma passada de PROCESSAMENTO (SKILL injetada + dança de cron + leitura do inbox) domina o corpo marginal de um handoff em ~9:1. Logo, a maior alavanca é **reduzir o número de wakes** (não o tamanho do corpo): um spec completo executado numa passada vale muito mais que a mesma frente fatiada em vários round-trips. Daí a doutrina do `SKILL.md` §3 (um spec/uma passada, sem ack, sem status avulso) e §5 (controlador consolida).

## Gate pré-API (hook `UserPromptSubmit`, `bus-gate.ps1`/`.sh`)
Roda ANTES de o modelo acordar; só age em prompt que começa com `/bus` (o resto passa em `exit 0`). Objetivo: **não estourar o limite da CONTA Claude** (o limite é da conta, não do projeto) e economizar contexto.
- **Lock POR PROJETO** `<projeto>/.bus-lock` (JSON, lease auto-libera se a sessao travar/cair -- default 60 min, configuravel no dashboard, ver secao abaixo): serializa DENTRO do projeto — se **outra** sessão **do mesmo projeto** o segura fresco → `exit 2` (defer, custo zero de API). Projetos diferentes têm locks independentes → **rodam em PARALELO**. Só o BARE `/bus` com trabalho o adquire. (Era global até a v0.6.30; virou por-projeto pra permitir 2+ frentes simultâneas. Tradeoff: o pico de API sobe com o nº de projetos ativos — o limite ainda é da CONTA.)
- **Pausa por projeto** `<projeto>/.bus-paused`: se o marcador existe, o gate defere o processamento (bare `/bus`) daquele projeto (`exit 2`, log `defer-paused`) — **para de pegar handoffs novos SEM interromper** quem já está no meio (o gate só age ANTES de acordar o modelo; a sessão que segura o lock termina o turno). CONFIG (`/bus <args>`) e `/bus-message` NÃO passam por essa checagem (seguem funcionando pausado). O marcador é criado/removido pelo dashboard (`POST /api/pause`, única escrita dele) e tem o mtime refrescado pela manutenção (não é limpo pelo Storage Sense numa pausa longa).
- **Projeto obrigatório** (v0.6.32): o `bus-name -Set` exige `-Project` (sem ele, ou com `default`, devolve `NEED_PROJECT` e o modelo pergunta) — o projeto `default` foi removido. Registros antigos de 1 linha ainda são lidos como `default` (compat), mas nenhum novo é criado assim.
- **CONFIG vs PROCESS:** `/bus <args>` (manual) = config → passa em `exit 0` **sem** o lock (não processa, não serializa); a prioridade do 3º arg é gravada pré-API como rede. Só o **bare** `/bus` processa.
- **Prioridade** (`<projroot>/.priority`, linhas `slug:N`, default 1000, menor cede mais): se EU tenho trabalho E há handoff pra alguém de prioridade MAIOR, o gate me faz **ceder a vez** (`exit 2`). É o que faz o controlador (prioridade baixa) processar por último.
- **Inbox vazio:** seen fresco → `exit 2` (skip grátis); seen >3h → `exit 0` (deixa re-armar o cron pós-restart).
- **Fail-open blindado:** erro inesperado nunca trava um prompt não-`/bus`; mas num `/bus` de sessão conhecida ele ainda tenta adquirir o lock após o erro (se outro segura, defere; senão passa COM o lock) — preserva a serialização mesmo sob falha.
- **Manutenção de estrutura (pré-API, sem trabalho do modelo):** o BUS vive no `%TEMP%`, que o Storage Sense do Windows limpa por idade. O gate garante as pastas e renova o mtime de `.bus-secret`/`names`/`.priority` **só do que já passou de 6h** (evita contenção com ~20 especialistas tocando os mesmos arquivos; toque só mexe no mtime, nunca no conteúdo). Assim o secret não rotaciona e a sessão não perde registro/prioridade.
- **Defer SILENCIOSO (v0.6.44):** todo `exit 2` é renderizado pelo app como um card **"Um hook bloqueou seu prompt"** com o texto do *stderr*. Como o tick ocioso dispara a cada N min em CADA sessão, isso enchia a conversa de cards. Os defers **automáticos** (inbox vazia / lock / prioridade / race / pausa) agora saem **calados** — `exit 2` sem stderr. O bloqueio continua **obrigatório**: é ele que impede o wake do modelo (custo zero); só o barulho saiu. O rastro fica no `.bus-gate.log` + no `seen/<sid>` (prova de que o tick rodou). **Stderr só nos caminhos que o operador acionou na mão** (`/bus-message` ok/erro), onde a resposta é esperada. ⚠️ Não reintroduza `Write-Error`/`>&2` nos defers automáticos.
- **SID TROCOU — auto-cura do `/clear` (v0.7.8):** quando o app trava e o operador dá `/clear`, a sessão ganha um **sid novo**. Só que o `.bus-lock` continua gravado com o **sid antigo**, e o lock é comparado **por sid** — então a sessão nova não reconhece o próprio lock, o `-Release` responde `LOCK_NOT_MINE`, e o **projeto inteiro fica preso até o lease vencer** (todo mundo deferindo). Caso real em 12/08/2026 (`pd-portal-dev1`): o operador teve que apagar o `.bus-lock` na mão. **Chave da correção:** o registro de um slug é **exclusivo** (o `bus-name -Set` evicta os outros sids do mesmo projeto+slug), então **um lock em nome do MEU slug só pode ser de uma encarnação anterior de mim**. Com isso, três caminhos se curam sozinhos: (1) o **gate** não defere mais nesse caso e rouba o lock no acquire (`acquire-sid-trocado`); (2) o **re-arme** (`/bus <projeto> <slug>`) libera o órfão e devolve `LOCK_ORFAO_LIBERADO=<sid8>`, que o modelo reporta; (3) o **`bus-lock -Release`** sem identidade resolvida (ex.: o `names/<sid>` foi apagado) passou a **varrer os projetos** atrás de um lock com o meu sid, em vez de olhar a raiz base e responder `LOCK_ABSENT` no lugar errado. ⚠️ O isolamento continua: lock **de outro slug**, fresco, segue bloqueando normalmente.
- **Log forense** `<base>/.bus-gate.log`: `acquire`/`acquire-steal`/`defer-race`/`defer-lock>slug`/`defer-prio>slug`/`failopen-*`/`release`, best-effort, auto-limita ~512 KB.

## Cron de auto-recheck (por que bare, por que desarmar)
- **In-harness:** o "wake" sem o operador é o harness re-invocando a própria sessão (cron/`/loop`). Um processo externo NÃO consegue acordar o chat — por isso não há daemon/monitor; a recuperação é in-harness.
- **Bare `/bus`:** o cron dispara **bare** (sem args) de propósito — é o sinal que distingue **auto-recheck** de **chamada manual** (`/bus <args>` = config). A identidade vem do `names/<sid>`.
- **Re-arma do zero:** pós-restart o `CronList` pode listar um cron *phantom* (some do painel "Tarefas em segundo plano" mas continua no `CronList`) que **não dispara**. Por isso todo `/bus` apaga os `/bus` antigos e cria um novo, em vez de confiar no `CronList`.
- **⚠️ só `*/N` ou valor único disparam** — vírgula (`"<M>,<M2>"`) e `"M/30"` o harness aceita/lista mas **não** dispara.
- **Intervalo do cron (default `*/5`), o MESMO pra toda a frota:** não há minuto/offset por-sessão — todos armam `*/<N> * * * *` com o mesmo `N`. O `N` é **config GLOBAL** (`<base>/.bus-cron-interval`, minutos, clamp 1–30, default 5), **ajustável pelo stepper "check" do dashboard** (`POST /api/cron-interval`). O `bus-name`/`bus-inbox` leem esse arquivo e devolvem `BUS_CRON_INTERVAL=N`; o modelo arma `*/N` (SKILL passos 2/7 + bus-reload). **Propagação:** cada especialista pega o novo `N` **no próximo arm** (~1 ciclo — não é instantâneo, igual foi o `*/1`→`*/5`). Barato: o gate defere tick vazio/bloqueado pré-API (zero API); o jitter do harness dispersa os disparos. **Trade-off:** `N` maior = menos overhead, mais latência pra pegar um handoff (até ~N min + jitter). (O antigo `BUS_CRON_MINUTE` — minuto determinístico por-sid — foi **removido** por ser vestigial. NÃO confunda com o `BUS_CRON_INTERVAL`, que é o `N` do `*/N` e é USADO.)
- **Cron de sessão:** some se o app fechar (re-armado no próximo `/bus`; ou só o cron via `/bus-reload`), expira em 7 dias, só dispara com o REPL ocioso.

### A "dança" desarma/re-arma e a alternativa gate-driven (NÃO implementada)
Hoje a proteção contra auto-interrupção é **do modelo**: o ramo PROCESSAR desarma o cron no início (passo 2) e re-arma no fim (passo 7) — ~5-7 tool calls de overhead por passada. O gate **não** cala o próprio tick da sessão: quando o tick da própria sessão dispara e ela ainda segura o lock, o gate re-adquire esse lock e a acorda (o defer-por-lock só barra o tick de OUTRA sessão).

**Por que NÃO mover isso pro gate (ideia DESCARTADA):** deferir o próprio tick no gate deixaria o cron **permanente** (nunca re-criado). Na prática, um cron loop permanente **degrada em phantom depois de algumas horas** — para de disparar / some sozinho / acumula e perde referência (observado em operação real; causa exata desconhecida). **Re-armar do zero a cada processamento** (desarma no início do passo 2, cria de novo no passo 7) é o que mantém o loop **fresco** — por isso é load-bearing, não é só anti-interrupção. Logo a dança do cron **fica**. O que dá pra otimizar é tirar do modelo o trabalho **mecânico** (mover handoffs inbox→processing→done, resolver identidade) via script — não o ciclo do cron.

## Desativar (botão do dashboard) — `BUS-SHUTDOWN`
Encerra o BUS **do projeto selecionado**. O dashboard (`POST /api/shutdown`) enfileira um handoff `operador→slug` cujo corpo começa com **`BUS-SHUTDOWN`** para **cada especialista ATIVO (chip verde)** do projeto. Amarelo/vermelho são **pulados de propósito** (decisão do operador): mandar pra quem já está offline só deixaria lixo parado no inbox dele — e se ele voltar, segue rodando normal (o operador desativa de novo).

Ao processar esse handoff, o especialista **desarma o cron e NÃO re-arma** (`SKILL.md` passo 7, exceção), libera o lock e encerra **em silêncio** (sem retorno/despedida — ninguém está esperando). É a **única exceção autorizada** à doutrina "mantenha o fio vivo" (§5): aqui parar é o certo, porque a ordem é explícita do operador.

**Por que NÃO usa a pausa:** o marcador `.bus-paused` faz o gate deferir o tique — o especialista nunca acordaria pra receber o shutdown. Desativar depende do tique passar. Se quiser as duas coisas, desative primeiro e pause depois que os chips ficarem vermelhos. **Pra religar:** `/bus <projeto> <slug>` em cada sessão (o cron volta no arme do passo 2).

## /bus-schedule — escopo de projeto (v0.7.7)
Os agendamentos vivem num diretório **global** (`~/.claude/bus-schedules/<slug>/`), fora da árvore do BUS — é lá que ficam o `body.txt`, o `schedule.meta` e os wrappers que a tarefa do SO executa. Mas **cada agendamento pertence a um projeto** (`project=` no `schedule.meta`, gravado na criação).

Sem filtro, o `list` mostrava os agendamentos de **todos** os projetos e o `remove` apagava qualquer um por nome de slug — o que fura o isolamento que vale no resto do BUS (você só vê e endereça quem está no seu projeto). Por isso os dois passaram a receber `-Project`/`--project`:

- **`list`** mostra só os do seu projeto e informa quantos ficaram de fora (`(N agendamento(s) de OUTRO projeto omitido(s))`) — o especialista sabe que existe algo fora do escopo sem ver o quê.
- **`remove`** **recusa** se o slug pertencer a outro projeto (`OUTRO_PROJETO=<projeto>`) e não apaga nada. Sem essa guarda, uma colisão de nome de slug entre projetos apagaria a tarefa do SO **e** os artefatos de outra frente — irreversível.
- Sem `-Project` os dois voltam a ser globais: é o modo do **operador**, pra auditar a máquina inteira.
- Agendamento antigo cujo `meta` não tem `project=` não casa com nenhum filtro → aparece só no `list` global (some da visão do especialista, mas não do radar do operador).

## `0b ESCOPO` — a atribuição é a primeira coisa que o agente esquece (v0.9.14)

**O sintoma veio da operação, não da teoria:** especialistas de vez em quando "começam a fazer coisas que não são deles". Faz sentido — eles são long-lived e o `CLAUDE.md` do projeto entra no contexto **uma vez**, no começo da sessão. Depois de dezenas de wakes, compactações e `/clear`, a atribuição é justamente o que some primeiro: não é repetida em lugar nenhum, enquanto o corpo do handoff — que muitas vezes pede mais do que é dele — chega **fresco** a cada tique. A regra tinha de competir com o texto do handoff no mesmo turno.

**Por isso a regra foi pro protocolo impresso, não pra skill.** O `BUS_PROTOCOL` só sai quando há trabalho, ou seja, exatamente nos ticks que **passam pro LLM** (lock adquirido, bloco no inbox); tique ocioso não paga nada. E ele é a coisa mais recente do contexto no instante em que o agente decide o que fazer. Custo: **634 bytes (~160 tokens) por wake produtivo** — o protocolo foi de ~2,9KB pra 3,5KB.

**As duas metades importam.** Só *"faça o que é seu"* transformaria GAP em paralisia: o agente pararia o turno inteiro esperando alinhamento. Por isso o 0b manda **escalar e seguir** — descreve o GAP num handoff pro controlador e continua com o resto do que é dele.

**`BUS_CONTROLLER=` fecha o buraco entre a regra e a ação.** Sem ele o especialista teria de ler o `.priority` pra descobrir pra quem escalar e, na dúvida, decidiria sozinho — que é exatamente o comportamento que o 0b existe pra impedir. Sai só pros `background`: o controlador não escala GAP pra si mesmo, ele alinha com o operador (e a linha de papel dele passou a dizer isso).

**A dependência que o operador precisa saber:** o 0b manda reler a seção **`Domínios — quem é dono de quê`** do `CLAUDE.md` do projeto. Seção vazia = o passo não tem o que ler e a regra vira decoração, com cada especialista inventando o próprio recorte de novo. O esqueleto da v0.9.8 já tem a seção; **preenchê-la é o que faz o 0b existir.**

## Slots de lock: de 1 para até 3 (v0.9.9)

O lock era 1 por projeto — **1 especialista trabalhando por vez**. Agora a capacidade é configurável (1..3) em `<projeto>/.bus-slots`, pelo stepper `slots:` do dashboard.

**Por que foi barato:** o acquire já era **atômico** (`File.Open(..., CreateNew, ..., FileShare.None)` no `.ps1`, `set -o noclobber` + `>` no `.sh` — ambos O_EXCL). Test-and-set atômico é a parte difícil de qualquer esquema de N slots; ela já estava paga. O resto é um laço nos slots e um arquivo de capacidade.

**Slot 1 continua chamando `.bus-lock`** (2 e 3 são `.bus-lock-2`/`.bus-lock-3`). Não é estética: um gate **antigo** só conhece esse nome, então disputa o slot 1 e ignora os outros — a frota migra em lote sem corromper nada e sem janela quebrada.

**Baixar a capacidade não expulsa ninguém.** Ela só é lida na hora de *adquirir*, então o slot excedente simplesmente não é reocupado quando o holder solta. É drenagem — e sai de graça do desenho, não precisou de código.

**A consequência que quase passou batido: a cessão por prioridade fica errada com N>1.** O gate cede a vez (`defer-prio`) quando alguém de prioridade maior tem pendente. Isso faz sentido com **um** slot: você abre mão da única vaga. Com 3, ceder seria ficar ocioso com vaga na mesa.

A **primeira** correção foi `freeSlots <= 1` ("sobrou mais de uma vaga? não cedo") e ela estava **errada** — presume que a vaga fica **reservada** até o de prioridade maior acordar. Não fica: cada sessão tica no seu minuto e **quem chega primeiro leva**. Medido em produção (rh-proxima, 3 slots), o operador viu antes de mim:

```
01:14:07  acquire  process-reviewer   (prio 10 — deveria ceder)
01:14:18  acquire  dev-backend        (pegou a "vaga sobrando" 11s depois)
01:14:30  defer    dev-frontend       (prio 1000 — era quem tinha a vez)
01:16:31  acquire  dev-frontend       (2 minutos atrasado)
```

A regra correta **reserva**: cedo se as vagas livres **não cobrem** todos os slugs distintos de prioridade maior com pendência — `freeSlots <= higherSlugs.Count`. Verificado nos dois shells, com 2 de prioridade maior pendentes:

| capacidade | vagas livres | decisão |
|---|---|---|
| 1 | 1 | cede (regra clássica intacta) |
| 2 | 2 | cede — as 2 vagas são deles |
| 3 | 3 | passa — pega a 3ª e deixa 2 |

Lição geral: **num sistema de tique, "há recurso livre agora" não é "haverá recurso quando o outro acordar".** Reservar é a única forma de a ordem configurada sobreviver à corrida entre tiques. (Ceder sempre pode fazer o de número baixo esperar muito quando os de cima nunca esvaziam — isso é inerente ao "cede a vez", não efeito dos slots.)

**Terceira correção: reserva não vale pra quem já está com slot.** A regra acima ainda guardava vaga pra quem estava **trabalhando naquele instante** — e o resultado era uma vaga eternamente parada. Medido em 19/08 (`rh-proxima`, capacidade 2): `e2e` segurando o slot 1 com um handoff próprio ainda no inbox; `process-reviewer` (prio 10) com 12 pendentes e o **slot 2 livre** levando `defer-prio>e2e` tique após tique. Guardar a segunda vaga pro `e2e` não adiantava a vez dele um segundo — ele já tinha a vez na primeira. Agora quem aparece nos locks vivos (`$busySlugs`) **sai da conta** do `higherSlugs`. A varredura olha os **3** arquivos, não só os da capacidade: um slot em drenagem também está trabalhando. O teste da matriz (8 cenários × 2 shells) inclui esse caso e o do dreno.

**Release e auto-cura passaram a varrer os 3 slots.** `bus-lock -Release` procura o slot com o **meu sid** (antes olhava só o `.bus-lock`); o `bus-name` faz o mesmo procurando o **meu slug** com sid velho (auto-cura do `/clear`). Sem isso, quem estivesse no slot 2 ou 3 nunca liberaria — e o slot ficaria preso até o lease vencer.

**O caminho fail-open do gate continua usando só o slot 1**, de propósito: sob erro inesperado, ser mais conservador (menos concorrência) é o comportamento certo.

**O risco não é o código, é operacional** — e por isso o default é 1 e a capacidade é **por projeto**:
- o lock protegia, sem ninguém pedir, contra **dois especialistas rodando `git` no mesmo repo**. Com N>1 isso acaba. Em projetos onde cada um tem sua subpasta o risco é menor; quem circula pela árvore inteira (arquiteto) é o caso a vigiar.
- **cada slot é uma sessão do Claude trabalhando**. Nesta máquina foi medido 94,7% de RAM e 100% de CPU com uma frota ociosa e um `vitest` rodando. Subir de 1 para 2 e observar é o caminho; 3 é teto, não meta.

## Tarefa pendurada mata o tique (v0.9.22)

O tique do BUS é o harness **re-invocando a sessão**, e ele só entra quando a sessão está **ociosa**. Enquanto um comando está rodando em foreground, ou enquanto uma tarefa de fundo continua viva, o cron não dispara — a sessão simplesmente **para de aparecer no BUS**, sem erro, sem log, sem nada no dashboard além de um especialista que ficou quieto.

Medido em 20/08/2026 no `rh-proxima`: a sessão `po`, a única que segurava um monitor de fundo, rodou **1 tique o dia inteiro**; os pares rodaram de **99 a 235**. Foi o que motivou trocar a vigia do `bus-git-watch` de monitor pendurado por **cron horário de passada única** (v0.9.18).

O que faltava era generalizar. A doutrina estava só na skill do `bus-git-watch` — quem nunca invocou `/bus-git-watch` nunca a leu, e o caso real que reabriu o assunto não tinha nada a ver com git: era um `ssh` sem `-o ConnectTimeout`, esperando para sempre uma máquina que não respondia. Vale para qualquer comando que **sai da máquina** — `ssh`, `gh`, `curl`, suíte de teste, deploy.

Por isso a regra virou **passo `0d` do protocolo** (impresso junto com o resto, custo zero em tique ocioso) e um bullet no passo 3 do `SKILL.md`: **timeout explícito em tudo que sai da máquina; nada de foreground longo, laço `for`+`sleep` ou espera sem prazo.** Precisa mesmo de algo longo? Dispare em background, **encerre o wake já** (re-armar cron + liberar lock) e feche quando a tarefa reacordar a sessão — o que o passo 3 do `SKILL.md` já mandava fazer pelo lock, e agora manda também pelo tique.

⚠️ Nada disso é mecânica nova: o gate, o lock e o cron não mudaram. É o agente que precisa parar de se auto-sabotar durante o próprio wake — e o modo de falha é silencioso, que é o que o torna caro.
## Eficiência do ciclo de desenvolvimento: o custo é o WAKE (v0.9.21)

O operador viu o sintoma antes de mim: *"manda handoff, acha erro, retorna, corrige, manda de volta, acha mais erro, roda o pipeline tudo de novo"*. Medi os dois projetos antes de escrever qualquer regra.

**`cl-adv` (1482 handoffs).** O par mais frequente do projeto inteiro é o loop de revisão:

| par | handoffs |
|---|---|
| `cl-dev1 → cl-code-revision` | 100 |
| `cl-code-revision → cl-dev1` | 92 |
| `cl-infra ↔ cl-code-revision` | 92 |

São **192 handoffs num único par** dev↔revisão — ~13% do tráfego do projeto — e mais 92 no segundo par. Não é o trabalho: é o *vaivém sobre o mesmo trabalho*.

**`rh-proxima` (2772 handoffs).** Por issue, o custo se concentra na cauda:

| issue | handoffs | janela |
|---|---|---|
| #48 | 19 | 9,5 h |
| #53 | 15 | 12,7 h |
| #29 | 12 | 4,3 h |

E **151 threads** são ida-e-volta entre exatamente **dois** agentes com 3+ handoffs. Na #53, quinze despachos do `po` pro mesmo grupo (arquiteto, dev-backend, dev-frontend, e2e, revisor… e de novo arquiteto ×4).

**Por que isso é caro aqui, e não numa equipe humana:** cada ida-e-volta é um **wake** — sessão acorda, refaz contexto, relê arquivo, roda o pipeline. Um humano lê um comentário em 5 segundos sem "recarregar" nada. Aqui, o custo marginal de *mais um comentário* é aproximadamente o custo de *começar do zero*. Logo a métrica certa não é "quantos tokens por handoff", é **quantos wakes por issue**.

**O que entrou no protocolo (passo `0c`, pago só em wake produtivo):**

1. **Gate do projeto antes da revisão.** Pipeline não é lint. Mandar sem verificar gasta um ciclo inteiro (wake do autor + wake do revisor + CI) pra descobrir o que o gate local diria em segundos.
2. **Revisão é passada COMPLETA**, com cada achado marcado *bloqueia* / *não bloqueia*. Devolver no primeiro defeito multiplica os wakes pelo número de defeitos — é a origem aritmética do vaivém.
3. **Erro trivial quem acha corrige.** Devolver custa mais que consertar.
4. **Teto de 2 rodadas** no mesmo item: a terceira não é código errado, é **enunciado** errado. Escalar é mais barato que insistir.
5. **Varra a issue inteira antes de codar** e **um handoff por especialista por onda** (esses dois ficaram na doutrina de frota, que é grátis: não são regras de *execução do BUS*, são de método).

**O que deliberadamente NÃO mudou:** nada da mecânica. Sem campo novo no handoff, sem estado novo, sem regra no gate. O ciclo de revisão é política de projeto — o gate é customizado por projeto e continua sendo do projeto. O BUS só passou a **dizer**, no momento em que o agente vai agir, o que custa caro no desenho dele.

## Lease do lock configurável (v0.9.20)

O lease — por quanto tempo um lock vale sem ninguém renovar — era `60` fixo no `bus-gate`. É o prazo que **destrava um projeto cuja sessão morreu** (app fechado, `/clear`, travamento) sem o operador apagar arquivo na mão, e o valor certo depende do time: turno longo pede folga, teste de fluxo pede prazo curto.

Virou `<base>/.bus-lease` (GLOBAL, como o `.bus-cron-interval`), com botão no dashboard ao lado do `check`.

**Escada, não passo livre:** `15 · 30 · 45 · 60 · 90 · 120 · 180 · 240`. De 15 a 240 de um em um seriam 47 cliques pra atravessar a faixa; a escada cobre a faixa útil em 7 passos. Valor fora dela (arquivo editado na mão) cai no default 60 — nos dois gates.

**Só vale pros locks NOVOS**, e isso é o ponto de desenho: o `expiry` é gravado **dentro do lock**, pelo gate, no momento do acquire. Quem já está segurando um lock mantém o prazo com que começou. Se o lease valesse retroativamente, baixar o número **roubaria o turno de quem está trabalhando agora** — exatamente o acidente que o lock existe pra impedir. O preço é que o efeito não aparece na barra de lock na hora; aparece no próximo acquire.

**A troca que o operador está fazendo:** curto demais = risco de dois especialistas no mesmo repo, se um turno passar do prazo (o lock é roubável, não renovável — ninguém dá heartbeat). Longo demais = projeto parado por mais tempo quando uma sessão morre. O default 60 continua sendo o meio termo medido na prática.

## O flash de console no Windows: de quem é a culpa (20/08/2026)

O operador via a tela **piscando** e o suspeito natural era o tique do BUS — ele é o que roda o tempo todo. Medição com a frota trabalhando (6 especialistas, `check` em 1 min), contando processos NOVOS numa janela de 30 s:

| processo | novos em 30 s |
|---|---|
| `bash.exe` | 306 |
| `conhost.exe` | 224 |
| `cygwin-console-helper.exe` | 123 |
| `powershell.exe` | 22 |
| **destes, o gate do BUS** | **~3** (≈ 6/min, confere com o `.bus-gate.log`) |

**O tique é ~1% do barulho.** O resto é a **ferramenta Bash** dos especialistas: no Windows ela chama `C:Program FilesGitinash.exe`, que re-executa `usrinash.exe`, e o MSYS2 **emula `fork()` abrindo processo novo** — cada `|`, cada `$( )`, cada volta de laço vira um `bash.exe`. Junto vêm `conhost.exe` e `cygwin-console-helper.exe`, que são janelas de console de verdade.

**O que NÃO resolveu, e por quê medir antes importou.** A ideia óbvia era tirar o PowerShell do hook e apontá-lo pro `bus-gate.sh` — bash já está no caminho de qualquer jeito (o harness roda o hook como `bash -c "powershell ... bus-gate.ps1"`). Medido na mesma máquina: `.ps1` **3,2 s** por execução contra `.sh` **5,5 s**. O gate em bash é *mais lento*, porque ele mesmo forka `sed`/`grep`/`date` — e cada fork é um processo no Windows. Teria piorado o flash **e** a latência.

**O que sobrou como ação real:**

1. **Doutrina de frota** (`~/.claude/CLAUDE.md`): no Windows, ordem de preferência **Read/Grep/Glob/Edit → ferramenta PowerShell → Bash só se não houver equivalente**. É onde estão os 99%. A orientação do modo bypass ("prefira o Bash tool") pressupõe Linux e é explicitamente revogada ali.
2. **`BUS_TICK_PROMPT` diz "(ferramenta PowerShell)"** e o protocolo repete: os comandos do BUS são `.ps1`, rodá-los por `bash -c` dobra o custo à toa.
3. **O intervalo do `check`** é o único multiplicador do lado do BUS: em 1 min são ~6 gates/min; em 5 min, ~1,2. É um clique no dashboard.

A lição que vale além deste caso: **o processo mais visível não é o mais frequente.** O tique tinha o perfil do culpado (roda sempre, é do BUS, aparece no log) e respondia por 1%.

## Agente long-lived: o que sobrevive à compactação (v0.9.8)

Especialista do BUS vive dias. A conversa **não** — compactação e `/clear` apagam. Três camadas, e o que decide qual usar é **o que sobrevive a quê**:

| o quê | onde | sobrevive porque |
|---|---|---|
| como o BUS funciona (idêntico em todo projeto) | `~/.claude/CLAUDE.md` | é config de sessão, re-estabelecida sempre |
| política **deste** projeto | `CLAUDE.md` na raiz do projeto | idem, e é herdado pelas subpastas |
| o que **este especialista** já fez/decidiu | `<projeto>/.state-<slug>.md` | é arquivo; contexto nenhum o alcança |

**A herança foi medida, não presumida.** Duas sessões `claude` reais com marcadores nos dois arquivos:

| sessão rodando em | global | `projects/cl/CLAUDE.md` |
|---|---|---|
| `projects/cl/ads` (subpasta de especialista) | ✓ | ✓ **herdado do pai** |
| `claude-bus` (outra árvore) | ✓ | ✗ |

A primeira linha justifica a camada de projeto: **um** arquivo em `projects/<sigla>/` alcança os N especialistas daquele projeto, porque no layout real cada projeto do BUS é uma pasta e cada especialista trabalha numa subpasta dela (em `cl/`, os diretórios `ads/`, `e2e/`, `social/` batem com os slugs).

A segunda linha é o **modo de falha**: na árvore errada o agente perde a política do projeto **em silêncio** — sem erro, sem aviso, seguindo a política de outro time (ou nenhuma). É a mesma armadilha que o `rules_file` do `/bus-git-watch` já documentava. Por isso o `CLAUDE.md` do projeto **declara** a quem serve (`<!-- BUS: projeto <slug> -->`) e o passo de identidade confere contra o projeto registrado: suposição vira checagem. A conferência fica no `/bus <projeto> <slug>` (uma vez por sessão, onde a skill já está carregada) e não no protocolo, que é pago em todo tique.

**Por que a camada global não foi dissolvida nos projetos:** ela é idêntica nos três. Em três cópias elas divergem, e o sintoma — um time se comportando diferente do outro — é caríssimo de diagnosticar. Duplicar o que é igual é o mesmo erro que o broadcast de handoff.

**`BUS_STATE` (`<projeto>/.state-<slug>.md`)** fecha o que a v0.9.6 deixou aberto: a regra *"self-handoff é PONTEIRO"* não tinha alvo canônico, e sem destino cada especialista inventava o seu — o corpo voltava a inchar. Vive na raiz do projeto (não no scratchpad da sessão, indexado por sid, que o `/clear` orfana — lição que o `/bus-git-watch` já pagou) e é dotfile, então não vira projeto no dashboard.

Três regras impedem que ele degenere:
- **Atualize quando o rumo MUDA**, não a cada tique — senão todo wake paga escrita à toa.
- **Sobrescreva, ~40 linhas, só o que não dá pra redescobrir.** Anexar transforma memória em diário, e o diário inteiro é lido em todo wake. O que está no git/arquivo/issue fica lá.
- **Estado ≠ mundo:** antes de re-executar, confirme no mundo. Arquivo desatualizado obedecido às cegas duplica commit, e-mail e deploy — a mesma regra que o `BUS_STATE_PROCESSING` já impunha na retomada.

**O que NÃO entrou:** a ideia de "o que importa vai no topo do `SKILL.md` porque a truncagem preserva o começo". A prática é boa por outras razões, mas não achei evidência da truncagem — e desde a v0.9.5 o tique **não carrega a skill**, então o caminho quente nem passa por lá. Onde a ordem ainda importa de verdade é na `description` do frontmatter, que é o que decide se a skill é acionada.

## `BUS_ROLE` e `issue:` — papel derivado, registro durável (v0.9.7)

A ideia original do operador era: *"agente **sem prioridade setada** opera como background, output mínimo, interagindo só com a issue"*. A intuição estava certa; a **chave** estava errada, em dois pontos.

**1. "Tem prioridade setada" não identifica a interface.** O `arquiteto` do `cl-adv` está em `10` por razão puramente de escalonamento e não é interface de ninguém. Pior, a inversa: um controlador que o operador **esqueceu** de setar viraria background e **sumiria como interface do projeto** — um esquecimento virando duas falhas.

O que se queria já existe e é computável: **controlador = a MENOR prioridade do projeto** (a definição que a skill já usava). O leitor lê o `.priority` de qualquer jeito, então devolve `BUS_ROLE=controlador|background` e o protocolo imprime **só a linha do seu papel**. Sem hierarquia no projeto (ninguém abaixo de 1000), nenhum papel é emitido e o comportamento anterior continua valendo — nada de silenciar um time que nunca escolheu controlador.

**2. "Interagir só com a issue" precisava de um vínculo que não existia.** Só os handoffs nascidos do `/bus-git-watch` vêm de uma issue; `po → dev-backend "faça X"` não tem nenhuma. Daí o header **`issue:`** (`-Issue`/`--issue`), que o carteiro preenche e o leitor entrega como `BUS_ISSUE=`. A regra é condicional ao campo: **com `issue:`, o retorno vai pro ticket; sem, handoff normal.** É extensão do `bus-git-watch` (que já pregava "o especialista responde no ticket"), não da prioridade.

**A válvula que faltava na proposta:** silêncio precisa de exceção. Um worker que trava e fica quieto porque "é background" some do radar. Por isso a linha do papel termina em *"bloqueio ou impasse que só o operador resolve FURA o silêncio"* — coerente com o `Impasses sobem pro operador` que já estava na §4.

**Onde está a economia de verdade:** não é no output do terminal (1 linha, troco). É em **worker registra na issue em vez de mandar handoff de status pro PO**: 5 workers × 1 status = **5 wakes do PO evitados**. Mesma lógica do `kind: fyi`, por outro caminho — FYI para o que o peer precisa saber agora, issue para o que precisa ficar registrado.

## `kind: fyi` — separar **acordar** de **entregar** (v0.9.6)

Até aqui todo handoff era gatilho de wake, e **o wake é a unidade cara**: protocolo + corpo + o turno inteiro do modelo + re-arme do cron + release do lock. Um "terminei X" custava tudo isso pra não gerar ação nenhuma.

Amostra de 180 handoffs / 446KB do BUS real: **18 cópias extras de broadcast** (o mesmo corpo do controlador replicado pra 3 especialistas) e, na leitura à mão, entre 1/3 e 1/2 do tráfego não-self era anúncio ou status.

`--fyi` grava `kind: fyi`. O gate **ignora** FYI ao decidir se acorda alguém; o leitor entrega o FYI **de carona** no próximo wake real do destino.

**Por que a carona é semanticamente certa, não só barata:** um aviso só importa quando o destinatário vai *fazer* algo — e ele só faz algo quando acorda. Acordando, recebe o aviso junto. O *"heads-up: a pilha cresceu de 7 pra 8"* chega imediatamente antes do push, que é quando ainda serve. Um FYI que acordasse uma sessão ociosa só faria ela ler e voltar a dormir.

**Os três pontos onde isso quebraria se feito pela metade:**

- **Prioridade.** FYI não pode contar no `higherPending`, senão um aviso pendente pra alguém de prioridade maior faz o projeto inteiro ceder a vez pra um fantasma que nunca vai acordar. Deadlock.
- **`BUS_PENDING`.** A doutrina do "fio vivo" diz: *se quem eu espero está no `BUS_PENDING`, posso encerrar — ele acorda e age*. Com FYI contando ali, eu encerraria esperando alguém que **não vai acordar**. Por isso `BUS_PENDING` passou a listar só quem tem **task** (ou FYI vencido) — e o número do envelhecimento tem que ser **o mesmo** no gate e no leitor.
- **Envelhecimento (4h).** Sem ele, um FYI pra quem ficou ocioso nunca é entregue e o remetente acha que avisou. Passado o prazo o FYI volta a valer como trabalho: no pior caso é **1 wake a cada 4h**, que entrega todos os acumulados de uma vez. O BUS já tem cicatriz de "handoff preso pra sempre" (foi o que originou o `BUS_STALE_PROCESSING`); não valia a pena abrir uma segunda.

**A borda afiada da marcação:** *destravar alguém é TASK*. "Gate saiu, pode pushar" parece anúncio e é gatilho de ação. A regra é "o outro tem algo a **fazer**?", não "isso é importante?". E a assimetria é proposital: task errada custa um wake, FYI errada custa atraso — por isso **na dúvida, task**.

FYI tem **orçamento próprio** no leitor (5), fora do lote de 3 tasks: senão três avisos empurrariam um pedido de verdade pro tique seguinte. Como consequência o leitor voltou a **abrir todo arquivo** do inbox (a v0.9.5 pulava a leitura além do lote): sem abrir não dá pra saber se é task ou fyi. São ~2KB por arquivo — aqui o caro é token, não I/O.

**Broadcast nativo (`-To a,b,c`) ficou de fora** de propósito: o remetente já escreve o corpo uma vez e só repete a chamada, então economiza pouco. O ganho estava todo em não acordar N sessões, e `--fyi` entrega isso inteiro.

## Corpo do handoff: onde o desperdício realmente estava (v0.9.6)

O diagnóstico genérico ("corpos longos demais") estava **errado**, e cortar por tamanho brigaria com uma otimização correta que já está na skill: *junte 2-3 pedidos num handoff só*, porque round-trip é mais caro que texto. O p50 de 2,3KB é razoável **para um spec**.

O desperdício era específico: **self-handoff**, média de **1.835 bytes**, cujo próprio corpo dizia *"Checkpoint em `<arquivo>`. **Leia dali**"* — 1,8KB descrevendo um arquivo que o modelo ia abrir de qualquer jeito. Num único dia, um especialista mandou **11 seguidos**.

Daí as duas regras: **self-handoff é ponteiro** (onde está o checkpoint, próximo passo, o que não refazer) e **nunca cole o que já está em arquivo/commit/issue** (mande o caminho).

O mecanismo é **um aviso, não um bloqueio**: `BUS_BODY_WARN=` acima de 800 B em self-handoff, ou 4KB em qualquer handoff. Recusar o envio jogaria fora trabalho já feito — e o aviso chega depois do envio, então seu valor é o **laço de feedback dentro da própria sessão**: quem manda 11 self-handoffs em sequência corrige do segundo em diante.

## Economia de token: protocolo impresso + lote (v0.9.5)

Com o tique já em texto puro, sobraram dois custos, e os dois foram **medidos** antes de mexer.

**1. A skill recarregada em todo tique produtivo.** O tique mandava *"carregue a skill bus"* — 10.250 bytes (~2.560 tokens) a cada acordada com trabalho. E o caminho de **processar** usa só §2+§3 (~5KB); §Comandos/§Identidade/§Coordenação são de **configuração**, pagos sem serem usados.

Agora o `bus-inbox -Protocol` imprime o bloco `BUS_PROTOCOL`: o fluxo BARE inteiro em **~2.3KB (~560 tokens)**, com os comandos já resolvidos em **caminho absoluto** — o script sabe onde está (`$PSScriptRoot`), e os irmãos ficam ao lado dele tanto no plugin (`bin/`) quanto no install local (`skills/bus/`). Economia de **~2.000 tokens por tique produtivo**. O protocolo só sai **quando há trabalho**: tique sem nada não paga por instrução que ninguém vai executar.

É o mesmo movimento que já tinha funcionado uma vez (o tique deixar de ser `/bus`): **tirar instrução do "sempre injetado" e pôr no "impresso sob demanda"**. A skill continua sendo a fonte pro `/bus <projeto> <slug>` e pro que fugir do previsto — o protocolo termina dizendo isso.

**`BUS_TICK_PROMPT=` — por que o script monta o prompt do cron.** O prompt do cron é **texto puro**: um `${CLAUDE_PLUGIN_ROOT}` gravado ali **não expande**. Se o modelo montasse o caminho na mão e errasse, o tique quebraria **em silêncio** — o especialista some do BUS sem erro visível, que é o pior modo de falha deste sistema. Então `bus-name` e `bus-inbox` devolvem a frase pronta e a skill só manda **copiar literal**. O caminho vai em **aspas simples**: a frase inteira entra dentro do `prompt:` (aspas duplas) do `CronCreate`, e aspas duplas aninhadas quebrariam o JSON. E ela termina com *"se falhar, carregue a skill bus"* — a rede pra plugin movido ou renomeado.

**2. Lote (`-Max`, default 3).** O leitor emitia **todos** os pendentes, corpo inteiro, numa passada. Quem voltava de offline acordava com 6+ handoffs (~3,7k tokens medidos num inbox real) e ainda gerava resposta pra cada um no mesmo contexto — o caminho conhecido pro "Prompt is too long" e pro `/clear`.

Seja honesto sobre o que isso é: **não reduz o total** de tokens para o mesmo volume de trabalho — reduz o **pico**. E o pico é o que dispara compactação (que relê o contexto inteiro) e o `/clear` (que joga tudo fora e reconstrói). Por isso o `BUS_MORE=<k>` vem com uma ordem explícita: **não drene** — feche o lote, re-arme, libere o lock. O resto sai no próximo tique, com atraso de no máximo `*/N`, e o gate já sabe que você tem trabalho (ele varre o `inbox/` por conta própria, independente do lote).

Além do limite o leitor **nem abre** os arquivos excedentes — só conta. Efeito colateral: handoff forjado além do lote só vai pro `rejected/` num tique seguinte.

## Prioridade órfã: desregistrar não apaga o `.priority` (v0.9.4)

O `<projeto>/.priority` é indexado por **slug**, não por sessão, e isso é **de propósito**: uma sessão que reinicia ganha um `sid` novo e roda `/bus <projeto> <slug>` **sem** o 3º argumento — a prioridade tem que sobreviver, senão o controlador viraria default 1000 a cada `/clear`.

O efeito colateral apareceu quando um especialista foi **removido**: "desregistrar" **não é uma operação do BUS** — não existe comando. O que se faz é apagar `names/<sid>.txt` (e o `seen/`) na mão, e nada toca no `.priority`. A linha fica órfã para sempre e o dashboard seguia exibindo o badge de prioridade de um destino que **não existe mais**.

Pior que o badge: um card endereçado a um slug inexistente **parecia normal**. O ✕ vermelho de destino offline depende de `toArmed === false`, e destino não registrado dava `toStatus = null` → `toArmed = null` → sem ✕. Ou seja: o caso *pior* (ninguém vai voltar pra ler) era o único **sem** aviso visual.

Correção: prioridade só existe para quem está no **roster** (`names/`). O servidor marca `toRegistered` e zera o `toPrio` (`null`) de destino não registrado; o front mostra `sem registro` (badge tracejado vermelho) e passa a exibir o ✕ também nesse caso, com texto próprio.

**A linha órfã ainda dá para limpar na mão** (`grep -v '^slug:' .priority`) e vale limpar quando o número for **> 1000**: o gate compara `xPrio > myPrio` e cederia a vez para um destino fantasma enquanto o handoff estiver no inbox — nenhum tique passa. Com número baixo (0/10, o caso comum de controlador) é inerte. Se um dia existir um comando de dereg, o lugar dele é o `bus-name` (apagar `names/` + `seen/` + a linha do `.priority` numa operação só).

## /bus-message (instrução do operador, sem acordar o modelo)
`/bus-message <texto>` é interceptado pelo **próprio gate** (hook `UserPromptSubmit`): ele resolve a identidade da sessão (`names/<sid>`), escreve um handoff `operador→seu-slug` no inbox do projeto (com o token, mesma lógica do bus-send) e **bloqueia o prompt (`exit 2`)** — o modelo **NÃO acorda**, custo ZERO de token. O especialista processa a instrução no próximo `/bus` (tick do cron ou manual), como qualquer handoff (`BUS_FROM=operador`, sem retorno). Como `/bus-message` não casa o regex `^/bus(\s|$)`, não interfere no gating normal do `/bus`. Há uma skill `bus-message` de **fallback**: se o hook não estiver instalado, o prompt chega ao modelo e a skill escreve o handoff via bus-send (custo pequeno, mas funciona).

## Autenticação e escrita
- Cada handoff carrega um token `auth:` (do `.bus-secret` compartilhado do projeto). O `bus-inbox` valida e manda forjados pra `rejected\` antes de te entregar; o `bus-send` injeta o token. Protege contra injeção **casual** via `%TEMP%`, não contra malware que leia o disco.
- Escrita atômica (temp + rename) pro leitor nunca pegar arquivo pela metade; o `###BUS-END` confirma escrita completa. Corpo em UTF-8 **sem BOM** (preserva acentos).

## Contrato do `bus-inbox` (saída enxuta)
O `bus-inbox` entrega ao modelo só `BUS_FROM`/`BUS_ID`/`BUS_REPLY_REQUIRED`/(`BUS_IN_REPLY_TO`) + o **corpo limpo** entre `BUS_BODY_BEGIN`/`END`. Descarta o `auth:` (token/ruído), o `to:` (é o próprio) e os marcadores `###BUS-START/END` — menos tokens por leitura e parsing trivial (o modelo não extrai corpo de raw). O `split` é com limite 2, então um `---` **dentro** do corpo não quebra o parsing.

**Identidade auto-resolvida:** chamado **sem `-Me`**, o `bus-inbox` lê o `names/<sid>` (linha1=projeto, linha2=slug) — como o gate faz — e abre a saída com `BUS_SLUG=`/`BUS_PROJECT=` (ou `BUS_IDENTITY=NONE` se a sessão nunca se registrou). Assim o `/bus` **bare não chama o `bus-name`** só pra se identificar — uma chamada a menos por passada. Com `-Me` explícito o comportamento é o de antes (retrocompat). O `seen` (prova de vida do dashboard) segue sendo gravado pelo `bus-inbox` a cada chamada, independente do `bus-name`.

**Processing órfão (`BUS_STALE_PROCESSING`):** o `processing/` é um **claim** — o handoff sai do `inbox/` no instante em que alguém o reivindica. Se aquele turno morre no meio (app fechado, contexto compactado, lease expirado, tarefa longa que nunca reacordou a sessão), o arquivo fica lá **para sempre**: o `bus-inbox` lê só o `inbox/`, e o gate também só conta o `inbox/` pra decidir se acorda alguém. Resultado: o handoff nunca é retomado e **quem espera a resposta trava em silêncio** — nada no bus aponta esse estado. Por isso o `bus-inbox` agora varre o `processing/` procurando `to-<você>__*` e emite uma linha por arquivo **com 30 min ou mais** (`caminho` + idade). O corte de 30 min existe pra **não** reportar o que está em voo na passada atual — um ciclo normal (claim → executa → done) leva segundos. Vale só pro **próprio slug**: handoff de outro especialista preso no processing dele é problema dele. A doutrina de como retomar (confirmar no mundo o que já foi feito **antes** de re-executar, pra não duplicar commit/e-mail/deploy) está no `SKILL.md` passo 5.

**Inbox geral (`BUS_PENDING`):** toda saída termina com `BUS_PENDING=<destinos distintos com handoff pendente no projeto>` — o "olhar o inbox GERAL, não só o seu". Vazio = **bus parado**. É o sinal da doutrina "fio vivo" (SKILL §5 regra 2): se você encerra **esperando uma resposta** e o `BUS_PENDING` está vazio (ou quem você espera não aparece nele), o retorno **não vem sozinho** (ninguém te acorda até um `/bus` manual) → dispare um handoff pedindo o status. Barato: só o nome do arquivo (a escrita é atômica → todo `.handoff` no inbox está completo). (O `bus-inbox` também emite `BUS_CRON_INTERVAL=N` no topo — o intervalo do cron configurado no dashboard, pra armar `*/N`.)

## `.ps1` sem acento
Os scripts `.ps1` são escritos **sem acento** no código/comentários: o PowerShell 5.1 corrompe acentos em arquivo salvo sem BOM (a ferramenta Write salva sem BOM). Conteúdo com acento vai só nos **corpos** de handoff (escritos via Write, lidos como UTF-8 sem BOM).
