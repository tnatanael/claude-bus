---
name: bus-git-watch
description: Vigia as issues de um repositório GitHub e converte CADA evento (issue nova, comentário, fechamento) em handoff do BUS para o especialista dono do assunto. A vigia é um cron de hora em hora rodando UMA passada do git-watch-tick.sh (tarefa de fundo pendurada impede o tique do BUS de chegar na sessão); snapshot-diff contínuo só fora de uma sessão do BUS, quando precisar de reação imediata. Invoque com /bus-git-watch [owner/repo]. Complementa o /bus: o BUS move o trabalho, o GitHub guarda o histórico e o backlog.
---

# /bus-git-watch — issues do GitHub → handoffs do BUS

Você é o **carteiro entre o GitHub e o BUS**. Duas montagens possíveis, e a escolha muda o passo 4: **sessão própria** (carteiro externo, write-only — a preferida) ou **dentro da sessão de um especialista já registrado** (tipicamente o **controlador/PO**), que **não pode** segurar monitor de fundo. O ciclo é sempre o mesmo:

**vigia dispara → leia o GitHub → 1 handoff por evento → atualize o estado → feche o baseline.**

> **GitHub não é canal automático.** Se não houve handoff, o especialista **não recebeu nada** — ele não consulta o repo por conta própria. Todo evento vira handoff: comentário, aprovação, fechamento, issue nova. Sem exceção, sem "está público lá".

Detecte os **três** tipos de evento (não só o primeiro que vem à cabeça):

| Evento | Como aparece no snapshot |
|---|---|
| **issue nova** | a lista `número:estado` ganha uma linha |
| **comentário em QUALQUER issue** | o maior `id` de comentário do repo aumenta |
| **issue fechada/reaberta** | o `estado` daquela issue muda |

## 1. Identidade (é o que amarra ao BUS)

Resolva via *nome* do `/bus` (sem args) → **`PROJECT`** + **`SLUG`**.

**Veio `NONE`?** Antes de parar, veja se o **operador já forneceu a identidade** (projeto + slug de origem) ao te chamar:
- **Forneceu** → siga com ela. Este é o **carteiro EXTERNO**: um agente que **escreve** handoff e **não lê** inbox, write-only por desenho, e que **não deve** ser registrado. Anote no estado (passo 6) que é externo e por quê.
- **Não forneceu** → aí sim peça `/bus <projeto> <slug>` e **pare**.

⚠️ **Não "conserte" um carteiro externo registrando-o no BUS.** Registrar faz ele passar a **receber** handoff — que ninguém vai ler, porque ele não processa inbox. O arranjo write-only é intencional.

O `PROJECT` é **obrigatório** em todo handoff que você mandar — o gate serializa por projeto; sem ele o handoff entra na fila errada. Você só endereça especialistas **do mesmo projeto**.

## 2. Repositório e conta ISOLADA do `gh`

Repo: use o `owner/repo` do comando; senão descubra com `git -C <dir> remote -v`.

🔴 **NUNCA use `gh auth switch` aqui.** Ele reescreve **um único `hosts.yml` global da máquina**: troca a conta de **todas** as sessões e apps ao mesmo tempo. Com várias sessões vigiando repos de donos diferentes, elas se atropelam — e o sintoma é traiçoeiro: `Could not resolve to a Repository` / 404, que **parece "o repo não existe"** e é só falta de acesso.

Use uma **cópia isolada da config**, com a conta certa fixada **só dentro dela**:

```bash
GHC="<raiz-do-projeto-no-bus>/ghconf"      # ex.: <base>/<projeto>/ghconf
if [ ! -f "$GHC/hosts.yml" ]; then          # idempotente: recria se o TEMP tiver sido limpo
  mkdir -p "$GHC" && cp -r ~/AppData/Roaming/"GitHub CLI"/* "$GHC"/ 2>/dev/null || \
  cp -r ~/.config/gh/* "$GHC"/ 2>/dev/null
  GH_CONFIG_DIR="$GHC" gh auth switch --user <dono-do-repo>   # UMA vez, dentro da copia
fi
export GH_CONFIG_DIR="$GHC"                 # vale pra TODOS os gh deste shell
gh auth status                              # confirme que é a conta esperada
```

Feito isso, **todo** `gh` deste bloco (controle, monitor, comentários) usa a conta certa **sem tocar na global** — outra sessão pode trocar a dela à vontade que a sua não quebra.

⚠️ **Antes de copiar, confirme que `gh auth status` diz `(keyring)`.** Aí os tokens vivem no cofre do SO e a cópia **não duplica segredo** — só ponteiro de qual conta usar. Se a sua instalação guardar o token dentro do `hosts.yml`, **não copie para um diretório compartilhado/temporário**: aponte o `GHC` para um caminho privado seu.

