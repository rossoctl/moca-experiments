// E18 driver: plays a user, injects a crash, times the recovery. See experiments/e18-crash-recovery/SPEC.md.
// Every time is measured from killedAt, the instant the kill returned.
import { appendFileSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { pathToFileURL } from 'node:url';
import { turn, retryUntilOk } from './lib/client.mjs';
import { userRetryTime, percentile } from './lib/stats.mjs';
import * as injector from './lib/injector.mjs';

export const CASES = ['W-I', 'W-M', 'S-I', 'S-M'];
const FACTS = ['APPLE', 'BANANA'];
const PROMPT = 'Reply only with OK.';
const EXPECT = /OK/;
const MAX_REDOS = 3;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** Default injector bound to a real compose project. */
export function composeInjector(ctx = injector.makeCtx()) {
  const stubUrl = `http://127.0.0.1:${process.env.E18_STUB_PORT ?? 18099}/__config`;
  return {
    waitSteady: () => injector.waitSteady(ctx),
    killWorker: (o) => injector.killWorker(ctx, o),
    killSupervisor: () => injector.killSupervisor(ctx),
    restartSupervisor: () => injector.restartSupervisor(ctx),
    restarts: async () => (await injector.readMetrics(ctx)).counters.restarts,
    workerCount: async () => (await injector.readMetrics(ctx)).workers.length,
    configureStub: (delayMs) => fetch(stubUrl, { method: 'POST', body: JSON.stringify({ delayMs }) }),
  };
}

/** Reads the session's stored history from Redis; the stub cannot recall facts, so the model's answer is not used. */
export function redisHistory(ctx = injector.makeCtx()) {
  return async (sid) => (await ctx.run(['exec', '-T', 'redis', 'valkey-cli', 'XRANGE', `session:${sid}`, '-', '+'])).stdout;
}

/**
 * One recorded run. Redoes itself (up to MAX_REDOS) when setup fails or a mid-turn kill landed late or found no
 * busy worker; returns { discarded: true } when the redos run out, so one bad run never kills the whole sweep.
 * midDelayMs: the stub delay for -M cases, long enough that the kill lands inside the turn.
 */
export async function runOne({ case: kase, run, baseUrl, inj, readHistory, delayMs = 200, midDelayMs = 2000, intervalMs = 200, settleMs = 0 }) {
  const midTurn = kase.endsWith('-M');
  const worker = kase.startsWith('W');
  let reason = 'none';
  for (let attempt = 0; attempt <= MAX_REDOS; attempt++) {
    await inj.waitSteady();
    if (settleMs) await sleep(settleMs); // the pool's restart backoff only resets after a worker ran 10 s
    await inj.configureStub?.(midTurn ? midDelayMs : delayMs);
    const restartsBefore = await inj.restarts();
    const workers = (await inj.workerCount?.()) ?? null;

    const setup = [
      await turn(baseUrl, `Fact 1 is ${FACTS[0]}. ${PROMPT}`, undefined, { expect: EXPECT }),
    ];
    const sid = setup[0].sessionId;
    if (setup[0].ok) setup.push(await turn(baseUrl, `Fact 2 is ${FACTS[1]}. ${PROMPT}`, sid, { expect: EXPECT }));
    const base = [];
    for (let i = 0; setup.every((r) => r.ok) && i < 3; i++) base.push(await turn(baseUrl, PROMPT, sid, { expect: EXPECT }));
    if (!setup.every((r) => r.ok) || !base.every((r) => r.ok) || !sid) { reason = 'setup turn failed'; continue; }
    const tBase = percentile(base.map((r) => r.ms), 50);

    let killedAt;
    let inflightStart = null;
    let inflight = null;
    let fraction = null;
    try {
      if (midTurn) {
        fraction = 0.1 + Math.random() * 0.8;
        inflightStart = performance.now();
        inflight = turn(baseUrl, PROMPT, sid, { expect: EXPECT });
        await sleep(fraction * tBase); // tBase already includes the stub delay
      }
      ({ killedAt } = worker ? await inj.killWorker({ busy: midTurn }) : await inj.killSupervisor());
    } catch (e) {
      if (inflight) await inflight;
      if (e instanceof injector.NoBusyWorker) { reason = 'no busy worker'; continue; }
      throw e;
    }
    const inflightResult = inflight ? await inflight : null;
    if (midTurn && inflightResult.ok) { reason = 'kill landed after the reply'; continue; }

    let restartCmdMs = null;
    if (!worker) ({ restartCmdMs } = await inj.restartSupervisor());
    const r = await retryUntilOk(baseUrl, PROMPT, sid, { intervalMs, t0: killedAt, expect: EXPECT });
    // The in-flight turn's failure is the first thing a mid-turn user sees.
    const tErr = midTurn ? Math.max(0, inflightResult.endedAt - killedAt) : r.firstErrorMs;
    const tRecover = r.recoverMs;
    const hist = await readHistory(sid);
    return {
      case: kase,
      run,
      tBase,
      tErr,
      tRecover,
      tRecoverUser: userRetryTime(tErr, tRecover),
      censored: r.censored,
      contextOk: FACTS.every((f) => hist.includes(f)),
      sameSession: r.sameSession,
      resendNeeded: midTurn,
      fraction,
      landing: midTurn ? (killedAt - inflightStart) / tBase : null,
      restartCmdMs,
      workers,
      restartsBefore,
      restartsAfter: await inj.restarts().catch(() => null),
    };
  }
  return { case: kase, run, discarded: true, reason };
}

/** Waits for the stack to serve turns (the sandbox attaches through the relay after the supervisor is ready), then runs 5 good turns in a row. */
export async function warmUp(baseUrl, { capMs = 120000, intervalMs = 1000 } = {}) {
  const t0 = performance.now();
  let good = 0;
  while (good < 5) {
    const w = await turn(baseUrl, PROMPT, undefined, { expect: EXPECT });
    if (w.ok) { good += 1; continue; }
    good = 0;
    if (performance.now() - t0 > capMs) throw new Error(`warm-up never succeeded (${w.status ?? ''} ${w.error ?? ''}): the stub or the stack is not working`);
    await sleep(intervalMs);
  }
}

async function main() {
  const arg = (n, d) => { const i = process.argv.indexOf(`--${n}`); return i > 0 ? process.argv[i + 1] : d; };
  const runs = Number(arg('runs', 10));
  const out = arg('out', 'results/runs.jsonl');
  const cases = arg('cases', CASES.join(',')).split(',');
  const baseUrl = arg('url', 'http://127.0.0.1:8080');
  const delayMs = Number(process.env.STUB_DELAY_MS ?? 200);
  mkdirSync(dirname(out), { recursive: true });
  const ctx = injector.makeCtx();
  const inj = composeInjector(ctx);
  const readHistory = redisHistory(ctx);
  await inj.waitSteady();
  await warmUp(baseUrl);
  for (const kase of cases) {
    for (let run = 1; run <= runs; run++) {
      const rec = await runOne({ case: kase, run, baseUrl, inj, readHistory, delayMs, settleMs: kase.startsWith('W') ? 11000 : 0 });
      appendFileSync(out, JSON.stringify(rec) + '\n');
      console.log(rec.discarded ? `${kase} #${run}: DISCARDED (${rec.reason})` : `${kase} #${run}: recover ${Math.round(rec.tRecover)} ms${rec.censored ? ' CENSORED' : ''} ctx=${rec.contextOk}`);
    }
  }
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) main();
