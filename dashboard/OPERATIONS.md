# Operação do dashboard — reiniciar e verificar

O dashboard é um processo **Node** somente-leitura (porta `7878`, ou `PORT`). Rode-o com
**`node --watch`** pra ele **recarregar sozinho** quando o `server.js` mudar (o `index.html`
é estático — só dar **F5**). Os comandos abaixo assumem que você está na **raiz do repositório**
(onde fica a pasta `dashboard/`).

`node --watch` roda como **supervisor + filho**: você verá um processo com `--watch …server.js`
(supervisor, que observa o arquivo) e outro `…server.js` (o filho, que escuta a porta). Editar o
`server.js` reinicia só o filho.

---

## 1. Reiniciar (mata o que está rodando + sobe com `--watch`)

**Windows (PowerShell):**
```powershell
Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
  Where-Object { $_.CommandLine -like '*dashboard*server.js*' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Start-Sleep -Milliseconds 600
Start-Process node -ArgumentList '--watch','dashboard/server.js' -WindowStyle Hidden
```

**macOS / Linux (bash):**
```bash
pkill -f 'dashboard/server.js' 2>/dev/null; sleep 1
nohup node --watch dashboard/server.js >/tmp/claude-bus-dashboard.log 2>&1 &
```

Depois, **F5** na(s) aba(s) do navegador.

---

## 2. Verificar (deve mostrar um processo com `--watch …server.js`)

**Windows (PowerShell):**
```powershell
Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
  Where-Object { $_.CommandLine -like '*dashboard*server.js*' } |
  Select-Object ProcessId, CommandLine | Format-List
```

**macOS / Linux (bash):**
```bash
pgrep -af 'dashboard/server.js'
```

---

## 3. Persistência no boot (opcional)

Pra o dashboard subir sozinho no logon/boot:

- **Windows:** um lançador `.vbs` que rode `node --watch …\dashboard\server.js` escondido
  (via `CreateObject("WScript.Shell").Run "node --watch …", 0, False`), colocado na pasta
  **Startup** (`%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup`). Não hardcode o caminho
  versionado do Node — chame `node` pelo **PATH** pra sobreviver a updates.
- **macOS:** um agente **launchd** (`~/Library/LaunchAgents/<id>.plist`) com `RunAtLoad` = `true`.
- **Linux:** um **serviço systemd de usuário** (`systemctl --user enable --now <unit>`) ou
  `cron` com `@reboot`.
