// Workers on OpenAI-compatible endpoints: Claude Code's Messages requests as chat completions and back (whole and
// streamed, with tool calls), through the worker proxy to a fake server. Model-free.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { estimateTokens, fromChatResponse, parseArgs, splitSse, StreamTranslator, toChatRequest } from '../src/openai.ts';
import { startWorkerProxy, type RequestStats, type Route } from '../src/proxy.ts';

type Obj = Record<string, unknown>;

/** Anthropic SSE as a list of its events' data. */
const events = (text: string) => splitSse(text + '\n\n').data.map((d) => JSON.parse(d) as Obj & { type: string });

test('a Messages request becomes a chat-completions request', () => {
  const req = toChatRequest({
    model: 'sonnet', max_tokens: 1024, temperature: 1, stream: true, stop_sequences: ['END'],
    system: [{ type: 'text', text: 'You are a worker.' }, { type: 'text', text: 'Be brief.', cache_control: { type: 'ephemeral' } }],
    tools: [
      { name: 'Read', description: 'Read a file', input_schema: { type: 'object', properties: { file_path: { type: 'string' } } } },
      { type: 'web_search_20250305', name: 'web_search' }, // a server tool: not offered
    ],
    tool_choice: { type: 'auto' },
    messages: [
      { role: 'user', content: 'Read a.ts' },
      { role: 'assistant', content: [{ type: 'thinking', thinking: 'hmm', signature: 'x' }, { type: 'text', text: 'Reading it.' }, { type: 'tool_use', id: 'toolu_1', name: 'Read', input: { file_path: 'a.ts' } }] },
      { role: 'user', content: [
        { type: 'tool_result', tool_use_id: 'toolu_1', content: [{ type: 'text', text: 'export const a = 1;' }] },
        { type: 'text', text: 'Now explain it.' },
      ] },
      { role: 'assistant', content: [{ type: 'tool_use', id: 'toolu_2', name: 'Read', input: { file_path: 'b.png' } }] },
      { role: 'user', content: [
        { type: 'tool_result', tool_use_id: 'toolu_2', is_error: true, content: 'no such file' },
        { type: 'image', source: { type: 'base64', media_type: 'image/png', data: 'AAAA' } },
      ] },
    ],
  }, 'qwen3-coder', 0.2);
  assert.equal(req.model, 'qwen3-coder');
  assert.equal(req.temperature, 0.2, "the worker's temperature wins");
  assert.equal(req.max_tokens, 1024);
  assert.deepEqual(req.stop, ['END']);
  assert.equal(req.stream, true);
  assert.deepEqual(req.stream_options, { include_usage: true });
  assert.equal(req.tool_choice, 'auto');
  assert.deepEqual(req.tools, [{ type: 'function', function: { name: 'Read', description: 'Read a file', parameters: { type: 'object', properties: { file_path: { type: 'string' } } } } }]);
  assert.deepEqual(req.messages, [
    { role: 'system', content: 'You are a worker.\n\nBe brief.' },
    { role: 'user', content: 'Read a.ts' },
    { role: 'assistant', content: 'Reading it.', tool_calls: [{ id: 'toolu_1', type: 'function', function: { name: 'Read', arguments: '{"file_path":"a.ts"}' } }] },
    { role: 'tool', tool_call_id: 'toolu_1', content: 'export const a = 1;' },
    { role: 'user', content: 'Now explain it.' },
    { role: 'assistant', content: null, tool_calls: [{ id: 'toolu_2', type: 'function', function: { name: 'Read', arguments: '{"file_path":"b.png"}' } }] },
    { role: 'tool', tool_call_id: 'toolu_2', content: 'Error: no such file' },
    { role: 'user', content: [{ type: 'image_url', image_url: { url: 'data:image/png;base64,AAAA' } }] },
  ]);
  assert.equal(toChatRequest({ messages: [], tools: [{ name: 'X', input_schema: {} }], tool_choice: { type: 'any' } }, 'm').tool_choice, 'required');
  assert.deepEqual(toChatRequest({ messages: [], tools: [{ name: 'X', input_schema: {} }], tool_choice: { type: 'tool', name: 'X' } }, 'm').tool_choice, { type: 'function', function: { name: 'X' } });
  assert.equal('tools' in toChatRequest({ messages: [] }, 'm'), false);
});