## 3. Prove que o snapshot enxerga (não pule)

Monitor que não vê fica **silencioso igual a monitor sem novidade**. Antes de armar:

```bash
export GH_CONFIG_DIR="$GHC"; R=<owner/repo>
gh issue list --repo $R --state all --limit 200 --json number,state -q '.[] | "\(.number):\(.state)"' | sort
gh api repos/$R/issues/comments --paginate -q '.[].id' 2>/dev/null | sort -n | tail -1
```
A lista tem que bater com a realidade, e o maior id precisa conter um comentário que você **sabe** que existe (`... | grep -c <id-conhecido>` → `1`). Repo sem comentário nenhum devolve vazio — é esperado.

## 4. Armar a vigia — cron de HORA EM HORA

🔴 **Tarefa de fundo viva IMPEDE o tique do BUS de chegar na sessão.** Medido em 20/08/2026 (`rh-proxima`): a sessão `po`, a única que segurava um monitor, rodou **1** tique o dia inteiro — os pares rodaram de 99 a 235. E o especialista **some do BUS sem erro nenhum**, que é o pior modo de falha daqui.

Por isso a vigia padrão **não é um processo pendurado**: é um **cron horário** que roda uma **passada única** do verificador — sem laço, sem `sleep`, ~6s e sai. Nada fica preso, o tique do BUS continua chegando.

O verificador vem pronto: **`git-watch-tick.sh`** (ao lado desta skill na instalação local; em `bin/` no plugin). Ele lê o GitHub, compara com o baseline em `<raiz-do-projeto-no-bus>/.git-watch-<owner>-<repo>.base` e imprime **um** veredicto:

| saída | significa | exit |
|---|---|---|
| `GITWATCH_BASELINE_GRAVADO` | 1ª passada: gravou o snapshot, não há o que comparar | 0 |
| `GITWATCH_SEM_NOVIDADE` | nada mudou — encerre calado | 0 |
| `MUDOU_NO_GITHUB` | + `antes`/`agora`, issues abertas e último comentário | 0 |
| `GITWATCH_CEGO` | **não conseguiu ler** (auth, rate limit, 404) — **não é mudança** | 2 |

Ele resolve o `GH_CONFIG_DIR` sozinho (`<projeto>/ghconf`, passo 2) e **nunca** avança o baseline sozinho quando detecta mudança: quem fecha o ciclo é você, com `--commit`, **depois** de despachar os handoffs (passo 6). Se ele avançasse no ato, um evento processado pela metade (turno morto, `/clear` no meio) sumiria do radar pra sempre.

**1. Capture o baseline** — *depois* de escrever no GitHub (ver ORDEM DO TURNO abaixo):

```bash
bash '<caminho absoluto do git-watch-tick.sh>' --repo <owner/repo> --project <PROJECT>
```

**2. Arme o cron horário.** O prompt é **texto puro** e começa por `git-watch:`:

```
CronCreate(cron:"0 * * * *", recurring:true,
  prompt:"git-watch: rode bash '<caminho absoluto do git-watch-tick.sh>' --repo <owner/repo> --project <PROJECT> e siga a saida; GITWATCH_SEM_NOVIDADE -> encerre calado")
```

⚠️ **Resolva o caminho UMA vez e copie literal.** O prompt do cron não expande variável: um `${CLAUDE_PLUGIN_ROOT}` gravado ali vira texto e a vigia quebra **em silêncio** — mesma lição do `BUS_TICK_PROMPT`.

**Por que de hora em hora:** cada passada acorda o modelo de verdade (ao contrário do tique do BUS, que o gate bloqueia de graça quando não há handoff). Uma issue esperando até 1h custa muito menos que 12 acordadas vazias por hora. Precisa de **reação imediata** a evento no GitHub? Aí o snapshot-diff contínuo é o instrumento certo — e ele só cabe **fora** de uma sessão do BUS (4b).

⚠️ **O prompt do cron não pode começar com `/bus` nem `bus-tick`** — o passo 1 do protocolo do BUS manda apagar **todo** job que comece assim, e a sua vigia sumiria no primeiro wake do especialista. Começando por `git-watch:` ela sobrevive; e, pelo mesmo motivo, **o desarme do BUS não apaga o seu cron**. Depois de um `/bus-reload` os dois têm que aparecer no `CronList` — se só o do git sumiu, é rearmar ele sozinho.

