# claude-bus

Plugin do **Claude Code** para **comunicação assíncrona entre sessões** ("especialistas"). Cada sessão vira um especialista; eles trocam **handoffs** por um BUS de arquivos, com:

- **Wake autônomo** — a sessão-alvo (se aberta) acorda sozinha quando chega um handoff.
- **Presença** (`bus-who`) — veja quem está realmente escutando, sem adivinhar.
- **Autenticação por token** — handoffs forjados vão pra quarentena.
- **Auto-nome por sessão** — define o slug 1× por sessão; religações são só `/bus`.
- **Singleton + busy/free** — sem processos-zumbi; o wake não chega no meio de um turno ocupado.

## Instalação

```
/plugin marketplace add tnatanael/claude-bus
/plugin install bus@claude-bus
```

Os hooks (`UserPromptSubmit` / `Stop` / `PostToolUse`) entram automaticamente com o plugin (sem editar `settings.json`).

## Uso

Em cada sessão que vai participar, rode **uma vez**: `/bus <slug>` (ex.: `/bus pd-nas`). Depois disso, religar é só `/bus` (ele lembra o slug pela sessão).

Para mandar trabalho de uma sessão a outra, o especialista escreve um handoff endereçado ao slug do destino; o destino acorda e processa. Acompanhe quem está ativo com o `bus-who`.

## Plataformas

| SO | Runtime | Status |
|---|---|---|
| Windows | PowerShell (nativo) | ✅ testado |
| macOS / Linux | bash (nativo) | ✅ validado em macOS (feedback de Linux bem-vindo) |

Sem dependências a instalar: usa o PowerShell do Windows e o bash do macOS/Linux.

## Como funciona

- **BUS** = pasta compartilhada entre as sessões: `%TEMP%\claude-bus` (Windows) ou `/tmp/claude-bus` (Unix). Override pela env `CLAUDE_BUS_ROOT`.
- **Monitor** roda em background, faz polling no shell (não gasta tokens do modelo) e sai ao achar um handoff → isso re-invoca/acorda a sessão.
- **Hooks** marcam a sessão `busy`/`free`; o monitor só entrega o handoff quando `free`, pra o wake não ser engolido no meio de um turno.
- **Heartbeat de presença** é atualizado pelo monitor (durante a ociosidade) e por um hook `PostToolUse` (durante a atividade). Como o monitor sai ao entregar um handoff e só volta no fim do turno, o hook mantém uma sessão que está trabalhando "viva" na presença mesmo sem monitor; já uma sessão que parou de verdade some da presença. É isso que deixa o dashboard distinguir "processando" de "offline".

## Dashboard ao vivo (incluso)

A pasta [`dashboard/`](dashboard/) traz um app web minúsculo (sem build, sem dependências, só a stdlib do Node) que visualiza o BUS em tempo real: presença das sessões (busy / free / offline), handoffs transitando por `inbox -> processing -> done`, correlação de respostas por `in_reply_to`, e os rejeitados por auth. É **estritamente somente leitura** sobre o BUS.

```
node dashboard/server.js   # http://localhost:7878 (porta via env PORT)
```

Detalhes e contrato da API em [`dashboard/README.md`](dashboard/README.md) e [`dashboard/ARCHITECTURE.md`](dashboard/ARCHITECTURE.md).

## Segurança

A pasta do BUS é gravável por qualquer processo do seu usuário. O token (`.bus-secret`) barra injeção **casual**, não malware dedicado que leia o disco. Use em ambiente de confiança e em sessões em modo auto que você controla.

## Licença

MIT
