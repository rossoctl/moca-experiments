import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readMetrics, waitSteady, killWorker, killSupervisor, restartSupervisor, NoBusyWorker } from '../lib/injector.mjs';

const metrics = (workers, restarts = 0) => JSON.stringify({ workers, counters: { restarts } });

function fakeRun(handler) {
  const calls = [];
  const run = async (cmd) => {
    calls.push(cmd.join(' '));
    return handler(cmd.join(' '), calls.length);
  };
  return { ctx: { run, sleep: async () => {} }, calls };
}

test('readMetrics parses the supervisor admin body', async () => {
  const { ctx } = fakeRun(() => ({ code: 0, stdout: metrics([{ id: 0, pid: 11, inFlight: 0, healthy: true }], 2) }));
  const m = await readMetrics(ctx);
  assert.equal(m.workers[0].pid, 11);
  assert.equal(m.counters.restarts, 2);
});

test('waitSteady rejects when a worker stays unhealthy', async () => {
  const { ctx } = fakeRun(() => ({ code: 0, stdout: metrics([{ id: 0, pid: 1, inFlight: 0, healthy: false }]) }));
  await assert.rejects(waitSteady(ctx, { timeoutMs: 20 }), /steady/);
});

test('waitSteady resolves when all workers are healthy and idle', async () => {
  const { ctx } = fakeRun(() => ({ code: 0, stdout: metrics([{ id: 0, pid: 1, inFlight: 0, healthy: true }]) }));
  await waitSteady(ctx, { timeoutMs: 1000 });
});

test('killWorker finds and kills in ONE exec, and stamps killedAt after it returns', async () => {
  let returnedAt = 0;
  const { ctx, calls } = fakeRun(async () => {
    await new Promise((r) => setTimeout(r, 60));
    returnedAt = performance.now();
    return { code: 0, stdout: '{"pid":22}' };
  });
  const before = performance.now();
  const r = await killWorker(ctx, { busy: true });
  assert.equal(calls.length, 1);
  assert.equal(r.pid, 22);
  assert.ok(r.killedAt >= returnedAt - 1, 'killedAt must be taken after the exec returns');
  assert.ok(r.killedAt - before >= 60);
});

test('killWorker busy throws NoBusyWorker when no worker has a turn in flight', async () => {
  const { ctx } = fakeRun(() => ({ code: 0, stdout: '{"pid":null}' }));
  await assert.rejects(killWorker(ctx, { busy: true }), NoBusyWorker);
});

test('killWorker throws when the exec fails, so a no-op kill is never recorded', async () => {
  const { ctx } = fakeRun(() => ({ code: 1, stdout: '' }));
  await assert.rejects(killWorker(ctx, { busy: false }), /kill/);
});

test('killSupervisor issues docker kill on the supervisor service', async () => {
  const { ctx, calls } = fakeRun(() => ({ code: 0, stdout: '' }));
  await killSupervisor(ctx);
  assert.ok(calls.some((c) => /kill .*supervisor/.test(c)));
});

test('restartSupervisor starts the container at once, with no detection wait, and reports the command time', async () => {
  const { ctx, calls } = fakeRun((c) => (c.includes('ps') ? { code: 0, stdout: 'supervisor' } : { code: 0, stdout: '' }));
  const r = await restartSupervisor(ctx, { timeoutMs: 1000 });
  assert.match(calls[0], /up -d supervisor/);
  assert.equal(typeof r.restartCmdMs, 'number');
});

test('restartSupervisor rejects instead of hanging when the container never comes up', async () => {
  const { ctx } = fakeRun((c) => (c.includes('ps') ? { code: 0, stdout: '' } : { code: 0, stdout: '' }));
  await assert.rejects(restartSupervisor(ctx, { timeoutMs: 30 }), /never/);
});
