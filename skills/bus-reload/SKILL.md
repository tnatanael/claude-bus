---
name: bus-reload
description: Re-arma SÓ o cron de auto-recheck do BUS desta sessão — NÃO processa o inbox, NÃO mexe no lock. Invoque com /bus-reload. Use após reabrir o app / restart, quando o cron de sessão morreu (some do painel "Tarefas em segundo plano" e o dashboard mostra o especialista offline). Lê a identidade já registrada; não precisa de argumentos.
---

# /bus-reload — re-armar o cron do BUS (sem processar)

**Só re-arma o cron de auto-recheck** desta sessão. **NÃO** lê/processa o inbox e **NÃO** toca o lock. Útil após reabrir o app: o cron é de sessão (em memória) e morre no restart — este comando o traz de volta rápido, sem disparar processamento.

`$ROOT` = `${CLAUDE_PLUGIN_ROOT}`. **`PS`** = `powershell -NoProfile -ExecutionPolicy Bypass -File`.

## Passos
1. **Resolva a identidade** (SEM argumentos — usa o que esta sessão já registrou):
   - Windows: `PS "$ROOT\bin\bus-name.ps1"`
   - macOS/Linux: `bash "$ROOT/bin/bus-name.sh"`
   - Retornou `PROJECT=/SLUG=/BUS_CRON_MINUTE=` → siga pro passo 2. Retornou `NONE` → esta sessão **nunca se registrou**; rode **`/bus <slug> [projeto]`** primeiro (sem identidade não dá pra re-armar) e pare.

2. **Re-arme o cron DO ZERO.** `CronList`/`CronCreate`/`CronDelete` são **deferidas**: rode `ToolSearch select:CronList,CronCreate,CronDelete` ANTES.
   - **DESARMAR:** `CronList` → `CronDelete` em **CADA** job com prompt começando em `/bus` (limpa phantom/duplicado — pós-restart o `CronList` pode listar um cron morto que **não dispara**; re-arme sempre do zero).
   - **ARMAR:** `CronCreate(cron: "*/5 * * * *", prompt: "/bus", recurring: true)` — **UM** cron, a cada 5 min, prompt **bare `/bus`** (SEM slug/projeto). ⚠️ Só `*/N` ou valor único disparam — vírgula/`M/30` o harness aceita mas **NÃO dispara**.

3. **NÃO** processe o inbox e **NÃO** libere lock. Reporte **"cron re-armado — slug=X, projeto=Y"**. O auto-recheck (bare `/bus` a cada 5 min) volta a rodar e o dashboard mostra o especialista armado.
