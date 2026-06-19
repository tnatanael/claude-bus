# claude-bus

Plugin do **Claude Code** para **comunicação assíncrona entre sessões** ("especialistas"). Cada sessão vira um especialista; eles trocam **handoffs** por um BUS de arquivos.

**Modelo pull (sem monitor de fundo).** Você roda `/bus` numa sessão e ela processa na hora os handoffs pendentes pra ela. Quem envia termina com uma linha de despacho (`📨 Handoffs para: x, y, z`) dizendo onde rodar `/bus` em seguida. Versões anteriores usavam um monitor autônomo em background; ele foi removido — gastava token à toa e morria em silêncio quando o host matava o processo. Pull é simples, confiável e tem **custo ocioso zero**.

- **Processamento on-demand** — `/bus` lê o inbox, valida o token, executa os handoffs e arquiva.
- **Autenticação por token** — handoffs forjados vão pra quarentena (`rejected/`) antes de qualquer execução.
- **Auto-nome por sessão** — define o slug 1× por sessão; religações são só `/bus`.
- **Linha de despacho** — cada envio diz ao operador onde disparar o próximo `/bus`.
- **Operação desassistida opcional** — `/loop 1h /bus` recheca o inbox de hora em hora quando você sai.

## Instalação

```
/plugin marketplace add tnatanael/claude-bus
/plugin install bus@claude-bus
```

## Uso

Em cada sessão que vai participar, rode **uma vez**: `/bus <slug>` (ex.: `/bus pd-nas`). Depois, religar/rechecar é só `/bus` (ele lembra o slug pela sessão).

Para mandar trabalho de uma sessão a outra, o especialista escreve um handoff endereçado ao slug do destino e termina o turno com a **linha de despacho**. Você então roda `/bus` no destino pra ele processar. Para cobrir o período em que está ausente, arme `/loop 1h /bus` nas sessões — elas recheckam o inbox a cada hora.

## Plataformas

| SO | Runtime | Status |
|---|---|---|
| Windows | PowerShell (nativo) | ✅ testado |
| macOS / Linux | bash (nativo) | ✅ validado em macOS (feedback de Linux bem-vindo) |

Sem dependências: usa o PowerShell do Windows e o bash do macOS/Linux.

## Como funciona

- **BUS** = pasta compartilhada entre as sessões: `%TEMP%\claude-bus` (Windows) ou `/tmp/claude-bus` (Unix). Override pela env `CLAUDE_BUS_ROOT`. Subpastas: `inbox/ processing/ done/ rejected/ names/`.
- Cada handoff é um arquivo `to-<destino>__from-<origem>__<id>.handoff`, escrito atomicamente e com um token de auth.
- `/bus` chama o leitor `bus-inbox` (one-shot): valida o token de cada handoff endereçado a você, manda os forjados pra `rejected/` e entrega os autênticos pra sessão processar (claim em `processing/`, executa, arquiva em `done/`, devolve retorno se pedido).
- Não há processo de fundo, presença ou heartbeat: uma sessão só age quando você roda `/bus` nela (ou o `/loop` ticar).

## Dashboard ao vivo (incluso)

A pasta [`dashboard/`](dashboard/) traz um app web minúsculo (sem build, sem dependências, só a stdlib do Node) que visualiza o BUS em tempo real: a **lista de despacho** (handoffs pendentes por destino — onde rodar `/bus`), handoffs transitando por `inbox -> processing -> done`, correlação de respostas por `in_reply_to`, e os rejeitados por auth. É **estritamente somente leitura** sobre o BUS.

```
node dashboard/server.js   # http://localhost:7878 (porta via env PORT)
```

Detalhes e contrato da API em [`dashboard/README.md`](dashboard/README.md) e [`dashboard/ARCHITECTURE.md`](dashboard/ARCHITECTURE.md).

## Segurança

A pasta do BUS é gravável por qualquer processo do seu usuário. O token (`.bus-secret`) barra injeção **casual**, não malware dedicado que leia o disco. O `bus-inbox` valida o token antes de a sessão tratar o corpo como comando. Use em ambiente de confiança e em sessões em modo auto que você controla.

## Licença

MIT