test('a whole chat completion becomes a Messages response', () => {
  const msg = fromChatResponse({
    choices: [{ finish_reason: 'tool_calls', message: { role: 'assistant', content: 'Let me look.', tool_calls: [{ id: 'call_1', type: 'function', function: { name: 'Grep', arguments: '{"pattern":"TODO"}' } }] } }],
    usage: { prompt_tokens: 120, completion_tokens: 14 },
  }, 'qwen3-coder');
  assert.equal(msg.type, 'message');
  assert.equal(msg.model, 'qwen3-coder');
  assert.equal(msg.stop_reason, 'tool_use');
  assert.deepEqual(msg.content, [{ type: 'text', text: 'Let me look.' }, { type: 'tool_use', id: 'call_1', name: 'Grep', input: { pattern: 'TODO' } }]);
  assert.deepEqual(msg.usage, { input_tokens: 120, output_tokens: 14 });
  // Some servers end tool calls with "stop"; a long answer is cut at max_tokens; an empty one still has a text block.
  assert.equal(fromChatResponse({ choices: [{ finish_reason: 'stop', message: { tool_calls: [{ function: { name: 'X', arguments: {} } }] } }] }, 'm').stop_reason, 'tool_use');
  assert.equal(fromChatResponse({ choices: [{ finish_reason: 'length', message: { content: 'abc' } }] }, 'm').stop_reason, 'max_tokens');
  assert.deepEqual(fromChatResponse({ choices: [{ finish_reason: 'stop', message: { content: '' } }] }, 'm').content, [{ type: 'text', text: '' }]);
  assert.deepEqual(parseArgs('{"a":1}'), { a: 1 });
  assert.deepEqual(parseArgs({ a: 1 }), { a: 1 });
  assert.deepEqual(parseArgs(''), {});
  assert.deepEqual(parseArgs('{"a":'), { _raw: '{"a":' });
});

test('a streamed chat completion becomes a Messages stream, a block at a time', () => {
  const t = new StreamTranslator('m');
  let out = '';
  out += t.push({ choices: [{ index: 0, delta: { role: 'assistant', content: 'Look' } }] });
  out += t.push({ choices: [{ index: 0, delta: { content: 'ing.' } }] });
  out += t.push({ choices: [{ index: 0, delta: { tool_calls: [{ index: 0, id: 'call_a', type: 'function', function: { name: 'Read', arguments: '{"file_' } }] } }] });
  out += t.push({ choices: [{ index: 0, delta: { tool_calls: [{ index: 0, function: { arguments: 'path":"a.ts"}' } }] } }] });
  out += t.push({ choices: [{ index: 0, delta: { tool_calls: [{ index: 1, id: 'call_b', function: { name: 'Glob', arguments: '{"pattern":"*.ts"}' } }] } }] });
  out += t.push({ choices: [{ index: 0, delta: {}, finish_reason: 'tool_calls' }] });
  out += t.push({ choices: [], usage: { prompt_tokens: 50, completion_tokens: 9 } });
  out += t.end();
  const ev = events(out);
  assert.deepEqual(ev.map((e) => e.type), [
    'message_start',
    'content_block_start', 'content_block_delta', 'content_block_delta', 'content_block_stop',
    'content_block_start', 'content_block_delta', 'content_block_delta', 'content_block_stop',
    'content_block_start', 'content_block_delta', 'content_block_stop',
    'message_delta', 'message_stop',
  ]);
  assert.deepEqual(ev[5].content_block, { type: 'tool_use', id: 'call_a', name: 'Read', input: {} });
  assert.equal(ev.filter((e) => e.index === 1 && e.type === 'content_block_delta').map((e) => (e.delta as { partial_json: string }).partial_json).join(''), '{"file_path":"a.ts"}');
  assert.deepEqual(ev[12].delta, { stop_reason: 'tool_use', stop_sequence: null });
  assert.deepEqual(ev[12].usage, { input_tokens: 50, output_tokens: 9 });
  // Nothing at all: still a whole message, with one empty text block.
  assert.deepEqual(events(new StreamTranslator('m').end()).map((e) => e.type), ['message_start', 'content_block_start', 'content_block_stop', 'message_delta', 'message_stop']);
  // An error in the stream ends it as an error event.
  const f = new StreamTranslator('m');
  const bad = events(f.push({ choices: [{ delta: { content: 'a' } }] }) + f.push({ error: { message: 'out of memory' } }) + f.end());
  assert.deepEqual(bad.map((e) => e.type), ['message_start', 'content_block_start', 'content_block_delta', 'content_block_stop', 'error']);
  assert.equal((bad[4].error as { message: string }).message, 'out of memory');
});

