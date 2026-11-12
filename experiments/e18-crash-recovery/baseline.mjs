// E18 real-model baseline: N uncrashed turns against the real model. Run with no stub override.
import { pathToFileURL } from 'node:url';
import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { turn } from './lib/client.mjs';
import { percentile } from './lib/stats.mjs';

const PROMPT = 'Run uname -a and tell me the kernel.';

async function main() {
  const arg = (n, d) => { const i = process.argv.indexOf(`--${n}`); return i > 0 ? process.argv[i + 1] : d; };
  const n = Number(arg('n', 20));
  const url = arg('url', 'http://127.0.0.1:8080');
  const out = arg('out', 'results/baseline.json');
  const ms = [];
  let discarded = 0;
  for (let i = 0; i <= n; i++) {
    const r = await turn(url, PROMPT, undefined, { timeoutMs: 120000 });
    if (i === 0) { discarded = 1; continue; } // warm-up
    if (r.ok) ms.push(r.ms);
    else console.error(`turn ${i} failed: ${r.status ?? ''} ${r.error ?? ''}`);
  }
  const rec = { n: ms.length, discarded, medianMs: percentile(ms, 50), p95Ms: percentile(ms, 95), prompt: PROMPT, model: process.env.SH_MODEL ?? process.env.ANTHROPIC_MODEL ?? 'default' };
  mkdirSync(dirname(out), { recursive: true });
  writeFileSync(out, JSON.stringify(rec, null, 2) + '\n');
  console.log(rec);
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) main();
