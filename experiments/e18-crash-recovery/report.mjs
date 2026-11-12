// E18 report: per-case table from results/runs.jsonl and results/baseline.json.
import { pathToFileURL } from 'node:url';
import { readFileSync, writeFileSync } from 'node:fs';
import { summarize, percentile, realModelMix, midTurnWait } from './lib/stats.mjs';

const CASE_ORDER = ['W-I', 'W-M', 'S-I', 'S-M'];
const s = (ms) => (ms / 1000).toFixed(2);

export function buildReport(allRuns, baseline) {
  const discarded = allRuns.filter((r) => r.discarded);
  const runs = allRuns.filter((r) => !r.discarded);
  const T = baseline.medianMs;
  const rows = [];
  const computed = [];
  for (const c of CASE_ORDER) {
    const rs = runs.filter((r) => r.case === c);
    if (rs.length === 0) continue;
    const sm = summarize(rs);
    const overheads = rs.map((r) => (r.censored ? 120000 : r.tRecover) - (r.tBase ?? 0));
    const overhead = percentile(overheads, 50);
    const mix = realModelMix(overhead, T);
    const p95mix = realModelMix(percentile(overheads, 95), T);
    const maxmix = realModelMix(Math.max(...overheads), T);
    const errs = rs.map((r) => r.tErr).filter((x) => x != null);
    const tErr = errs.length ? s(percentile(errs, 50)) : 'none';
    const resends = rs.filter((r) => r.resendNeeded).length;
    const restartCmd = rs.map((r) => r.restartCmdMs).filter((x) => x != null);
    const rc = restartCmd.length ? s(percentile(restartCmd, 50)) : '-';
    const nDisc = discarded.filter((d) => d.case === c).length;
    const user = percentile(rs.map((r) => r.tRecoverUser ?? r.tRecover), 50);
    const ctx = rs.filter((r) => r.contextOk).length;
    rows.push(`| ${c} | ${sm.n} | ${sm.censored} | ${s(sm.median)} | ${s(sm.p95)} | ${s(sm.max)} | ${mix.seconds.toFixed(2)} s, ${(mix.share * 100).toFixed(1)}% (p95 ${p95mix.seconds.toFixed(2)} s, max ${maxmix.seconds.toFixed(2)} s) | ${tErr} | ${resends}/${sm.n} | ${rc} | ${nDisc} | ${s(user)} | ${ctx}/${sm.n} |`);
    if (c.endsWith('-M')) {
      const f = percentile(rs.map((r) => r.landing ?? r.fraction ?? 0.5), 50);
      const typical = midTurnWait(f * T, Math.max(0, overhead), T);
      const worst = midTurnWait(1.0 * T, Math.max(0, overhead), T);
      computed.push(`| ${c} | ${s(typical)} | ${s(worst)} |`);
    }
  }
  const out = [
    '# E18 results: crash recovery latency',
    '',
    `Real-model baseline: median T = ${s(T)} s, p95 = ${s(baseline.p95Ms)} s.`,
    `Pool size (SH_WORKERS) per run: ${[...new Set(runs.map((r) => r.workers).filter((x) => x != null))].join(', ') || 'unknown'}. With more than one worker, a worker kill that a sibling absorbs measures the sibling, not the restart.`,
    '',
    '| case | n | censored | recover median (s) | p95 (s) | max (s) | overhead vs T | t_err median (s) | resend | restart cmd median (s) | discarded | user-retry median (s) | context ok |',
    '| ---- | - | -------- | ------------------ | ------- | ------- | ------------- | ---------------- | ------ | ---------------------- | --------- | --------------------- | ---------- |',
    ...rows,
  ];
  if (computed.length) {
    out.push(
      '',
      'Mid-turn wait for a real-model user who must resend: `elapsed_at_kill + recovery overhead + T` (computed, not measured; the overhead is t_recover minus one normal turn, floored at 0). Typical uses the median landing point of the recorded kills; worst case is a kill just before the reply (f = 1).',
      '',
      '| case | typical (s) | worst (s) |',
      '| ---- | ----------- | --------- |',
      ...computed,
    );
  }
  return out.join('\n') + '\n';
}

function main() {
  const arg = (n) => { const i = process.argv.indexOf(`--${n}`); return i > 0 ? process.argv[i + 1] : undefined; };
  const runs = readFileSync(arg('runs') ?? 'results/runs.jsonl', 'utf8').trim().split('\n').map((l) => JSON.parse(l));
  const baseline = JSON.parse(readFileSync(arg('baseline') ?? 'results/baseline.json', 'utf8'));
  writeFileSync(arg('out') ?? 'RESULTS.md', buildReport(runs, baseline));
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) main();
