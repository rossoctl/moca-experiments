import { test } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { runOne } from '../driver.mjs';
import { NoBusyWorker } from '../lib/injector.mjs';

const ok = (r, o = {}) => r.writeHead(200, { 'content-type': 'application/json' }).end(JSON.stringify({ sessionId: 'sid-1', response: 'OK', stopReason: 'end_turn', ...o }));

// Fake supervisor. After kill(): requests fail for downMs. holdMs delays every reply (a "slow model").
function fakeWorld({ downMs = 0, holdMs = 0 } = {}) {
  let downUntil = 0;
  let epoch = 0; // a kill bumps it: requests already in flight fail, as they do when the process is SIGKILLed
  const s = http.createServer(async (q, r) => {
    const startedIn = epoch;
    if (holdMs) await new Promise((x) => setTimeout(x, holdMs));
    if (epoch !== startedIn || performance.now() < downUntil) return r.writeHead(503).end('down');
    ok(r);
  });
  return new Promise((res) =>
    s.listen(0, '127.0.0.1', () =>
      res({ s, url: `http://127.0.0.1:${s.address().port}`, kill: () => { epoch += 1; downUntil = performance.now() + downMs; return { killedAt: performance.now(), pid: 7 }; } }),
    ),
  );
}

const hist = async () => 'APPLE BANANA';
const base = (w, over = {}) => ({
  waitSteady: async () => {}, killWorker: async () => w.kill(), killSupervisor: async () => w.kill(),
  restartSupervisor: async () => ({ restartCmdMs: 5 }), restarts: async () => 0, configureStub: async () => {}, ...over,
});

test('W-I: tRecover and tErr are both measured from the kill', async () => {
  const w = await fakeWorld({ downMs: 500 });
  const rec = await runOne({ case: 'W-I', run: 1, baseUrl: w.url, inj: base(w), readHistory: hist, delayMs: 0, intervalMs: 50 });
  w.s.close();
  assert.equal(rec.censored, false);
  assert.ok(rec.tRecover >= 450 && rec.tRecover < 2000, `tRecover ${rec.tRecover}`);
  assert.ok(rec.tErr !== null && rec.tErr < 200, `tErr ${rec.tErr}`);
  assert.equal(rec.contextOk, true);
  assert.equal(rec.sameSession, true);
  assert.ok(rec.tRecoverUser >= rec.tRecover);
});

test('S-I: tErr is measured from the kill, not from the end of the restart', async () => {
  const w = await fakeWorld({ downMs: 600 });
  const inj = base(w, { restartSupervisor: async () => { await new Promise((r) => setTimeout(r, 300)); return { restartCmdMs: 300 }; } });
  const rec = await runOne({ case: 'S-I', run: 1, baseUrl: w.url, inj, readHistory: hist, delayMs: 0, intervalMs: 50 });
  w.s.close();
  assert.ok(rec.tErr >= 300, `tErr ${rec.tErr} must include the restart time`);
  assert.ok(rec.tRecover >= 550, `tRecover ${rec.tRecover}`);
  assert.equal(rec.restartCmdMs, 300);
});

test('a setup turn that fails redoes the run instead of recording a fresh-session recovery', async () => {
  let n = 0;
  const s = http.createServer((q, r) => { n += 1; if (n === 1) return r.writeHead(503).end('x'); ok(r); });
  await new Promise((res) => s.listen(0, '127.0.0.1', res));
  const url = `http://127.0.0.1:${s.address().port}`;
  const inj = base({ kill: () => ({ killedAt: performance.now(), pid: 1 }) });
  const rec = await runOne({ case: 'W-I', run: 1, baseUrl: url, inj, readHistory: hist, delayMs: 0, intervalMs: 20 });
  s.close();
  assert.equal(rec.sameSession, true);
  assert.ok(n > 6, 'the failed setup must have been retried');
});

