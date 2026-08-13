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

## Cego ≠ mudou (o terceiro estado)

A primeira versão comparava as strings cruas dos dois snapshots. Parece seguro, mas quando a API do GitHub falha ela devolve um **corpo de erro**: não-vazio e diferente do baseline. O guard `[ -n "$CUR" ]` passava, a comparação dava "diferente", e o monitor gritava `MUDOU_NO_GITHUB` sem nada ter acontecido.

**Duas ocorrências reais, causas diferentes:** conta do `gh` trocada globalmente por outra sessão, e um 404 transitório da API. Mesmo sintoma — sinal de que o problema não é a causa, é o monitor **não distinguir "não consegui ler" de "mudou"**.

Isso é grave **neste desenho** porque o carteiro reage ao disparo mandando handoff: alarme falso vira ruído no BUS de um especialista. A skill ensina que *"se não houve handoff, o especialista não recebeu nada"* — o inverso também vale: **handoff sem evento gasta a atenção de quem devia estar codando**.

A correção é o `snap()` validar o próprio formato (`return 1` em vez de devolver lixo) e o laço contar **leituras cegas consecutivas**, saindo com código próprio após ~10 min e com mensagem que diz explicitamente *"ISTO NÃO É MUDANÇA"* — senão quem lê o output cai no mesmo engano que o código.

⚠️ **Limitação conhecida:** a validação exige pelo menos uma issue (`^([0-9]+:[A-Z]+ )+$`). Num repo **sem nenhuma issue** o baseline falha e o monitor sai com `MONITOR_NAO_ARMOU`. Para o uso pretendido (vigiar um projeto ativo) é aceitável, e é melhor que o alternativo — não dá para distinguir "vazio porque não há issues" de "vazio porque a chamada falhou" sem inspecionar o código de saída do `gh`. Se um dia precisar vigiar repo vazio, é aí que mexer.

## Carteiro externo: write-only por desenho

O passo 1 pressupõe que o watcher é um especialista registrado — e na maioria dos casos é (o controlador). Mas existe um arranjo legítimo que a primeira versão mandava **parar**: o carteiro **externo**, um agente que só **escreve** handoff e **não lê** inbox.

O risco não era só bloquear: uma sessão futura seguindo a skill ao pé da letra tentaria "consertar" **registrando o carteiro no BUS** — exatamente o que não se quer. Registrado, ele passa a **receber** handoff, e ninguém vai ler, porque ele não processa inbox. O `bus.externo` no estado existe para que a próxima sessão saiba que é intencional e não repita a tentativa.

## Por que "não presuma o gate do projeto"

O especialista **obedece** ao que vem no handoff — ele não confere se aquele documento é mesmo o do projeto dele. Então apontar pro arquivo errado não gera erro visível: gera trabalho feito sob a **política de outro time**, e isso só aparece na revisão (ou em produção). É por isso que a regra é *localizar antes do primeiro handoff*, e não *deduzir na hora*.

E quando não existe documento nenhum, a saída certa é **perguntar**, não improvisar: um critério de qualidade inventado pelo carteiro vira regra de fato assim que entra num handoff — o especialista não tem como saber que você a criou. Guardar o caminho no `rules_file` do estado evita reprocurar e evita errar depois, quando o watcher cuidar de mais de um repo.

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

## Conta do `gh`: isolar em vez de revezar

`gh auth switch` reescreve **um único** `hosts.yml` com **uma** chave `user:` — não é por-sessão nem por-terminal. Com várias sessões vigiando repos de donos diferentes, elas se atropelam: aconteceu **3 vezes num dia** numa máquina com ~20 especialistas.

A mitigação por etiqueta ("troque e devolva no fim") **não resolve**: entre a troca e a devolução existe uma janela em que qualquer outra sessão que rode `gh` pega a conta errada. Pior, o sintoma engana — `Could not resolve to a Repository` / 404 parece *"o repo não existe"* e manda quem depura para o lado errado. Em cima disso, se o snapshot não validar o formato, o corpo de erro 404 vira "mudou" e o monitor dispara sozinho (ver *Cego ≠ mudou*): **uma causa, dois sintomas**.

A solução é **não disputar o estado global**: `GH_CONFIG_DIR` aponta o `gh` para uma **cópia** da config, com a conta certa fixada só ali. Verificado empiricamente: com o global apontando para outra conta, o comando isolado alcançou o repo privado e o não-isolado deu 404.

**Duas condições para ser seguro:**
- **Tokens no keyring do SO** (`gh auth status` mostra `(keyring)`) — aí a cópia carrega só *qual conta usar*, não o segredo. Se a instalação guardar o token dentro do `hosts.yml`, copiar para diretório temporário/compartilhado **espalha credencial**; nesse caso use caminho privado.
- **Recriação idempotente** — a raiz do BUS vive no `%TEMP%`/`/tmp`, que o SO limpa por idade. Por isso o passo 2 recria a cópia quando o `hosts.yml` não está lá, em vez de assumir que ela sobreviveu.
