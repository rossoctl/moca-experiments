import http from 'node:http';
import { pathToFileURL } from 'node:url';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function sse(res, event, data) {
  res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
}

export function createStub({ delayMs: initialDelayMs = 200, reply = 'OK' } = {}) {
  let delayMs = initialDelayMs;
  return http.createServer(async (req, res) => {
    if (req.method === 'GET' && req.url === '/healthz') {
      res.writeHead(200).end('ok');
      return;
    }
    if (req.method === 'POST' && req.url === '/__config') {
      let raw = '';
      for await (const chunk of req) raw += chunk;
      const c = JSON.parse(raw || '{}');
      if (typeof c.delayMs === 'number') delayMs = c.delayMs;
      res.writeHead(200).end('ok');
      return;
    }
    if (req.method !== 'POST' || !req.url.startsWith('/v1/messages')) {
      res.writeHead(404).end();
      return;
    }
    let raw = '';
    for await (const chunk of req) raw += chunk;
    let body = {};
    try {
      body = JSON.parse(raw);
    } catch {}
    await sleep(delayMs);
    const model = body.model ?? 'stub';
    const usage = { input_tokens: 1, output_tokens: 1 };
    if (body.stream) {
      res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' });
      sse(res, 'message_start', {
        type: 'message_start',
        message: { id: 'msg_stub', type: 'message', role: 'assistant', model, content: [], stop_reason: null, usage },
      });
      sse(res, 'content_block_start', { type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } });
      sse(res, 'content_block_delta', { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: reply } });
      sse(res, 'content_block_stop', { type: 'content_block_stop', index: 0 });
      sse(res, 'message_delta', { type: 'message_delta', delta: { stop_reason: 'end_turn' }, usage: { output_tokens: 1 } });
      sse(res, 'message_stop', { type: 'message_stop' });
      res.end();
      return;
    }
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(
      JSON.stringify({
        id: 'msg_stub',
        type: 'message',
        role: 'assistant',
        model,
        content: [{ type: 'text', text: reply }],
        stop_reason: 'end_turn',
        usage,
      }),
    );
  });
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  const port = Number(process.env.PORT ?? 8099);
  const delayMs = Number(process.env.STUB_DELAY_MS ?? 200);
  createStub({ delayMs }).listen(port, '0.0.0.0', () => console.log(`stub listening on ${port} delay ${delayMs}ms`));
}
