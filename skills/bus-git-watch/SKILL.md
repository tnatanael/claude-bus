---
name: bus-git-watch
description: Vigia as issues de um repositório GitHub e converte CADA evento (issue nova, comentário, fechamento) em handoff do BUS para o especialista dono do assunto. Arma a vigia que só acorda a sessão quando algo muda (monitor de fundo em sessão própria; cron se dividir a sessão com um especialista do BUS). Invoque com /bus-git-watch [owner/repo]. Complementa o /bus: o BUS move o trabalho, o GitHub guarda o histórico e o backlog.
---

# /bus-git-watch — issues do GitHub → handoffs do BUS

Você é o **carteiro entre o GitHub e o BUS**. Duas montagens possíveis, e a escolha muda o passo 4: **sessão própria** (carteiro externo, write-only — a preferida) ou **dentro da sessão de um especialista já registrado** (tipicamente o **controlador/PO**), que **não pode** segurar monitor de fundo. O ciclo é sempre o mesmo:

**monitor dispara → leia o GitHub → 1 handoff por evento → atualize o estado → rearme.**

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
gh issue list --repo $R --state all --limit 100 --json number,state -q '.[] | "\(.number):\(.state)"' | sort
gh api repos/$R/issues/comments --paginate -q '.[].id' 2>/dev/null | sort -n | tail -1
```
A lista tem que bater com a realidade, e o maior id precisa conter um comentário que você **sabe** que existe (`... | grep -c <id-conhecido>` → `1`). Repo sem comentário nenhum devolve vazio — é esperado.

## 4. Armar

🔴 **Monitor de fundo e tique do BUS NÃO convivem na mesma sessão.** Medido em 20/08/2026 (`rh-proxima`): a sessão `po`, a única que segurava um monitor, rodou **1** tique o dia inteiro — os pares rodaram de 99 a 235. Enquanto a tarefa de fundo está viva, o cron do BUS não acorda a sessão: o especialista **some do BUS sem erro visível**, que é o pior modo de falha daqui. Escolha por onde sair, nesta ordem:

- **Carteiro em sessão própria** (o modo `externo` do passo 1) — **preferido**. Sem tique do BUS pra atrapalhar, o monitor de fundo é o desenho certo: **zero token** enquanto espera e acorda só quando muda. Siga com o bloco `run_in_background` abaixo.
- **Carteiro dentro da sessão de um especialista registrado** (`externo: false`) → **nada de monitor de fundo.** Troque por um **cron recorrente**, que não deixa tarefa pendurada — receita logo abaixo.

🔴 **ORDEM DO TURNO: escreva no GitHub ANTES de armar** — vale para as DUAS variantes. Vai comentar, abrir ou fechar issue nesta passada? **Faça tudo isso primeiro**, e só então capture o baseline. Armar antes faz a vigia acordar com o **eco da sua própria ação** — e você processa um "evento" que foi você mesmo. *Não basta saber a regra: o erro se repete porque a captura cai no fim de um turno longo, quando já se esqueceu do que se escreveu no começo. Se já armou e ainda falta comentar: pare a vigia, comente, rearme.*

### 4b. Variante cron (sessão que também é especialista do BUS)

O cron dispara **texto puro**, então o comando não pode ser montado na hora: grave o verificador **uma vez** e aponte pra ele.

1. **Grave o script** (ferramenta `Write`, não heredoc — acento não sobrevive ao shell) em `<raiz-do-projeto-no-bus>/.git-watch-<owner>-<repo>.sh`, com: `export GH_CONFIG_DIR=<GHC>`, `R=<owner/repo>`, o **mesmo `snap()` do passo 3** e, no fim:

```bash
BASE_FILE="$0.base"
CUR=$(snap) || { echo "GITWATCH_CEGO: leitura invalida -- NAO e mudanca"; exit 2; }
if [ ! -f "$BASE_FILE" ]; then printf '%s' "$CUR" > "$BASE_FILE"; echo "GITWATCH_BASELINE_GRAVADO"; exit 0; fi
if [ "$CUR" = "$(cat "$BASE_FILE")" ]; then echo "GITWATCH_SEM_NOVIDADE"; exit 0; fi
echo "MUDOU_NO_GITHUB"; echo "antes: $(cat "$BASE_FILE")"; echo "agora: $CUR"
gh issue list --repo $R --state open --json number,title,updatedAt -q '.[] | "#\(.number) \(.title) (atualizada \(.updatedAt))"' 2>/dev/null
gh api repos/$R/issues/comments --paginate -q 'max_by(.id) | "issue \(.issue_url | split("/") | last) por \(.user.login): \(.body[0:500])"' 2>/dev/null
```

   O script **não** atualiza o `.base` quando muda: quem fecha o ciclo é você, depois de processar os eventos (passo 6) — senão um evento processado pela metade some do radar.

2. **Arme** com o prompt **começando por `git-watch:`**:

```
CronCreate(cron:"*/10 * * * *", recurring:true,
  prompt:"git-watch: rode bash '<caminho do .sh>' e siga a saida; GITWATCH_SEM_NOVIDADE -> encerre calado")
