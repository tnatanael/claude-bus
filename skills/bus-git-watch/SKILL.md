---
name: bus-git-watch
description: Vigia as issues de um repositório GitHub e converte CADA evento (issue nova, comentário, fechamento) em handoff do BUS para o especialista dono do assunto. Arma um monitor de fundo que só acorda a sessão quando algo muda. Invoque com /bus-git-watch [owner/repo]. Complementa o /bus: o BUS move o trabalho, o GitHub guarda o histórico e o backlog.
---

# /bus-git-watch — issues do GitHub → handoffs do BUS

Você é o **carteiro entre o GitHub e o BUS**, na sessão de um especialista já registrado (tipicamente o **controlador/PO**). O ciclo é sempre o mesmo:

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

## 2. Repositório e conta

Repo: use o `owner/repo` do comando; senão descubra com `git -C <dir> remote -v`.

```
gh auth status
```
⚠️ Com mais de uma conta logada, a errada devolve `Could not resolve to a Repository` em repo privado — parece "não existe" e é só falta de acesso.

> 🚨 **`gh auth switch` é estado GLOBAL da máquina** (um `hosts.yml`, uma chave `user:`): troca para **todas** as sessões e apps. Se precisar trocar, **volte para a conta de repouso ao terminar** e confirme com `gh auth status`.

## 3. Prove que o snapshot enxerga (não pule)

Monitor que não vê fica **silencioso igual a monitor sem novidade**. Antes de armar:

```bash
R=<owner/repo>
gh issue list --repo $R --state all --limit 100 --json number,state -q '.[] | "\(.number):\(.state)"' | sort
gh api repos/$R/issues/comments --paginate -q '.[].id' 2>/dev/null | sort -n | tail -1
```
A lista tem que bater com a realidade, e o maior id precisa conter um comentário que você **sabe** que existe (`... | grep -c <id-conhecido>` → `1`). Repo sem comentário nenhum devolve vazio — é esperado.

## 4. Armar

⚠️ **Pare o monitor anterior antes** (`TaskStop <task_id>`): dois monitores do mesmo repo acordam você em duplicidade.
⚠️ **Publique seus comentários ANTES de capturar o baseline** — senão o monitor dispara com o eco da sua própria ação.

Rode com `run_in_background: true`:

🔴 **"Não consegui ler" é um TERCEIRO estado — nunca o compare.** Quando a API falha, ela devolve um **corpo de erro**: não-vazio e diferente do baseline. Comparar string crua faz isso virar `MUDOU_NO_GITHUB` e disparar handoff **sem evento nenhum** — aconteceu duas vezes em produção (conta do `gh` trocada por outra sessão; 404 transitório). Por isso o `snap()` **valida o próprio formato** e falha com `return 1`, e o laço conta leituras cegas em vez de comparar lixo.

```bash
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

1. **Mande o handoff** (*enviar* do `/bus`, com `-Project <PROJECT>` e `-From <SLUG>`) pro especialista dono do assunto.
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

1. documento de regras na raiz do repo (`GATE.md`, `CONTRIBUTING.md`, equivalente);
2. `docs/conventions.md` + os hooks em `.githooks/`;
3. **não achou nenhum? PERGUNTE ao operador antes de despachar** — não invente regra de qualidade.

Achou? Então **em CADA handoff** inclua: *"siga as regras do `<arquivo>` deste projeto"*. Se você mantém mais de um repo/projeto, **guarde o caminho no estado** (passo 6) pra não reprocurar nem errar depois.

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

- ❌ **`nohup ... &` dentro do background** → o wrapper sai em ~1s, o harness dá a tarefa por concluída e o loop fica **órfão**: nunca notifica. Rode o `for` em foreground dentro da tarefa. Voltou em segundos? Está órfão.
- ❌ **Monitorar UMA issue** (`gh issue view <n>`) → issue nova nasce sem ninguém ver. Monitore o **repo**.
- ❌ **Reusar monitor que já disparou** → ele fez `exit 0`; nada está vigiando.
- ❌ **Rearmar sem reconciliar** → perde o que chegou durante o processamento.
- ❌ **Comparar snapshot sem validar o formato** → resposta de erro da API vira "mudou" e dispara handoff **sem evento**.
- ❌ **Tratar `MONITOR_CEGO`/`MONITOR_NAO_ARMOU` como novidade** → o alarme falso gasta a atenção de quem devia estar codando; a regra "todo evento = handoff" **não** tem inverso.
- ❌ **Registrar o carteiro externo no BUS** → ele passa a receber handoff que ninguém lê.
- ❌ **Handoff sem `-Project`** (ou com `default`) → entra na fila errada e some.
- ❌ **"Está público no GitHub, eles veem."** Não veem.
