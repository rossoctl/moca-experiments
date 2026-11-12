/** One turn against the supervisor. Never throws: failures come back as ok:false. */
export async function turn(baseUrl, prompt, sessionId, { timeoutMs = 5000, expect } = {}) {
  const t0 = performance.now();
  try {
    const res = await fetch(`${baseUrl}/turn`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(sessionId ? { prompt, sessionId } : { prompt }),
      signal: AbortSignal.timeout(timeoutMs),
    });
    const text = await res.text();
    const endedAt = performance.now();
    const ms = endedAt - t0;
    if (!res.ok) return { ok: false, ms, endedAt, status: res.status, error: text.slice(0, 200) };
    let j = {};
    try {
      j = JSON.parse(text);
    } catch {
      return { ok: false, ms, endedAt, status: res.status, error: 'non-JSON body' };
    }
    // The harness answers 200 with stopReason 'error' when the model call fails; that is a failed turn.
    if (j.stopReason === 'error' || j.stopReason === 'aborted') return { ok: false, ms, endedAt, status: res.status, error: `stopReason ${j.stopReason}` };
    if (expect && !expect.test(String(j.response ?? ''))) return { ok: false, ms, endedAt, status: res.status, error: 'unexpected reply' };
    return { ok: true, ms, endedAt, sessionId: j.sessionId, status: res.status };
  } catch (e) {
    const endedAt = performance.now();
    return { ok: false, ms: endedAt - t0, endedAt, error: String(e?.cause?.code ?? e?.name ?? e) };
  }
}

/** Resends the same turn until one succeeds. Times are measured from t0 (default: now), i.e. the kill instant. */
export async function retryUntilOk(baseUrl, prompt, sessionId, { intervalMs = 200, capMs = 120000, timeoutMs = 5000, t0 = performance.now(), expect } = {}) {
  let firstErrorMs = null;
  let attempts = 0;
  while (performance.now() - t0 < capMs) {
    attempts += 1;
    const r = await turn(baseUrl, prompt, sessionId, { timeoutMs, expect });
    if (r.ok) return { firstErrorMs, recoverMs: performance.now() - t0, censored: false, attempts, sameSession: r.sessionId === sessionId };
    if (firstErrorMs === null) firstErrorMs = performance.now() - t0;
    await new Promise((res) => setTimeout(res, intervalMs));
  }
  return { firstErrorMs, recoverMs: capMs, censored: true, attempts, sameSession: false };
}