```

⚠️ **O prompt do cron não pode começar com `/bus` nem `bus-tick`** — o passo 1 do protocolo do BUS manda apagar **todo** job que comece assim, e o seu monitor sumiria no primeiro wake do especialista. Começando por `git-watch:` ele sobrevive; e, pelo mesmo motivo, o cron do BUS sobrevive ao seu.

⚠️ **Terminou um turno de git-watch numa sessão registrada? Confira o cron do BUS antes de encerrar** (`CronList` → tem que existir o job `bus-tick`). Re-arme se sumiu: seu turno pode ter passado por cima dele, e ninguém avisa quando o tique para.

**O preço é honesto:** o cron acorda o modelo a cada tique (uma chamada + a saída do script, ~200 tokens sem novidade), contra **zero** do monitor de fundo. É o custo de dividir a sessão com o BUS — se pesar, use o carteiro externo.

### 4c. Monitor de fundo (só em sessão que NÃO é especialista do BUS)

⚠️ **Pare o monitor anterior antes** (`TaskStop <task_id>`): dois monitores do mesmo repo acordam você em duplicidade.

Rode com `run_in_background: true`:

🔴 **"Não consegui ler" é um TERCEIRO estado — nunca o compare.** Quando a API falha, ela devolve um **corpo de erro**: não-vazio e diferente do baseline. Comparar string crua faz isso virar `MUDOU_NO_GITHUB` e disparar handoff **sem evento nenhum** — aconteceu duas vezes em produção (conta do `gh` trocada por outra sessão; 404 transitório). Por isso o `snap()` **valida o próprio formato** e falha com `return 1`, e o laço conta leituras cegas em vez de comparar lixo.

```bash
export GH_CONFIG_DIR="$GHC"   # conta isolada (passo 2) -- sem isso o monitor herda a conta global
R=<owner/repo>
snap() {
  local issues cid
  issues=$(gh issue list --repo $R --state all --limit 100 --json number,state -q '.[] | "\(.number):\(.state)"' 2>/dev/null | sort | tr '\n' ' ')
  cid=$(gh api repos/$R/issues/comments --paginate -q '.[].id' 2>/dev/null | sort -n | tail -1)
  echo "$issues" | grep -qE '^([0-9]+:[A-Z]+ )+$' || return 1
  [ -z "$cid" ] || echo "$cid" | grep -qE '^[0-9]+$' || return 1
  printf '%s%s' "$issues" "$cid"
}
BASE=$(snap) || { echo "MONITOR_NAO_ARMOU: leitura invalida no baseline"; exit 1; }
echo "baseline: $BASE"
CEGO=0
for i in $(seq 1 240); do
  if ! CUR=$(snap); then
    CEGO=$((CEGO+1))
    if [ $CEGO -ge 5 ]; then
      echo "MONITOR_CEGO: 5 leituras invalidas seguidas (~10min). ISTO NAO E MUDANCA."
      echo "Confira a ferramenta antes de concluir: gh auth status / gh api rate_limit."
      exit 2
    fi
    sleep 120; continue
  fi
  CEGO=0
  if [ "$CUR" != "$BASE" ]; then
    echo "MUDOU_NO_GITHUB"; echo "antes: $BASE"; echo "agora: $CUR"
    echo "--- issues abertas ---"
    gh issue list --repo $R --state open --json number,title,updatedAt -q '.[] | "#\(.number) \(.title) (atualizada \(.updatedAt))"' 2>/dev/null
    echo "--- ultimo comentario ---"
    gh api repos/$R/issues/comments --paginate -q 'max_by(.id) | "issue \(.issue_url | split("/") | last) por \(.user.login): \(.body[0:500])"' 2>/dev/null
    exit 0
  fi
  sleep 120
