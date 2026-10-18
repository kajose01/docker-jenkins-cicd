const test = require('node:test');
const assert = require('node:assert/strict');
const { greeting } = require('../src/lib');
const { createServer } = require('../src/server');

test('greeting defaults to world', () => {
  assert.equal(greeting(undefined).message, 'Hello, world!');
});
test('greeting trims the name', () => {
  assert.equal(greeting('  Josephine ').message, 'Hello, Josephine!');
});
test('greeting rejects a name that is too long', () => {
  assert.equal(greeting('x'.repeat(31)).ok, false);
});
test('greeting rejects markup', () => {
  assert.equal(greeting('<script>').ok, false);
});

test('server endpoints work end to end', async (t) => {
  const server = createServer();
  await new Promise((r) => server.listen(0, r));
  t.after(() => { server.closeAllConnections(); server.close(); });
  const base = `http://127.0.0.1:${server.address().port}`;

  assert.equal((await fetch(`${base}/health`)).status, 200);
  const v = await (await fetch(`${base}/version`)).json();
  assert.equal(v.app, 'cicd-demo');
  const g = await fetch(`${base}/api/greet?name=Ana`);
  assert.equal(g.status, 200);
  assert.equal((await g.json()).message, 'Hello, Ana!');
  assert.equal((await fetch(`${base}/api/greet?name=%3Cb%3E`)).status, 400);
  assert.equal((await fetch(`${base}/nope`)).status, 404);
});
