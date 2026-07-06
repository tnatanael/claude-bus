---
name: bus-message
description: Enfileira uma instrução do operador para o especialista DESTA sessão sem processar nada agora — vira um handoff (operador→seu-slug) no inbox, processado no próximo /bus. Invoque com /bus-message <texto>. Normalmente o hook do BUS já trata isto SEM acordar o modelo (custo zero); esta skill é só o fallback pra quando o hook não está ativo.
---

# /bus-message — enfileira uma instrução do operador (fallback)

**Normalmente você NEM deveria estar lendo isto.** O hook do BUS (gate `UserPromptSubmit`) intercepta o `/bus-message`, escreve o handoff sozinho e bloqueia o prompt — **sem acordar o modelo, custo zero de token**. Se você chegou aqui, o hook não estava ativo: faça o fallback abaixo e **pare**.

`$ROOT` = `${CLAUDE_PLUGIN_ROOT}`. **`PS`** = `powershell -NoProfile -ExecutionPolicy Bypass -File`.

O texto após `/bus-message` é a **mensagem do operador** para o especialista **desta** sessão. Transforme-a num handoff `operador → seu-slug` no seu inbox (a ser processado no próximo `/bus`) e **não processe mais nada agora**.

## Passos
1. **Resolva sua identidade** (seu slug/projeto):
   - Windows: `PS "$ROOT\bin\bus-name.ps1"`
   - macOS/Linux: `bash "$ROOT/bin/bus-name.sh"`

   `NONE` → esta sessão nunca se registrou; peça pro operador rodar `/bus <slug> <projeto>` primeiro e pare.
2. **Escreva a mensagem** (todo o texto após `/bus-message`) num arquivo temp com a ferramenta **Write**.
3. **Enfileire** como handoff do operador para você mesmo (**sem** `--reply`/`-ReplyRequired`):
   - Windows: `PS "$ROOT\bin\bus-send.ps1" -To <seu-slug> -From operador -Project <seu-projeto> -BodyFile "<caminho>"`
   - macOS/Linux: `bash "$ROOT/bin/bus-send.sh" --to <seu-slug> --from operador --project <seu-projeto> --body-file "<caminho>"`
4. Reporte **"mensagem enfileirada — será processada no próximo /bus"** e **PARE** (não leia nem processe o inbox agora; o cron/próximo `/bus` cuida disso).
