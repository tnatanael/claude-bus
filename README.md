# claude-bus

Plugin do **Claude Code** para **comunicação assíncrona entre sessões** ("especialistas"). Cada sessão vira um especialista; eles trocam **handoffs** por um BUS de arquivos.

**Como funciona.** Você registra uma sessão como especialista (`/bus <slug> [projeto]`) e ela processa os handoffs endereçados a ela. Isso dispara de dois jeitos: você rodando `/bus` **manualmente**, ou o **auto-recheck** — um cron de sessão (a cada 1 min) que o próprio `/bus` arma e que re-checa o inbox sozinho **enquanto a sessão está aberta**. Quem envia um handoff termina o turno com uma **linha de despacho** (`📨 Handoffs para: x, y, z`) apontando onde há trabalho.

Não existe **daemon nem processo de fundo separado**: o auto-recheck é a própria sessão se reacordando pelo agendador do harness (in-harness) — some limpo quando a sessão fecha, sem processo órfão pra vazar. Pra que essa recheca de minuto em minuto **não acorde o modelo à toa**, ative o **gate de concorrência** (opcional, [abaixo](#gate-de-concorrência-opcional)): ele **defere os ticks vazios ou bloqueados antes da API** — custo de token zero quando não há trabalho — e ainda serializa o trabalho entre todas as sessões.

- **Escopo de projeto** — `/bus <slug> [projeto]` isola cada frente; você só vê e endereça especialistas do mesmo projeto (omitido = `default`).
- **Processamento on-demand** — `/bus` lê o inbox, valida o token, executa os handoffs e arquiva.
- **Autenticação por token** — handoffs forjados vão pra quarentena (`rejected/`) antes de qualquer execução.
- **Auto-nome por sessão** — define o slug 1× por sessão; religações são só `/bus`.
- **Linha de despacho** — cada envio diz ao operador onde disparar o próximo `/bus`.
- **Operação desassistida automática** — o `/bus` arma sozinho um recheck **a cada 1 min** (cron de sessão) pra processar handoffs quando você sai.
- **Gate de concorrência (anti-overload, opcional)** — um hook serializa o trabalho disparado por `/bus` num **lock global** (1 por máquina): como o limite de requisições é da **conta** Claude (não do projeto), só um especialista trabalha por vez; os demais deferem **sem gastar API**, e checagens de inbox vazia ficam de graça. Setup na seção [Gate de concorrência](#gate-de-concorrência-opcional).

## Instalação

```
/plugin marketplace add tnatanael/claude-bus
/plugin install bus@claude-bus
```

## Uso

Em cada sessão que vai participar, rode **uma vez**: `/bus <slug> [projeto]` (ex.: `/bus backend acme`). O projeto isola o BUS — especialistas só veem/endereçam quem está no mesmo projeto (omitido = `default`). Depois, religar/rechecar é só `/bus` (ele lembra slug e projeto pela sessão).

Para mandar trabalho de uma sessão a outra, o especialista escreve um handoff endereçado ao slug do destino e termina o turno com a **linha de despacho**. Você então roda `/bus` no destino pra ele processar. O próprio `/bus` arma um recheck **a cada 1 min** (cron de sessão) que processa handoffs enquanto você está ausente.

## Plataformas

| SO | Runtime | Status |
|---|---|---|
| Windows | PowerShell (nativo) | ✅ testado |
| macOS / Linux | bash (nativo) | ✅ validado em macOS (feedback de Linux bem-vindo) |

Sem dependências: usa o PowerShell do Windows e o bash do macOS/Linux.

## Como funciona

- **BUS** = pasta compartilhada entre as sessões: base `%TEMP%\claude-bus` (Windows) ou `/tmp/claude-bus` (Unix), override pela env `CLAUDE_BUS_ROOT`. O projeto `default` usa a base; um projeto `<p>` usa `<base>/<p>/` (cada um com seu `inbox/ processing/ done/ rejected/ .bus-secret`). O registro `names/` fica na base (global).
- Cada handoff é um arquivo `to-<destino>__from-<origem>__<id>.handoff`, escrito atomicamente e com um token de auth.
- `/bus` chama o leitor `bus-inbox` (one-shot): valida o token de cada handoff endereçado a você, manda os forjados pra `rejected/` e entrega os autênticos pra sessão processar (claim em `processing/`, executa, arquiva em `done/`, devolve retorno se pedido).
- Não há **daemon separado**, presença nem heartbeat: o que reacorda uma sessão é você rodando `/bus` **ou** o cron de auto-recheck dela (a cada 1 min, só enquanto a sessão está aberta). O cron é in-harness — re-invoca a própria sessão e some quando o app fecha; nada de processo órfão.
- **Gate de concorrência (opcional)** — um hook `UserPromptSubmit` (`bin/bus-gate.*`) filtra os `/bus` **antes da API**: defere sem custo se outro especialista segura o **lock global** (`<base>/.bus-lock`) ou se sua inbox está vazia; adquire o lock quando há trabalho pra você. O fim do `/bus` libera o lock (`bin/bus-lock.* --release`); um lease de 30 min é a rede de segurança. Setup abaixo.

## Gate de concorrência (opcional)

O limite de requisições da API é da **conta** Claude, não do projeto — várias sessões trabalhando em paralelo podem causar overload (429/"serviço ocupado"). O gate serializa o trabalho disparado por `/bus` num **lock único por máquina** (`<base>/.bus-lock`) e torna as checagens de inbox vazia **de graça** (bloqueia o `/bus` antes da API). É **opt-in**: registre o hook `UserPromptSubmit` no `settings.json` global (`~/.claude/settings.json`):

```json
{ "hooks": { "UserPromptSubmit": [ { "hooks": [ { "type": "command", "command": "<comando>" } ] } ] } }
```
- **Windows:** `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<raiz>\bin\bus-gate.ps1"`
- **macOS/Linux:** `bash "<raiz>/bin/bus-gate.sh"`

O hook é **fail-open blindado** (erro inesperado nunca trava um prompt; mas num `/bus` ele ainda **tenta adquirir o lock após o erro** — se outro o segura, **defere em vez de sobrepor**, preservando a serialização mesmo sob falha) e só age em `/bus`: grava o `seen` (prova de vida pro dashboard), defere (`exit 2`, **sem custo de API**) se o lock está ocupado ou a inbox vazia, e adquire o lock quando há handoff. O passo final do `/bus` libera o lock; um **lease de 30 min** cobre quedas de sessão. Cada decisão relevante (`acquire`/`acquire-steal`/`defer-race`/`failopen-*`/`release`) vai pra `<base>/.bus-gate.log` (log forense, best-effort, auto-limita em ~512 KB). O dashboard mostra quem segura o lock ("Trabalhando agora"). Sem o hook, o BUS funciona normalmente — só sem a serialização anti-overload.

### Dica: o PO/coordenador processa por último

Cada especialista tem uma **prioridade** (default `1000`; quanto **menor**, mais cede a vez). Um especialista **cede a vez** (defere) quando tem trabalho **e** há handoff pendente pra alguém de prioridade **maior** — igual/menor não bloqueia. Pra um **PO/coordenador** (a sessão que fan-out o trabalho e recebe os retornos), registre com prioridade **baixa**: assim os especialistas terminam primeiro e o PO **consolida no fim**, em vez de competir pelo lock no meio do fluxo.

Set a prioridade pelo **3º argumento do `/bus`**: `/bus <slug> <projeto> <prioridade>`. Ex.: lance o PO com `0`:

```
/bus po acme 0
```

Isso grava `po:0` em `<raiz-do-projeto>/.priority` (linhas `slug:N`; o gate lê pré-LLM, sem reinício). Omitir o 3º arg **não mexe** na prioridade (persiste). **Atenção a starvation:** num projeto sempre cheio de handoffs, um low-prio pode esperar bastante (é o comportamento desejado — "só quando ninguém de prioridade maior tiver"); se incomodar, dá pra adicionar um teto de espera.

## Dashboard ao vivo (incluso)

A pasta [`dashboard/`](dashboard/) traz um app web minúsculo (sem build, sem dependências, só a stdlib do Node) que visualiza o BUS em tempo real, com **seletor de projeto** (um projeto isolado, ou "Todos" agrupado): handoffs transitando por `inbox -> processing -> done`, correlação de respostas por `in_reply_to`, os rejeitados por auth, e **quem segura o lock global agora** ("Trabalhando agora", com a expiração do lease). É **estritamente somente leitura** sobre o BUS.

```
node dashboard/server.js           # http://localhost:7878 (porta via env PORT)
node --watch dashboard/server.js   # idem, com auto-reload ao salvar o server.js (Node 20+)
```

Detalhes e contrato da API em [`dashboard/README.md`](dashboard/README.md) e [`dashboard/ARCHITECTURE.md`](dashboard/ARCHITECTURE.md).

## Segurança

A pasta do BUS é gravável por qualquer processo do seu usuário. O token (`.bus-secret`) barra injeção **casual**, não malware dedicado que leia o disco. O `bus-inbox` valida o token antes de a sessão tratar o corpo como comando. Use em ambiente de confiança e em sessões em modo auto que você controla.

## Licença

MIT
