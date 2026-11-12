import { test } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { turn, retryUntilOk } from '../lib/client.mjs';
const json = (r, o) => r.writeHead(200, { 'content-type': 'application/json' }).end(JSON.stringify(o));

function serve(handler) {
  const s = http.createServer(handler);
  return new Promise((res) => s.listen(0, '127.0.0.1', () => res({ s, url: `http://127.0.0.1:${s.address().port}` })));
}

test('turn returns ok:false with the status on a 503 and does not throw', async () => {
  const { s, url } = await serve((q, r) => r.writeHead(503).end('busy'));
  const r = await turn(url, 'hi');
  s.close();
  assert.equal(r.ok, false);
  assert.equal(r.status, 503);
});

test('turn returns ok:false with an error on connection refused', async () => {
  const r = await turn('http://127.0.0.1:1', 'hi');
  assert.equal(r.ok, false);
  assert.ok(r.error);
});

test('turn returns the sessionId on success', async () => {
  const { s, url } = await serve((q, r) => r.writeHead(200, { 'content-type': 'application/json' }).end('{"sessionId":"abc","response":"OK"}'));
  const r = await turn(url, 'hi');
  s.close();
  assert.equal(r.ok, true);
  assert.equal(r.sessionId, 'abc');
});

test('retryUntilOk reports the first error and the recovery time', async () => {
  const t0 = performance.now();
  const { s, url } = await serve((q, r) => {
    if (performance.now() - t0 < 600) r.writeHead(503).end('x');
    else r.writeHead(200, { 'content-type': 'application/json' }).end('{"sessionId":"abc"}');
  });
  const r = await retryUntilOk(url, 'hi', 'abc', { intervalMs: 50, capMs: 5000 });
  s.close();
  assert.equal(r.censored, false);
  assert.ok(r.recoverMs >= 550, `recoverMs ${r.recoverMs}`);
  assert.ok(r.firstErrorMs !== null && r.firstErrorMs < 200);
});

test('retryUntilOk is censored when the server never recovers', async () => {
  const { s, url } = await serve((q, r) => r.writeHead(503).end('x'));
  const r = await retryUntilOk(url, 'hi', 'abc', { intervalMs: 50, capMs: 400 });
  s.close();
  assert.equal(r.censored, true);
});

test('turn treats HTTP 200 with stopReason error as a failed turn', async () => {
  const { s, url } = await serve((q, r) => json(r, { sessionId: 'a', response: '', stopReason: 'error' }));
  const r = await turn(url, 'hi');
  s.close();
  assert.equal(r.ok, false);
});

test('turn with expect fails when the reply does not match', async () => {
  const { s, url } = await serve((q, r) => json(r, { sessionId: 'a', response: 'nope', stopReason: 'end_turn' }));
  const bad = await turn(url, 'hi', undefined, { expect: /OK/ });
  const good = await turn(url, 'hi');
  s.close();
  assert.equal(bad.ok, false);
  assert.equal(good.ok, true);
});

test('turn reports a non-JSON 200 body as a failure', async () => {
  const { s, url } = await serve((q, r) => r.writeHead(200).end('<html>'));
  const r = await turn(url, 'hi');
  s.close();
  assert.equal(r.ok, false);
});

test('turn stamps endedAt', async () => {
  const { s, url } = await serve((q, r) => json(r, { sessionId: 'a' }));
  const r = await turn(url, 'hi');
  s.close();
  assert.ok(r.endedAt > 0);
});

test('retryUntilOk measures from t0, not from its own start', async () => {
  const { s, url } = await serve((q, r) => json(r, { sessionId: 'abc' }));
  const t0 = performance.now() - 1000;
  const r = await retryUntilOk(url, 'hi', 'abc', { intervalMs: 20, capMs: 5000, t0 });
  s.close();
  assert.ok(r.recoverMs >= 1000, `recoverMs ${r.recoverMs}`);
});

test('retryUntilOk reports whether the recovered turn was on the same session', async () => {
  const { s, url } = await serve((q, r) => json(r, { sessionId: 'other' }));
  const r = await retryUntilOk(url, 'hi', 'abc', { intervalMs: 20, capMs: 1000 });
  s.close();
  assert.equal(r.sameSession, false);
});

test('every failure path stamps endedAt (503, non-JSON 200, refused)', async () => {
  const a = await serve((q, r) => r.writeHead(503).end('x'));
  const b = await serve((q, r) => r.writeHead(200).end('<html>'));
  const r1 = await turn(a.url, 'hi');
  const r2 = await turn(b.url, 'hi');
  const r3 = await turn('http://127.0.0.1:1', 'hi');
  a.s.close();
  b.s.close();
  for (const r of [r1, r2, r3]) {
    assert.equal(r.ok, false);
    assert.ok(r.endedAt > 0, `endedAt missing on ${JSON.stringify(r)}`);
  }
});
