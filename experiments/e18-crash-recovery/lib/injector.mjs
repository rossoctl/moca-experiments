import { spawn } from 'node:child_process';

export class NoBusyWorker extends Error {}

const sleepReal = (ms) => new Promise((r) => setTimeout(r, ms));

/** Default runner: `docker compose` for the e18 project; E18_COMPOSE_FILES is a space-separated -f list. */
export function dockerRunner({ project = 'e18', files = process.env.E18_COMPOSE_FILES ?? '', dir = process.env.E18_PROJECT_DIR } = {}) {
  const f = files.split(/\s+/).filter(Boolean).flatMap((x) => ['-f', x]);
  const d = dir ? ['--project-directory', dir, '--env-file', `${dir}/.env`] : [];
  return (cmd) =>
    new Promise((resolve) => {
      const p = spawn('docker', ['compose', '-p', project, ...d, ...f, ...cmd]);
      let stdout = '';
      p.stdout.on('data', (d) => (stdout += d));
      p.on('close', (code) => resolve({ code, stdout }));
      p.on('error', () => resolve({ code: -1, stdout: '' }));
    });
}

export function makeCtx(run = dockerRunner()) {
  return { run, sleep: sleepReal };
}

const FETCH_METRICS = ['exec', '-T', 'supervisor', 'node', '-e',
  "fetch('http://127.0.0.1:8081/metrics').then(r=>r.text()).then(t=>process.stdout.write(t))"];

export async function readMetrics(ctx) {
  const r = await ctx.run(FETCH_METRICS);
  if (r.code !== 0) throw new Error(`metrics unavailable (exit ${r.code})`);
  return JSON.parse(r.stdout);
}

export async function waitSteady(ctx, { timeoutMs = 60000 } = {}) {
  const deadline = performance.now() + timeoutMs;
  for (;;) {
    try {
      const m = await readMetrics(ctx);
      if (m.workers.length > 0 && m.workers.every((w) => w.healthy && w.inFlight === 0)) return;
    } catch {}
    if (performance.now() > deadline) throw new Error('pool never reached steady state');
    await ctx.sleep(250);
  }
}

// One exec does find-and-kill: the metrics fetch and the SIGKILL happen inside the container, so the signal is
// not delayed by a second `docker compose exec`. killedAt is stamped after the exec returns (the signal was sent
// just before), so it undercounts by the exec's return latency, tens of ms.
const KILL_SCRIPT = (busy) => `
const m = await (await fetch('http://127.0.0.1:8081/metrics')).json();
const w = m.workers.find((x) => ${busy ? 'x.inFlight > 0' : 'x.healthy'});
if (w) process.kill(w.pid, 'SIGKILL');
process.stdout.write(JSON.stringify({ pid: w ? w.pid : null }));
`;

export async function killWorker(ctx, { busy }) {
  const r = await ctx.run(['exec', '-T', 'supervisor', 'node', '--input-type=module', '-e', KILL_SCRIPT(busy)]);
  const killedAt = performance.now();
  if (r.code !== 0) throw new Error(`kill exec failed (exit ${r.code})`);
  const { pid } = JSON.parse(r.stdout);
  if (pid == null) throw busy ? new NoBusyWorker('no worker has a turn in flight') : new Error('no healthy worker to kill');
  return { pid, killedAt };
}

export async function killSupervisor(ctx) {
  await ctx.run(['kill', 'supervisor']);
  return { killedAt: performance.now() };
}

/**
 * `docker kill` counts as a manual stop, so Docker does not apply the restart policy. This stands in for an
 * orchestrator that restarts at once: start immediately, no detection wait. restartCmdMs is the `up -d` time,
 * reported separately; it stays inside tRecover because it is the recovery work.
 */
export async function restartSupervisor(ctx, { timeoutMs = 60000 } = {}) {
  const t0 = performance.now();
  await ctx.run(['up', '-d', 'supervisor']);
  const restartCmdMs = performance.now() - t0;
  const deadline = t0 + timeoutMs;
  while (performance.now() < deadline) {
    if ((await ctx.run(['ps', '--status', 'running', '--services', 'supervisor'])).stdout.includes('supervisor')) return { restartCmdMs };
    await ctx.sleep(100);
  }
  throw new Error('supervisor never came back up');
}
