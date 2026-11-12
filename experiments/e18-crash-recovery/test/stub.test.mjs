import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createStub } from '../lib/stub.mjs';

function listen(server) {
  return new Promise((res) => server.listen(0, '127.0.0.1', () => res(server.address().port)));
}

test('non-streaming POST replies OK after the delay', async () => {
  const s = createStub({ delayMs: 50 });
  const port = await listen(s);
  const t0 = performance.now();
  const r = await fetch(`http://127.0.0.1:${port}/v1/messages`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ model: 'x', max_tokens: 8, messages: [{ role: 'user', content: 'hi' }] }),
  });
  const j = await r.json();
  s.close();
  assert.ok(performance.now() - t0 >= 50);
  assert.equal(j.content[0].text, 'OK');
  assert.equal(j.stop_reason, 'end_turn');
});

test('streaming POST ends with message_stop', async () => {
  const s = createStub({ delayMs: 10 });
  const port = await listen(s);
  const r = await fetch(`http://127.0.0.1:${port}/v1/messages`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ model: 'x', max_tokens: 8, stream: true, messages: [{ role: 'user', content: 'hi' }] }),
  });
  const body = await r.text();
  s.close();
  const events = [...body.matchAll(/^event: (.+)$/gm)].map((m) => m[1]);
  assert.equal(events[0], 'message_start');
  assert.equal(events.at(-1), 'message_stop');
});

test('healthz answers 200', async () => {
  const s = createStub({});
  const port = await listen(s);
  const r = await fetch(`http://127.0.0.1:${port}/healthz`);
  s.close();
  assert.equal(r.status, 200);
});

test('POST /__config changes the reply delay at runtime', async () => {
  const s = createStub({ delayMs: 0 });
  const port = await listen(s);
  await fetch(`http://127.0.0.1:${port}/__config`, { method: 'POST', body: JSON.stringify({ delayMs: 120 }) });
  const t0 = performance.now();
  await fetch(`http://127.0.0.1:${port}/v1/messages`, { method: 'POST', body: JSON.stringify({ model: 'x', messages: [] }) });
  s.close();
  assert.ok(performance.now() - t0 >= 120);
});