test('context_ok is false when the history lacks a fact', async () => {
  const w = await fakeWorld();
  const rec = await runOne({ case: 'W-I', run: 1, baseUrl: w.url, inj: base(w), readHistory: async () => 'APPLE only', delayMs: 0, intervalMs: 50 });
  w.s.close();
  assert.equal(rec.contextOk, false);
});

test('W-M: a kill that finds no busy worker is redone, not recorded', async () => {
  const w = await fakeWorld({ downMs: 100, holdMs: 300 });
  let calls = 0;
  const inj = base(w, { killWorker: async () => { calls += 1; if (calls === 1) throw new NoBusyWorker('idle'); return w.kill(); } });
  const rec = await runOne({ case: 'W-M', run: 1, baseUrl: w.url, inj, readHistory: hist, delayMs: 0, intervalMs: 50 });
  w.s.close();
  assert.equal(calls, 2);
  assert.equal(rec.case, 'W-M');
});

test('W-M: a kill that lands after the reply (in-flight turn succeeded) is discarded, never recorded', async () => {
  const w = await fakeWorld({ downMs: 0, holdMs: 20 }); // turn always completes before the kill
  let kills = 0;
  const inj = base(w, { killWorker: async () => { kills += 1; await new Promise((r) => setTimeout(r, 100)); return w.kill(); } });
  const rec = await runOne({ case: 'W-M', run: 1, baseUrl: w.url, inj, readHistory: hist, delayMs: 0, intervalMs: 50 });
  w.s.close();
  assert.equal(rec.discarded, true);
  assert.ok(kills >= 2, `expected redos, got ${kills}`);
});

test('W-M: a kill that lands mid-turn is recorded with where it landed and tErr from the in-flight failure', async () => {
  const w = await fakeWorld({ downMs: 400, holdMs: 300 });
  const rec = await runOne({ case: 'W-M', run: 1, baseUrl: w.url, inj: base(w), readHistory: hist, delayMs: 0, intervalMs: 50 });
  w.s.close();
  assert.equal(rec.discarded, undefined);
  assert.ok(rec.landing > 0 && rec.landing < 1, `landing ${rec.landing}`);
  assert.equal(rec.resendNeeded, true);
  assert.ok(rec.tErr >= 0 && rec.tErr < 400, `tErr ${rec.tErr}`);
});

test('exhausting the redos returns a discarded record instead of throwing', async () => {
  const w = await fakeWorld({ holdMs: 20 });
  const inj = base(w, { killWorker: async () => { throw new NoBusyWorker('idle'); } });
  const rec = await runOne({ case: 'W-M', run: 1, baseUrl: w.url, inj, readHistory: hist, delayMs: 0, intervalMs: 50 });
  w.s.close();
  assert.equal(rec.discarded, true);
});

test('warmUp retries a 503 until the sandbox attaches, then needs 5 good turns', async () => {
  let n = 0;
  const s = http.createServer((q, r) => { n += 1; if (n <= 3) return r.writeHead(503).end('{"error":"sandbox_unavailable"}'); ok(r); });
  await new Promise((res) => s.listen(0, '127.0.0.1', res));
  try {
    const { warmUp } = await import('../driver.mjs');
    await warmUp(`http://127.0.0.1:${s.address().port}`, { capMs: 5000, intervalMs: 20 });
    assert.equal(n, 8);
  } finally {
    s.closeAllConnections();
    s.close();
  }
});

test('warmUp gives up with a clear error when the stack never works', async () => {
  const s = http.createServer((q, r) => r.writeHead(503).end('{"error":"sandbox_unavailable"}'));
  await new Promise((res) => s.listen(0, '127.0.0.1', res));
  try {
    const { warmUp } = await import('../driver.mjs');
    await assert.rejects(warmUp(`http://127.0.0.1:${s.address().port}`, { capMs: 200, intervalMs: 20 }), /sandbox_unavailable/);
  } finally {
    s.closeAllConnections();
    s.close();
  }
});