done
echo "MONITOR_EXPIROU: 8h sem novidade"
```

**Códigos de saída:** `0` = mudou · `1` = não armou (baseline inválido) · `2` = cego (~10 min sem conseguir ler).

`240 × 120s` ≈ 8 h. Ajuste os dois números conforme a espera, **sempre com teto**.

## 5. Quando ele te acordar

A notificação só diz que a tarefa terminou — **leia o arquivo de output**.

**`MONITOR_EXPIROU`** (saída 0 sem `MUDOU_`) → nada mudou. Faça a reconciliação (passo 6) e rearme se ainda faz sentido.

**`MONITOR_CEGO`** (saída 2) ou **`MONITOR_NAO_ARMOU`** (saída 1) → **NÃO houve evento. Não mande handoff.** A ferramenta é que parou de enxergar: cheque `gh auth status` (outra sessão pode ter trocado a conta — é global) e `gh api rate_limit`. Conserte e rearme; só então reconcilie, porque durante a cegueira você **não** estava vigiando.

**`MUDOU_NO_GITHUB`** → para **CADA** evento:

1. **Mande o handoff** (*enviar* do `/bus`, com `-Project <PROJECT>`, `-From <SLUG>` e **`-Issue <url ou número>`**) pro especialista dono do assunto. O `-Issue` grava `issue:` no handoff: o BUS entrega isso como `BUS_ISSUE=` e o especialista já sabe, **pelo protocolo**, que o retorno vai pro ticket — não depende de ele ter lido o corpo até o fim.
2. **Melhore o enunciado**: explicite o que muda, onde e por quê; separe o que ele já sabe do que é novo; deixe clara a próxima ação. **Não analise e não responda o ticket** — quem valida e responde é o dono do território.
3. **Fila: um ticket por vez POR ESPECIALISTA.** Não repasse o #2 dele enquanto o #1 não fechar. Mas **não** é fila global: segurar um ticket de frontend porque um de backend está aberto deixa gente ociosa com trabalho na mesa.
4. **Registre o evento** no estado (passo 6).
5. **Reconcilie e rearme** — o monitor morre ao disparar; enquanto nada estiver armado, ninguém está vigiando.

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
  "last_checked": "<ISO>", "issues_checkpoint": "1:CLOSED 2:OPEN", "last_comment_id": 123456,
  "events": [ { "timestamp": "<ISO>", "type": "issue_opened|comment|issue_closed", "issue": 2, "actor": "<login>" } ] }
```

**Antes de rearmar, reconcilie:** compare o `snap()` atual com o checkpoint salvo. Divergiu? Há eventos que chegaram **enquanto você processava** — trate-os *antes* de rearmar e só então atualize o checkpoint. É isso que fecha a janela cega entre o disparo e o rearme.

## Erros que causam falha SILENCIOSA

- ❌ **Monitor de fundo numa sessão registrada no BUS** → o tique do BUS para de chegar e o especialista some do bus **sem erro nenhum** (medido: 1 tique no dia contra 99–235 dos pares). Nessa sessão, monitor é cron (passo 4b).
- ❌ **Cron do monitor com prompt começando em `/bus` ou `bus-tick`** → o próprio protocolo do BUS apaga o job no primeiro wake do especialista.
- ❌ **`nohup ... &` dentro do background** → o wrapper sai em ~1s, o harness dá a tarefa por concluída e o loop fica **órfão**: nunca notifica. Rode o `for` em foreground dentro da tarefa. Voltou em segundos? Está órfão.
- ❌ **Monitorar UMA issue** (`gh issue view <n>`) → issue nova nasce sem ninguém ver. Monitore o **repo**.
- ❌ **Reusar monitor que já disparou** → ele fez `exit 0`; nada está vigiando.
- ❌ **Rearmar sem reconciliar** → perde o que chegou durante o processamento.
- ❌ **Comparar snapshot sem validar o formato** → resposta de erro da API vira "mudou" e dispara handoff **sem evento**.
- ❌ **Tratar `MONITOR_CEGO`/`MONITOR_NAO_ARMOU` como novidade** → o alarme falso gasta a atenção de quem devia estar codando; a regra "todo evento = handoff" **não** tem inverso.
- ❌ **Registrar o carteiro externo no BUS** → ele passa a receber handoff que ninguém lê.
- ❌ **Handoff sem `-Project`** (ou com `default`) → entra na fila errada e some.
- ❌ **"Está público no GitHub, eles veem."** Não veem.
