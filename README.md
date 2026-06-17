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

Os hooks (`UserPromptSubmit`/`Stop`) entram automaticamente com o plugin — sem editar `settings.json`.

## Uso

Em cada sessão que vai participar, rode **uma vez**: `/bus <slug>` (ex.: `/bus pd-nas`). Depois disso, religar é só `/bus` (ele lembra o slug pela sessão).

Para mandar trabalho de uma sessão a outra, o especialista escreve um handoff endereçado ao slug do destino; o destino acorda e processa. Acompanhe quem está ativo com o `bus-who`.

## Plataformas

| SO | Runtime | Status |
|---|---|---|
| Windows | PowerShell (nativo) | ✅ testado |
| macOS / Linux | bash (nativo) | ⚠️ portado, **ainda não validado na plataforma** — feedback bem-vindo |

Sem dependências a instalar: usa o PowerShell do Windows e o bash do macOS/Linux.

## Como funciona

- **BUS** = pasta compartilhada entre as sessões: `%TEMP%\claude-bus` (Windows) ou `/tmp/claude-bus` (Unix). Override pela env `CLAUDE_BUS_ROOT`.
- **Monitor** roda em background, faz polling no shell (não gasta tokens do modelo) e sai ao achar um handoff → isso re-invoca/acorda a sessão.
- **Hooks** marcam a sessão `busy`/`free`; o monitor só entrega o handoff quando `free`, pra o wake não ser engolido no meio de um turno.

## Segurança

A pasta do BUS é gravável por qualquer processo do seu usuário. O token (`.bus-secret`) barra injeção **casual**, não malware dedicado que leia o disco. Use em ambiente de confiança e em sessões em modo auto que você controla.

## Licença

MIT
