const CENSOR_MS = 120000;

export function percentile(values, p) {
  const v = [...values].sort((a, b) => a - b);
  if (v.length === 0) return NaN;
  const idx = (p / 100) * (v.length - 1);
  const lo = Math.floor(idx);
  const hi = Math.ceil(idx);
  return v[lo] + (v[hi] - v[lo]) * (idx - lo);
}

export function summarize(runs) {
  const t = runs.map((r) => (r.censored ? CENSOR_MS : r.tRecover));
  return {
    n: runs.length,
    censored: runs.filter((r) => r.censored).length,
    median: percentile(t, 50),
    p95: percentile(t, 95),
    max: Math.max(...t),
  };
}

export function userRetryTime(tErr, tRecover, tickMs = 3000) {
  if (tErr == null) return tRecover;
  const ticks = Math.max(1, Math.ceil((tRecover - tErr) / tickMs));
  return tErr + ticks * tickMs;
}

export function realModelMix(overheadMs, medianRealMs) {
  return { seconds: overheadMs / 1000, share: overheadMs / medianRealMs };
}

export function midTurnWait(elapsedAtKillMs, tRecoverMs, medianRealMs) {
  return elapsedAtKillMs + tRecoverMs + medianRealMs;
}