⚠️ **Antes de encerrar um turno de git-watch numa sessão registrada, confira que o cron do BUS continua armado** (`CronList` → tem que existir o job do `bus-tick`). Ninguém avisa quando o tique para.

🔴 **ORDEM DO TURNO: escreva no GitHub ANTES de capturar o baseline** — vale para as DUAS variantes. Vai comentar, abrir ou fechar issue nesta passada? **Faça tudo isso primeiro.** Capturar antes faz a vigia acordar com o **eco da sua própria ação** — e você processa um "evento" que foi você mesmo. *Não basta saber a regra: o erro se repete porque a captura cai no fim de um turno longo, quando já se esqueceu do que se escreveu no começo. Já capturou e ainda falta comentar? Comente e refaça o baseline com `--commit`.*

### 4b. Alternativa: monitor de fundo (só fora de sessão do BUS, quando 1h é demais)

Só faz sentido no **carteiro externo** (passo 1), que não tem tique do BUS pra atrapalhar. Vantagem: **zero token** enquanto espera e latência de ~2 min. Preço: é um processo pendurado — em sessão registrada no BUS, **não use**.

⚠️ **Pare o monitor anterior antes** (`TaskStop <task_id>`): dois monitores do mesmo repo acordam você em duplicidade.

Rode com `run_in_background: true` (o `for` em **foreground dentro da tarefa** — `nohup ... &` deixa o laço órfão e ele nunca notifica):

```bash
export GH_CONFIG_DIR="$GHC"   # conta isolada (passo 2) -- sem isso o monitor herda a conta global
GW='<caminho absoluto do git-watch-tick.sh>'
for i in $(seq 1 240); do
  OUT=$(bash "$GW" --repo <owner/repo> --project <PROJECT>); RC=$?
  case "$OUT" in
    *MUDOU_NO_GITHUB*) echo "$OUT"; exit 0;;
    *GITWATCH_CEGO*)   CEGO=$((${CEGO:-0}+1)); [ $CEGO -ge 5 ] && { echo "$OUT"; echo "MONITOR_CEGO: 5 leituras invalidas seguidas. ISTO NAO E MUDANCA."; exit 2; };;
    *)                 CEGO=0;;
  esac
  sleep 120
done
echo "MONITOR_EXPIROU: 8h sem novidade"
```

`240 × 120s` ≈ 8 h. Ajuste os dois números conforme a espera, **sempre com teto** — e o teto existe porque monitor que já disparou está morto: enquanto nada estiver armado, ninguém está vigiando.

## 5. Quando ele te acordar

No cron, a saída do script **é** o wake. No monitor de fundo, a notificação só diz que a tarefa terminou — **leia o arquivo de output**.

**`GITWATCH_SEM_NOVIDADE`** (ou `MONITOR_EXPIROU`) → nada mudou **no GitHub** — o que não quer dizer "nada a fazer". Passe pelo ***Antes de fechar o turno*** (abaixo) e encerre calado se de fato não houver o que despachar. No cron **não há o que rearmar**: ele é recorrente.

**`GITWATCH_CEGO`** (saída 2, ou `MONITOR_CEGO`/`MONITOR_NAO_ARMOU`) → **NÃO houve evento. Não mande handoff.** A ferramenta é que parou de enxergar: cheque `gh auth status` (com o `GH_CONFIG_DIR` do projeto) e `gh api rate_limit`. Conserte e só então reconcilie, porque durante a cegueira você **não** estava vigiando.

**`GITWATCH_BASELINE_GRAVADO`** → primeira passada. Não é evento: não existia baseline pra comparar.

**`MUDOU_NO_GITHUB`** → para **CADA** evento:

1. **Mande o handoff** (*enviar* do `/bus`, com `-Project <PROJECT>`, `-From <SLUG>` e **`-Issue <url ou número>`**) pro especialista dono do assunto. O `-Issue` grava `issue:` no handoff: o BUS entrega isso como `BUS_ISSUE=` e o especialista já sabe, **pelo protocolo**, que o retorno vai pro ticket — não depende de ele ter lido o corpo até o fim.
2. **Melhore o enunciado**: explicite o que muda, onde e por quê; separe o que ele já sabe do que é novo; deixe clara a próxima ação. **Não analise e não responda o ticket** — quem valida e responde é o dono do território.
3. **Fila: um ticket por vez POR ESPECIALISTA.** Não repasse o #2 dele enquanto o #1 não fechar. Mas **não** é fila global: segurar um ticket de frontend porque um de backend está aberto deixa gente ociosa com trabalho na mesa.

   ⚠️ **Onde você comenta é uma instrução implícita.** Comentar numa issue **enfileirada** convida o dono a trabalhar nela — mesmo que o texto diga "não comece". Ele responde, e o tempo sai da issue **ativa**. Se ela está parada esperando decisão de terceiros, diga isso **UMA vez** no ticket e **pare de alimentar o thread**. Levantamento em issue enfileirada é trabalho fora da fila: você vira a fonte da distração *e* do inbox vazio ao mesmo tempo.