test('splitSse keeps an unfinished event for later', () => {
  assert.deepEqual(splitSse('data: {"a":1}\n\ndata: {"b"'), { data: ['{"a":1}'], rest: 'data: {"b"' });
  assert.deepEqual(splitSse('event: x\r\ndata: [DONE]\r\n\r\n'), { data: ['[DONE]'], rest: '' });
  assert.ok(estimateTokens({ messages: [{ role: 'user', content: 'x'.repeat(400) }] }) > 100);
});

// ---- through the worker proxy, to a fake OpenAI-compatible server ----

type Seen = { path: string; auth?: string; body: Obj };
const seen: Seen[] = [];
let mode: 'ok' | 'overflow' | 'unauthorized' = 'ok';
const upstream = http.createServer((req, res) => {
  const chunks: Buffer[] = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    const body = chunks.length ? JSON.parse(Buffer.concat(chunks).toString()) : {};
    seen.push({ path: req.url ?? '', auth: req.headers.authorization, body });
    if (mode === 'unauthorized') return void res.writeHead(401, { 'content-type': 'application/json' }).end(JSON.stringify({ error: { message: 'Invalid API key' } }));
    if (mode === 'overflow') return void res.writeHead(400, { 'content-type': 'application/json' }).end(JSON.stringify({ error: { message: "This model's maximum context length is 32768 tokens. However, you requested 40000 tokens (39000 in the messages, 1000 in the completion)." } }));
    if (!body.stream) {
      return void res.writeHead(200, { 'content-type': 'application/json' }).end(JSON.stringify({
        choices: [{ finish_reason: 'stop', message: { role: 'assistant', content: 'Done.' } }], usage: { prompt_tokens: 30, completion_tokens: 2 },
      }));
    }
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    const chunk = (o: Obj) => res.write(`data: ${JSON.stringify(o)}\n\n`);
    chunk({ choices: [{ index: 0, delta: { role: 'assistant', content: 'On it.' } }] });
    chunk({ choices: [{ index: 0, delta: { tool_calls: [{ index: 0, id: 'call_9', type: 'function', function: { name: 'Bash', arguments: '{"command":' } }] } }] });
    // Split across writes, mid-event.
    res.write('data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"ls\\"}"}}]}}]}');
    setTimeout(() => {
      res.write('\n\n');
      chunk({ choices: [{ index: 0, delta: {}, finish_reason: 'tool_calls' }] });
      chunk({ choices: [], usage: { prompt_tokens: 80, completion_tokens: 12 } });
      res.end('data: [DONE]\n\n');
    }, 20);
  });
});
await new Promise<void>((r) => upstream.listen(0, '127.0.0.1', r));
const upPort = (upstream.address() as { port: number }).port;
const stats: RequestStats[] = [];
const route: Route = { upstream: `http://127.0.0.1:${upPort}/v1`, model: 'qwen3-coder', table: 'none', level: 'default', temperature: 0.3, taskId: 't-1', api: 'openai', apiKey: 'test-key' };
const proxy = await startWorkerProxy((w) => (w === 'oa' ? route : { refuse: 'no' }), (s) => stats.push(s));
after(async () => { await proxy.close(); upstream.close(); });

