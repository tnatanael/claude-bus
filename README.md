# claude-bus

Plugin do **Claude Code** para **comunicação assíncrona entre sessões** ("especialistas"). Cada sessão vira um especialista; eles trocam **handoffs** por um BUS de arquivos.

**Como funciona.** Há **dois usos do `/bus`**: **com argumentos** (`/bus <slug> <projeto> [prioridade]`) ele **configura** a sessão — registra a identidade no projeto (o **projeto é obrigatório**), define prioridade e arma o auto-recheck — e **não processa**; **bare** (`/bus`) ele **processa** os handoffs endereçados a ela. O processamento dispara de dois jeitos: você rodando `/bus` (bare), ou o **auto-recheck** — um cron de sessão (a cada 5 min) que re-checa o inbox sozinho **enquanto a sessão está aberta**. O cron do destino processa os handoffs **automaticamente** — não precisa anunciar nem rodar `/bus` manual; o dashboard mostra os pendentes.

Não existe **daemon nem processo de fundo separado**: o auto-recheck é a própria sessão se reacordando pelo agendador do harness (in-harness) — some limpo quando a sessão fecha, sem processo órfão pra vazar. Pra que essa recheca de 5 em 5 min **não acorde o modelo à toa**, ative o **gate de concorrência** (opcional, [abaixo](#gate-de-concorrência-opcional)): ele **defere os ticks vazios ou bloqueados antes da API** — custo de token zero quando não há trabalho — e ainda serializa o trabalho entre todas as sessões.

- **Escopo de projeto (obrigatório)** — `/bus <slug> <projeto>` isola cada frente; você só vê e endereça especialistas do mesmo projeto. O projeto é **obrigatório** (não há mais `default`).
- **Config vs processar** — `/bus <slug> [projeto] [prio]` (com args) **só configura** (identidade/prioridade/cron); **`/bus` bare** lê o inbox, valida o token, executa os handoffs e arquiva.
- **Autenticação por token** — handoffs forjados vão pra quarentena (`rejected/`) antes de qualquer execução.
- **Auto-nome por sessão** — configure o slug 1× com `/bus <slug> [projeto]`; depois é só `/bus` (bare) pra processar.
- **Entrega automática** — o cron de cada especialista (a cada 5 min) processa os handoffs sozinho; não precisa anunciar nem rodar `/bus` manual. Handoffs pra sessões offline esperam no dashboard.
- **`/bus-message <texto>`** — o operador enfileira uma instrução pra um especialista **sem acordar o modelo** (o hook escreve o handoff `operador→especialista`; o especialista processa no próximo tique).
- **Operação desassistida automática** — o `/bus` arma sozinho um recheck **a cada 5 min** (cron de sessão) pra processar handoffs quando você sai. Após reabrir o app (o cron de sessão morre no restart), religue com **`/bus-reload`** — re-arma o cron usando a identidade já registrada, **sem processar** o inbox nem mexer no lock.
- **Gate de concorrência (anti-overload, opcional)** — um hook serializa o trabalho por `/bus` num **lock por projeto** (`<projeto>/.bus-lock`): 1 especialista por vez **dentro** do projeto, mas **projetos diferentes rodam em paralelo**; os demais deferem **sem gastar API**, e checagens de inbox vazia ficam de graça. Setup na seção [Gate de concorrência](#gate-de-concorrência-opcional).

## Instalação

```
/plugin marketplace add tnatanael/claude-bus
/plugin install bus@claude-bus
```

## Uso

Em cada sessão que vai participar, rode **uma vez** `/bus <slug> <projeto>` (ex.: `/bus backend acme`) pra **configurar** — registra no projeto e arma o auto-recheck (**não processa**). O **projeto é obrigatório**. A partir daí, **`/bus` (bare)** — ou o auto-cron — **processa** os handoffs (lembra slug/projeto pela sessão). O projeto isola o BUS: especialistas só veem/endereçam quem está no mesmo projeto. Pra mudar a **prioridade** depois: `/bus <slug> <projeto> <prioridade>` (configura, não processa).

Para mandar trabalho de uma sessão a outra, o especialista escreve um handoff endereçado ao slug do destino. O cron do destino (**a cada 5 min**, cron de sessão) processa sozinho — não precisa anunciar nem rodar `/bus` manual. O dashboard mostra os pendentes + quem está offline.

## Plataformas

| SO | Runtime | Status |
|---|---|---|
| Windows | PowerShell (nativo) | ✅ testado |
| macOS / Linux | bash (nativo) | ✅ validado em macOS (feedback de Linux bem-vindo) |

Sem dependências: usa o PowerShell do Windows e o bash do macOS/Linux.

## Como funciona

- **BUS** = pasta compartilhada entre as sessões: base `%TEMP%\claude-bus` (Windows) ou `/tmp/claude-bus` (Unix), override pela env `CLAUDE_BUS_ROOT`. O **projeto é obrigatório** (não há `default`): cada projeto `<p>` usa `<base>/<p>/` (cada um com seu `inbox/ processing/ done/ rejected/ .bus-secret`). O registro `names/` fica na base (global).
- Cada handoff é um arquivo `to-<destino>__from-<origem>__<id>.handoff`, escrito atomicamente e com um token de auth.
- **`/bus` (bare)** chama o leitor `bus-inbox` (one-shot): valida o token de cada handoff endereçado a você, manda os forjados pra `rejected/` e entrega os autênticos pra sessão processar (claim em `processing/`, executa, arquiva em `done/`, devolve retorno se pedido). (Comando **com args** = config; não chega a processar.)
- Não há **daemon separado**, presença nem heartbeat: o que reacorda uma sessão é você rodando `/bus` **ou** o cron de auto-recheck dela (a cada 5 min, só enquanto a sessão está aberta). O cron é in-harness — re-invoca a própria sessão e some quando o app fecha; nada de processo órfão.
- **Gate de concorrência (opcional)** — um hook `UserPromptSubmit` (`bin/bus-gate.*`) filtra os `/bus` **antes da API**: defere sem custo se outro especialista **do mesmo projeto** segura o **lock do projeto** (`<projeto>/.bus-lock`; projetos diferentes rodam em paralelo) ou se sua inbox está vazia; adquire o lock quando há trabalho. O hook também intercepta **`/bus-message`** (enfileira instrução do operador sem acordar o modelo) e a **pausa por projeto**. O fim do `/bus` libera o lock (`bin/bus-lock.* --release`); um lease de 30 min é a rede. Setup abaixo.

## Gate de concorrência (opcional)

O limite de requisições da API é da **conta** Claude, não do projeto — várias sessões trabalhando em paralelo podem causar overload (429/"serviço ocupado"). O gate serializa o trabalho por `/bus` num **lock por projeto** (`<projeto>/.bus-lock`): **1 especialista por vez dentro do projeto, mas projetos diferentes rodam em paralelo** (o tradeoff é que o pico de API sobe com o nº de projetos ativos — o limite ainda é da conta). Também torna as checagens de inbox vazia **de graça** (bloqueia o `/bus` antes da API). É **opt-in**: registre o hook `UserPromptSubmit` no `settings.json` global (`~/.claude/settings.json`):

```json
{ "hooks": { "UserPromptSubmit": [ { "hooks": [ { "type": "command", "command": "<comando>" } ] } ] } }
```
- **Windows:** `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<raiz>\bin\bus-gate.ps1"`
- **macOS/Linux:** `bash "<raiz>/bin/bus-gate.sh"`

O hook é **fail-open blindado** (erro inesperado nunca trava um prompt; mas num `/bus` ele ainda **tenta adquirir o lock após o erro** — se outro o segura, **defere em vez de sobrepor**, preservando a serialização mesmo sob falha) e só age em `/bus`: grava o `seen` (prova de vida pro dashboard), defere (`exit 2`, **sem custo de API**) se o lock está ocupado ou a inbox vazia, e adquire o lock quando há handoff. O passo final do `/bus` libera o lock; um **lease de 30 min** cobre quedas de sessão. Cada decisão relevante (`acquire`/`acquire-steal`/`defer-race`/`defer-prio>slug`/`defer-lock>slug`/`failopen-*`/`release`) vai pra `<base>/.bus-gate.log` (log forense, best-effort, auto-limita em ~512 KB). Além disso, o hook faz **manutenção da estrutura** (pré-API, sem custo de modelo): **garante as pastas** do projeto (recria as que o SO tiver limpado do `%TEMP%`/`/tmp`) e **renova o mtime** de `.bus-secret`, `names/<sid>`, `.priority` e `.bus-paused` — **só dos que já passaram de ~6h** (pra não gerar contenção com dezenas de especialistas tocando os mesmos arquivos; cada operação é isolada e só mexe no mtime, nunca no conteúdo). Assim o `.bus-secret` não "rotaciona" (token novo) por limpeza (ex.: Storage Sense do Windows) e a sessão não perde registro nem prioridade. O dashboard mostra quem segura o lock de cada projeto ("Trabalhando agora") e permite **pausar/retomar** um projeto. Sem o hook, o BUS funciona normalmente — só sem a serialização anti-overload (e sem essa manutenção).

### O CONTROLADOR (menor prioridade) processa por último

Cada especialista tem uma **prioridade** (default `1000`; quanto **menor**, mais cede a vez). Um especialista **cede a vez** (defere) quando tem trabalho **e** há handoff pendente pra alguém de prioridade **maior** — igual/menor não bloqueia. O especialista de **menor prioridade** é o **controlador**: registre-o com prioridade **baixa** (ex.: `0`) → ele processa por último (**consolida no fim**), é dono do backlog de macro-tarefas (despacha a próxima onda quando os outros esvaziam — ninguém ocioso) e é o ponto de resumo pro operador. Sem controlador (ninguém < 1000), a coordenação é peer-to-peer: cada um consolida a própria frente.

Set a prioridade pelo **3º argumento do `/bus`**: `/bus <slug> <projeto> <prioridade>`. Ex.: lance o controlador com `0`:

```
/bus po acme 0
```

Isso grava `po:0` em `<raiz-do-projeto>/.priority` (linhas `slug:N`; o gate lê pré-LLM, sem reinício). Omitir o 3º arg **não mexe** na prioridade (persiste). **Atenção a starvation:** num projeto sempre cheio de handoffs, um low-prio pode esperar bastante (é o comportamento desejado — "só quando ninguém de prioridade maior tiver"); se incomodar, dá pra adicionar um teto de espera.

## Dashboard ao vivo (incluso)

A pasta [`dashboard/`](dashboard/) traz um app web minúsculo (sem build, sem dependências, só a stdlib do Node) que visualiza o BUS em tempo real, com **seletor de projeto obrigatório** (escolha um projeto pra ver o board): handoffs transitando por `inbox -> processing -> done`, correlação de respostas por `in_reply_to`, os rejeitados por auth, **quem segura o lock daquele projeto agora** (🔨 + o slug, com a expiração do lease) e um botão **Pausar/Retomar** o projeto. É somente leitura sobre o BUS — a única escrita é o marcador de pausa.

```
node dashboard/server.js           # http://localhost:7878 (porta via env PORT)
node --watch dashboard/server.js   # idem, com auto-reload ao salvar o server.js (Node 20+)
```

Reiniciar/verificar (com auto-reload via `--watch`) e persistência no boot — Windows/macOS/Linux — em [`dashboard/OPERATIONS.md`](dashboard/OPERATIONS.md). Detalhes e contrato da API em [`dashboard/README.md`](dashboard/README.md) e [`dashboard/ARCHITECTURE.md`](dashboard/ARCHITECTURE.md).

## Segurança

A pasta do BUS é gravável por qualquer processo do seu usuário. O token (`.bus-secret`) barra injeção **casual**, não malware dedicado que leia o disco. O `bus-inbox` valida o token antes de a sessão tratar o corpo como comando. Use em ambiente de confiança e em sessões em modo auto que você controla.

## Licença

MIT
