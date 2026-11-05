const { describe, it, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { greeting } = require('../src/lib');
const { createServer } = require('../src/server');

describe('greeting()', () => {
  it('defaults to world when no name is given', () => {
    assert.equal(greeting(undefined).message, 'Hello, world!');
  });
  it('treats null, empty and whitespace-only names as world', () => {
    for (const v of [null, '', '   ']) assert.equal(greeting(v).message, 'Hello, world!');
  });
  it('trims the name', () => {
    assert.equal(greeting('  Josephine ').message, 'Hello, Josephine!');
  });
  it('accepts exactly 30 characters and rejects 31', () => {
    assert.equal(greeting('x'.repeat(30)).ok, true);
    assert.equal(greeting('x'.repeat(31)).ok, false);
  });
  it('accepts letters from other alphabets, digits, space, underscore and hyphen', () => {
    for (const v of ['José', 'Zoë Ndayisaba', 'Ana_2-b']) assert.equal(greeting(v).ok, true, v);
  });
  it('rejects markup and other special characters', () => {
    for (const v of ['<script>', 'a;b', "o'brien", 'x/y', '{x}']) assert.equal(greeting(v).ok, false, v);
  });
  it('rejects malformed input: embedded newline, object, array', () => {
    for (const v of ['Ana\nBob', {}, ['a', 'b']]) assert.equal(greeting(v).ok, false, JSON.stringify(v));
  });
});

describe('HTTP server', () => {
  let server, base;
  before(async () => {
    server = createServer();
    await new Promise((r) => server.listen(0, r));
    base = `http://127.0.0.1:${server.address().port}`;
  });
  after(() => { server.closeAllConnections(); server.close(); });

  it('GET /health returns 200 and status ok', async () => {
    const r = await fetch(`${base}/health`);
    assert.equal(r.status, 200);
    assert.deepEqual(await r.json(), { status: 'ok' });
  });

  it('GET /version reports the build metadata injected through the environment', async () => {
    const saved = { b: process.env.BUILD_NUMBER, c: process.env.GIT_SHA };
    process.env.BUILD_NUMBER = '42'; process.env.GIT_SHA = 'abc1234';
    try {
      const v = await (await fetch(`${base}/version`)).json();
      assert.equal(v.app, 'cicd-demo');
      assert.equal(v.build, '42');
      assert.equal(v.commit, 'abc1234');
    } finally {
      for (const [k, x] of [['BUILD_NUMBER', saved.b], ['GIT_SHA', saved.c]]) {
        if (x === undefined) delete process.env[k]; else process.env[k] = x;
      }
    }
  });

  it('GET /version falls back to dev/unknown when no metadata is injected', async () => {
    const saved = { b: process.env.BUILD_NUMBER, c: process.env.GIT_SHA };
    delete process.env.BUILD_NUMBER; delete process.env.GIT_SHA;
    try {
      const v = await (await fetch(`${base}/version`)).json();
      assert.equal(v.build, 'dev');
      assert.equal(v.commit, 'unknown');
    } finally {
      if (saved.b !== undefined) process.env.BUILD_NUMBER = saved.b;
      if (saved.c !== undefined) process.env.GIT_SHA = saved.c;
    }
  });

  it('GET /api/greet returns 200 with a greeting', async () => {
    const r = await fetch(`${base}/api/greet?name=Ana`);
    assert.equal(r.status, 200);
    assert.equal((await r.json()).message, 'Hello, Ana!');
  });

  it('GET /api/greet without a name greets the world', async () => {
    const r = await fetch(`${base}/api/greet`);
    assert.equal(r.status, 200);
    assert.equal((await r.json()).message, 'Hello, world!');
  });

  it('GET /api/greet returns 400 with an error for invalid names', async () => {
    for (const q of ['name=%3Cb%3E', `name=${'x'.repeat(31)}`]) {
      const r = await fetch(`${base}/api/greet?${q}`);
      assert.equal(r.status, 400, q);
      const body = await r.json();
      assert.equal(body.ok, false);
      assert.ok(body.error);
    }
  });

  it('survives malformed requests and keeps serving', async () => {
    const r1 = await fetch(`${base}/api/greet?name=%E0%A4%A`);   // broken percent-encoding
    assert.equal(r1.status, 400);
    const r2 = await fetch(`${base}//no/such/path`);
    assert.equal(r2.status, 404);
    assert.equal((await fetch(`${base}/health`)).status, 200);
  });

  it('returns 404 with a JSON error for unknown routes', async () => {
    const r = await fetch(`${base}/nope`);
    assert.equal(r.status, 404);
    assert.deepEqual(await r.json(), { error: 'not found' });
  });
});
