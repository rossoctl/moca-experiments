import { test } from 'node:test';
import assert from 'node:assert/strict';
import { percentile, summarize, userRetryTime, realModelMix, midTurnWait } from '../lib/stats.mjs';

test('percentile interpolates linearly', () => {
  assert.equal(percentile([1, 2, 3, 4, 5], 50), 3);
  assert.equal(percentile([1, 2, 3, 4, 5], 95), 4.8);
});

test('summarize counts a censored run as 120000 ms', () => {
  const s = summarize([
    { tRecover: 400, censored: false },
    { tRecover: 600, censored: false },
    { tRecover: 999, censored: true },
  ]);
  assert.equal(s.n, 3);
  assert.equal(s.censored, 1);
  assert.equal(s.max, 120000);
  assert.equal(s.median, 600);
});

test('userRetryTime rounds up to the next 3 s tick after the first error', () => {
  assert.equal(userRetryTime(null, 400), 400);
  assert.equal(userRetryTime(100, 400), 3100);
  assert.equal(userRetryTime(100, 3100), 3100);
});

test('realModelMix gives seconds and share of the real median', () => {
  const m = realModelMix(400, 4000);
  assert.equal(m.seconds, 0.4);
  assert.equal(m.share, 0.1);
});

test('midTurnWait sums elapsed, recovery and a full real turn', () => {
  assert.equal(midTurnWait(1000, 500, 4000), 5500);
});