const post = (path: string, body: Obj) => fetch(`${proxy.baseUrl('oa')}${path}`, { method: 'POST', headers: { 'content-type': 'application/json', 'x-api-key': 'local' }, body: JSON.stringify(body) });

test('the proxy streams a worker request through an OpenAI-compatible server and back', async () => {
  seen.length = 0; stats.length = 0; mode = 'ok';
  const r = await post('/v1/messages?beta=true', { model: 'sonnet', max_tokens: 100, stream: true, messages: [{ role: 'user', content: 'list files' }], tools: [{ name: 'Bash', input_schema: { type: 'object' } }] });
  assert.equal(r.status, 200);
  assert.match(r.headers.get('content-type') ?? '', /event-stream/);
  const ev = events(await r.text());
  assert.equal(seen[0].path, '/v1/chat/completions');
  assert.equal(seen[0].auth, 'Bearer test-key');
  assert.equal(seen[0].body.model, 'qwen3-coder');
  assert.equal(seen[0].body.temperature, 0.3);
  const tool = ev.find((e) => e.type === 'content_block_start' && (e.content_block as Obj).type === 'tool_use');
  assert.deepEqual(tool?.content_block, { type: 'tool_use', id: 'call_9', name: 'Bash', input: {} });
  const json = ev.filter((e) => e.type === 'content_block_delta' && e.index === tool?.index).map((e) => (e.delta as { partial_json: string }).partial_json).join('');
  assert.deepEqual(JSON.parse(json), { command: 'ls' });
  assert.equal((ev.find((e) => e.type === 'message_delta')?.delta as Obj).stop_reason, 'tool_use');
  assert.equal(ev.at(-1)?.type, 'message_stop');
  assert.equal(stats.length, 1);
  assert.equal(stats[0].inputTokens, 80);
  assert.equal(stats[0].outputTokens, 12);
  assert.equal(stats[0].taskId, 't-1');
});

test('the proxy answers whole requests, count_tokens, overflows and refusals in Anthropic form', async () => {
  seen.length = 0; stats.length = 0; mode = 'ok';
  const whole = await (await post('/v1/messages', { max_tokens: 10, messages: [{ role: 'user', content: 'hi' }] })).json() as Obj;
  assert.deepEqual(whole.content, [{ type: 'text', text: 'Done.' }]);
  assert.equal(whole.stop_reason, 'end_turn');
  assert.equal(stats[0].outputTokens, 2);

  const count = await (await post('/v1/messages/count_tokens', { messages: [{ role: 'user', content: 'x'.repeat(40) }] })).json() as Obj;
  assert.equal(typeof count.input_tokens, 'number');
  assert.equal(seen.length, 1, 'count_tokens is answered by the proxy');

  mode = 'overflow';
  const over = await post('/v1/messages', { max_tokens: 10, messages: [{ role: 'user', content: 'hi' }] });
  assert.equal(over.status, 400);
  assert.match(((await over.json()) as { error: { message: string } }).error.message, /^prompt is too long: 40000 tokens > 32768 maximum/);

  mode = 'unauthorized';
  const denied = await post('/v1/messages', { max_tokens: 10, messages: [{ role: 'user', content: 'hi' }] });
  assert.equal(denied.status, 401);
  assert.deepEqual(await denied.json(), { type: 'error', error: { type: 'authentication_error', message: 'Invalid API key' } });

  const other = await post('/v1/complete', {});
  assert.equal(other.status, 404);
});