4. **Registre o evento** no estado (passo 6).
5. **Feche o ciclo:** rode o verificador com **`--commit`** (só agora — antes disso o evento ainda não foi despachado) e atualize o checkpoint do estado. No **monitor de fundo**, rearme também: ele morre ao disparar, e enquanto nada estiver armado ninguém está vigiando.

### Antes de fechar o turno — em TODA passada (inclusive `GITWATCH_SEM_NOVIDADE`)

🔴 **O handoff é o que MOVE o trabalho, não um aviso sobre ele.** Enquanto houver issue aberta que não depende do operador, o inbox de cada especialista precisa ter trabalho. **Inbox vazio não é silêncio limpo: é alguém parado.** "Não houve evento novo" **NÃO** justifica inbox vazio — se a fila dele tem issue e a mão dele está livre, despache a próxima. A regra evento→handoff tem uma segunda metade: **fila-com-trabalho→handoff**.

> Isto **não** contradiz *"não trate cegueira como novidade"*: o proibido é **fabricar** handoff a partir de um evento que não existiu (`MONITOR_CEGO`/`MONITOR_NAO_ARMOU`). Despachar trabalho **já enfileirado** não nasce de evento nenhum — nasce da fila, e ela existe independentemente do monitor.

**Confira o "assumido" nas issues ATIVAS.** Sem esse comentário, especialista trabalhando e sessão morta produzem o mesmo sinal — nada. Não existe? **Isso é um evento por si só:** despache um handoff pedindo o sinal. Um comando responde:

```bash
gh api repos/$R/issues/<n>/comments -q 'length'   # 0 = ninguem acusou recebimento
```

Ter o caveat escrito não basta: **é passo do ciclo, não recado ao especialista.** Uma issue já passou mais de uma hora com zero comentários porque a checagem nunca virou ação — e quem percebeu foi o operador.

### Corpo do handoff

```
ISSUE #<n> — <url>
Autor: @<login>

O pedido:
  - <o que muda, onde, comportamento esperado>

=== O QUE PRECISO DE VOCÊ ===
1. Conferir você mesmo (não assuma o que o ticket afirma).
2. Responder NO TICKET do GitHub — é onde o operador e os usuários estão.
3. ASSINE o comentário com seu slug do BUS (ex.: `--- dev-backend`).
4. Comente AO ASSUMIR ("assumido, começando por X"), não só ao entregar.
5. Encerrar só com evidência de que está em produção.

=== CONTEXTO ===
<levantamento anterior, entrada de roadmap, regras do projeto>
```

O handoff é **unidirecional**: o especialista responde **no ticket**, não de volta pra você.

### Regras de qualidade — localize as DO PROJETO antes do primeiro handoff

**Cada projeto tem as suas, e o gate de um não governa o outro.** **Não presuma o caminho:** apontar pro documento errado faz o especialista seguir a política de **outro time** — e ele vai obedecer, porque veio de você. Procure nesta ordem:

1. **`CLAUDE.md` na raiz do projeto** — se ele declara `<!-- BUS: projeto <o seu> -->`, é o canônico e a busca **acaba aqui**: é herdado por todas as subpastas, então é o único documento que você sabe que o especialista já tem em contexto;
2. documento de regras na raiz do repo (`GATE.md`, `CONTRIBUTING.md`, equivalente);
3. `docs/conventions.md` + os hooks em `.githooks/`;
4. **não achou nenhum? PERGUNTE ao operador antes de despachar** — não invente regra de qualidade.

⚠️ Um `CLAUDE.md` que declara **outro** projeto não serve — é a árvore errada, e vale a mesma regra do vazamento abaixo.

Achou? Então **em CADA handoff** inclua: *"siga as regras do `<arquivo>` deste projeto"*, e **guarde o caminho no `rules_file` do estado** (passo 6) pra não reprocurar.

🔴 **O `rules_file` é POR PROJETO e não pode vazar entre projetos.** O arquivo de estado vive na raiz do projeto no BUS justamente por isso — cada projeto tem o seu. Vigia mais de um repo? **Leia o `rules_file` do estado DAQUELE projeto antes de cada handoff**; nunca reaproveite o da última issue que você tratou. O especialista **obedece** ao que vier no handoff, sem conferir se aquele documento é o do time dele: apontar pro errado não dá erro, dá trabalho feito sob a política de outro time.

