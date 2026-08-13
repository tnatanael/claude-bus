# /bus-git-watch — referência (não injetada)

O `SKILL.md` carrega só o que se executa. Aqui fica o **porquê**, as adaptações e as lições que custaram caro.

## Por que isso existe: o BUS é efêmero, o GitHub é durável

O BUS move trabalho muito bem, mas **não guarda memória**: vive no `%TEMP%`/`/tmp`, os handoffs viram `done/`, e o contexto da sessão morre no `/clear`, na compactação, no restart. Quem precisa saber *"o que foi decidido na semana passada e por quê"* não tem onde olhar.

O GitHub resolve exatamente isso — issues são backlog, discussão e histórico ao mesmo tempo, e ainda são o lugar onde **o operador e os usuários finais já estão**. Juntando os dois: **o BUS cuida do fluxo, o GitHub da memória.** O ponto natural de junção é o **controlador (prio 0)**, que já é o consolidador do projeto.

## Por que "carteiro", e não analista

A tentação é o watcher ler a issue, investigar e responder. Não faça: quem tem o território é o especialista. O watcher **melhora o enunciado** (explicita pedido, separa o que já é sabido, deixa clara a próxima ação) e **despacha**. Se ele analisar, vira gargalo e passa a errar em domínio alheio.

E o especialista responde **no ticket**, não de volta pelo BUS: é lá que o operador e os usuários leem. Handoff de volta só criaria um canal paralelo que ninguém acompanha.

## Fila por especialista, não global

Um ticket por vez **por especialista** evita empilhar trabalho em quem já está ocupado. Fila **global** parece mais segura e é pior: trava o time inteiro atrás do gargalo de uma frente só — com dezenas de issues abertas, gente ociosa com trabalho na mesa. Num time de uma pessoa só os dois critérios coincidem.

## Estado no projeto do BUS (mudou na absorção)

A versão original guardava o histórico no **scratchpad da sessão** — que é indexado pelo id da sessão. Como o `/clear` gera um **sid novo**, o histórico ficava órfão exatamente no fluxo mais usado na prática (`/clear` + `/bus <projeto> <slug>` para escapar da compactação).

Agora o arquivo vive em `<base>/<projeto>/.git-watch-<owner>-<repo>.json`: sobrevive ao `/clear`, ao restart e à troca de sessão, e **qualquer** sessão daquele projeto retoma de onde parou. É dotfile, então não aparece como projeto no dashboard.

## A janela cega entre disparar e rearmar

O monitor **morre ao detectar** — de propósito, é assim que ele acorda a sessão. Entre esse instante e o rearme, **ninguém está vigiando**. Se um comentário chega nesse intervalo, ele some pra sempre.

Daí a reconciliação obrigatória: comparar o `snap()` atual com o checkpoint salvo **antes** de rearmar, e processar o que apareceu. Sem isso o sistema perde eventos de forma silenciosa — o pior modo de falha, porque parece que está funcionando.

## Custo: a bolinha de "trabalhando"

O monitor é **task de fundo rastreada**, e é isso que permite acordar a sessão ao terminar. O efeito colateral é que o app mostra a sessão como **ocupada** o tempo todo (bolinha piscando).

Foi exatamente por esse motivo que o BUS **descartou** um redesenho com monitor por sessão (ver `bus/REFERENCE.md`): rastreado ⟺ parece ocupado, não dá pra ter os dois. Numa sessão só (o PO) o incômodo é aceitável; **replicar isso na frota inteira acende a bolinha em todo mundo** — decisão do operador, não default.

## Por que o monitor não infla o contexto

Diferente do tique do cron, a conclusão do monitor chega como **notificação de tarefa**, não como slash command — então **não expande skill nenhuma**. O ciclo dispara→acorda→rearma custa o output do script, não uma cópia da skill. (O `/bus` teve que abandonar o tique `/bus` justamente por isso; ver `bus/REFERENCE.md`.)

## Adaptações

- **Só uma issue** (raro): filtre por `.issue_url` terminando no número — e saiba que você deixa de ver issues novas.
- **PRs junto**: `gh api repos/$R/issues/comments` já cobre comentários de PR (no GitHub, PR é issue). Para o *estado* dos PRs, acrescente `gh pr list --json number,state` ao `snap()`.
- **Reagir a push/CI** em vez de issues: troque o `snap()` por `gh run list --repo $R --limit 1 --json databaseId,status,conclusion`.
- **Repo muito ativo**: `--limit 100` pode truncar. Suba o limite ou filtre por label/milestone no `gh issue list`.

## Conta do `gh` — cuidado que vale a máquina inteira

`gh auth switch` reescreve **um único** `hosts.yml` com **uma** chave `user:`: não é por-sessão nem por-terminal. Trocar aqui muda para todas as sessões e apps ao mesmo tempo — inclusive as que estão no meio de um push. Se precisar trocar para enxergar um repo privado, **volte para a conta de repouso ao terminar** e confirme com `gh auth status`.
