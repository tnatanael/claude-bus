// pm2 (opcional) para o dashboard do BUS.
//
//   pm2 start ecosystem.config.js   # sobe
//   pm2 logs bus-dashboard          # o que ele esta falando
//   pm2 restart bus-dashboard       # restart manual
//   pm2 save                        # grava a lista pro 'pm2 resurrect' do logon
//
// O dashboard e READ-ONLY sobre a raiz do BUS: se ele cair, o BUS continua funcionando
// (os especialistas nao dependem dele). Por isso autorestart com teto -- se estiver em
// crash-loop, e melhor ficar parado e visivel no 'pm2 list' do que reiniciar pra sempre.
//
// SEM watch, de proposito. O launcher antigo rodava 'node --watch' (auto-reload ao editar o
// server.js), mas o watch DO PM2 derruba o proprio daemon no Windows -- medido no pm2 7.0.3 +
// Node 24: a app sobe "online", 3s depois o daemon some sem log de shutdown e a lista de
// processos vai junto (o sintoma visivel e o DeprecationWarning DEP0190, "child process with
// shell option true", que vem do watcher). Sem watch: online, 0 restarts, estavel.
// Editou o server.js? 'pm2 restart bus-dashboard'.
module.exports = {
  apps: [
    {
      name: 'bus-dashboard',
      script: './dashboard/server.js',
      autorestart: true,
      max_restarts: 10,
      min_uptime: '20s',
      time: true,       // timestamp nas linhas de log -- sem isso o log nao serve pra diagnostico
    },
  ],
};