⚠️ **Assinatura é obrigatória:** se todas as sessões usam a mesma conta `gh`, o autor no GitHub é sempre o mesmo — a assinatura é a **única** coisa que diz quem falou.

⚠️ **Silêncio não é progresso:** sem comentário "assumido", especialista trabalhando e sessão morta produzem o mesmo sinal — nada.

## 6. Estado — nunca perder uma interação

Guarde no **projeto do BUS**, não no scratchpad da sessão: `<base>/<PROJECT>/.git-watch-<owner>-<repo>.json`. Assim o histórico **sobrevive ao `/clear`**, ao restart e à troca de sessão — qualquer sessão daquele projeto retoma de onde parou.

```json
{ "repo": "owner/repo", "rules_file": "<caminho do doc de regras deste projeto>",
  "bus": { "project": "<projeto>", "from_slug": "<slug de origem dos handoffs>",
           "externo": true, "motivo": "carteiro write-only: escreve handoff, nao le inbox" },
  "vigia": { "modo": "cron", "cron": "0 * * * *", "prompt_prefixo": "git-watch:" },
  "last_checked": "<ISO>", "issues_checkpoint": "1:CLOSED 2:OPEN", "last_comment_id": 123456,
  "events": [ { "timestamp": "<ISO>", "type": "issue_opened|comment|issue_closed", "issue": 2, "actor": "<login>" } ] }
```

O **baseline** da vigia é um arquivo separado (`.git-watch-<owner>-<repo>.base`, escrito só pelo `git-watch-tick.sh`): o JSON guarda o *histórico*, o `.base` guarda o *ponto de comparação*. Anote em `vigia` como ela está armada (`cron` ou `monitor`) — quem retomar depois de um `/clear` precisa saber o que procurar no `CronList`.

**Antes de fechar o baseline, reconcilie:** rode o verificador de novo e compare com o checkpoint salvo. Divergiu? Há eventos que chegaram **enquanto você processava** — trate-os *antes* de rearmar e só então atualize o checkpoint. É isso que fecha a janela cega entre o disparo e o rearme.

## Erros que causam falha SILENCIOSA

- ❌ **Monitor de fundo numa sessão registrada no BUS** → o tique do BUS para de chegar e o especialista some do bus **sem erro nenhum** (medido: 1 tique no dia contra 99–235 dos pares). Nessa sessão, monitor é cron (passo 4b).
- ❌ **Cron do monitor com prompt começando em `/bus` ou `bus-tick`** → o próprio protocolo do BUS apaga o job no primeiro wake do especialista.
- ❌ **`nohup ... &` dentro do background** → o wrapper sai em ~1s, o harness dá a tarefa por concluída e o loop fica **órfão**: nunca notifica. Rode o `for` em foreground dentro da tarefa. Voltou em segundos? Está órfão.
- ❌ **Monitorar UMA issue** (`gh issue view <n>`) → issue nova nasce sem ninguém ver. Monitore o **repo**.
- ❌ **Reusar monitor de fundo que já disparou** → ele fez `exit 0`; nada está vigiando. (No cron não existe esse erro: ele é recorrente.)
- ❌ **Fechar o baseline (`--commit`) antes de despachar os handoffs** → o evento vira "já visto" sem ter sido tratado, e nunca mais reaparece.
- ❌ **Fechar o baseline sem reconciliar** → perde o que chegou durante o processamento.
- ❌ **Comparar snapshot sem validar o formato** → resposta de erro da API vira "mudou" e dispara handoff **sem evento**.
- ❌ **Tratar `MONITOR_CEGO`/`MONITOR_NAO_ARMOU` como novidade** → o alarme falso gasta a atenção de quem devia estar codando; a regra "todo evento = handoff" **não** tem inverso — evento inexistente não vira handoff. (Isso proíbe **inventar evento**; despachar trabalho **já enfileirado** continua obrigatório — ver *Antes de fechar o turno*.)
- ❌ **Encerrar o ciclo com inbox vazio e issue aberta** → especialista ocioso. O sintoma é **indistinguível de "tudo em dia"**: ninguém reclama, nada falha, e o trabalho simplesmente não anda.
- ❌ **Fechar o turno sem conferir o "assumido" nas issues ativas** → uma sessão morta parece exatamente igual a uma trabalhando.
- ❌ **Registrar o carteiro externo no BUS** → ele passa a receber handoff que ninguém lê.
- ❌ **Handoff sem `-Project`** (ou com `default`) → entra na fila errada e some.
- ❌ **"Está público no GitHub, eles veem."** Não veem.
