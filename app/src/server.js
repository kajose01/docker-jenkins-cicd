const http = require('http');
const { greeting } = require('./lib');

function createServer() {
  return http.createServer((req, res) => {
    const u = new URL(req.url, 'http://localhost');
    const send = (code, body) => {
      res.writeHead(code, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(body));
    };
    if (u.pathname === '/health') return send(200, { status: 'ok' });
    if (u.pathname === '/version') {
      return send(200, { app: 'cicd-demo', build: process.env.BUILD_NUMBER || 'dev',
                         commit: process.env.GIT_SHA || 'unknown', host: process.env.HOSTNAME });
    }
    if (u.pathname === '/api/greet') {
      const r = greeting(u.searchParams.get('name'));
      return send(r.ok ? 200 : 400, r);
    }
    send(404, { error: 'not found' });
  });
}

if (require.main === module) {
  createServer().listen(3000, () => console.log('cicd-demo listening on 3000'));
}
module.exports = { createServer };
