import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildReport } from '../report.mjs';

const run = (c, r, tRecover, extra = {}) => ({ case: c, run: r, tRecover, tRecoverUser: tRecover + 2000, censored: false, contextOk: true, fraction: null, ...extra });

test('per-case table shows n, the censored count and the share of the real median', () => {
  const md = buildReport(
    [run('W-I', 1, 400), run('W-I', 2, 600), run('W-I', 3, 0, { censored: true })],
    { medianMs: 4000, p95Ms: 6000 },
  );
  assert.match(md, /W-I/);
  assert.match(md, /\| W-I \| 3 \| 1 \|/);
  assert.match(md, /\d+\.\d%/);
});

test('mid-turn cases carry the computed-not-measured row', () => {
  const md = buildReport([run('W-M', 1, 500, { fraction: 0.5 })], { medianMs: 4000, p95Ms: 6000 });
  assert.match(md, /computed, not measured/);
});

test('idle cases do not carry the computed row', () => {
  const md = buildReport([run('S-I', 1, 5000)], { medianMs: 4000, p95Ms: 6000 });
  assert.doesNotMatch(md, /computed, not measured/);
});

test('table reports t_err, resend count, restart-command time, workers, and discarded runs', () => {
  const md = buildReport(
    [
      run('S-M', 1, 5000, { tErr: 300, resendNeeded: true, restartCmdMs: 1200, workers: 4, fraction: 0.4, landing: 0.4 }),
      { case: 'S-M', run: 2, discarded: true, reason: 'kill landed after the reply' },
    ],
    { medianMs: 4000, p95Ms: 6000 },
  );
  assert.match(md, /t_err/);
  assert.match(md, /resend/);
  assert.match(md, /restart cmd/);
  assert.match(md, /discarded/i);
  assert.match(md, /SH_WORKERS/);
});

test('discarded runs are excluded from the statistics', () => {
  const md = buildReport([run('W-I', 1, 400), { case: 'W-I', run: 2, discarded: true, reason: 'x' }], { medianMs: 4000, p95Ms: 6000 });
  assert.match(md, /\| W-I \| 1 \| 0 \|/);
});

test('worst case for a mid-turn user uses a kill just before the reply (f = 1)', () => {
  const md = buildReport([run('W-M', 1, 500, { fraction: 0.5, landing: 0.5 })], { medianMs: 4000, p95Ms: 6000 });
  // typical 0.5*4 + 0.5 + 4 = 6.50 ; worst 1.0*4 + 0.5 + 4 = 8.50
  assert.match(md, /6\.50/);
  assert.match(md, /8\.50/);
});

test('mid-turn computed wait uses the recovery overhead, not tRecover (which already holds one stub turn)', () => {
  // tBase 2000, tRecover 2000 (a resend costs one normal turn => overhead 0); landing 0.5; real T = 4000
  // wait = 0.5*4000 + overhead 0 + 4000 = 6000 ms
  const md = buildReport([run('W-M', 1, 2000, { tBase: 2000, landing: 0.5, fraction: 0.5 })], { medianMs: 4000, p95Ms: 6000 });
  assert.match(md, /\| W-M \| 6\.00 \| 8\.00 \|/);
});
