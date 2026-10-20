// Canonical client -> hub messages, type-checked against the protocol. With DUET_FIXTURES_DIR set they are
// written to client.jsonl, and the Swift tests check that DuetKit encodes the same JSON.
import { test } from 'node:test';
import { writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import type { ClientMsg } from '../src/protocol.ts';

export const CLIENT_MESSAGES: ClientMsg[] = [
  { type: 'hello', protocol: 1, token: 'TOKEN', device: 'mac', lastSeq: 42 },
  { type: 'prompt', ref: '1', text: 'Hello' },
  { type: 'approve', ref: '2', id: 'ab12cd34' },
  { type: 'approve', ref: '3', id: 'ab12cd34', updatedInput: { command: 'ls -la', timeout: 5000 } },
  { type: 'reject', ref: '4', id: 'ab12cd34', message: 'Not that file' },
  { type: 'interrupt', ref: '5' },
  { type: 'set_effort', ref: '6', level: 'high' },
  { type: 'set_effort', ref: '7', level: null },
  { type: 'delegate', ref: '8', worker: 'qwen-27b', prompt: 'Fix the test', cwd: '/home/you/proj', effort: 'xhigh' },
  { type: 'cancel_task', ref: '9', taskId: 't-abc123' },
  { type: 'set_worker', ref: '10', worker: 'qwen-9b', effort: 'on', temperature: 0.3, enabled: true },
  { type: 'approve_swap', ref: '11', id: 's-abc123' },
  { type: 'reject_swap', ref: '12', id: 's-abc123' },
  { type: 'answer', ref: '13', questionId: 'q-abc123', text: 'Use duet' },
  { type: 'steer', ref: '14', taskId: 't-abc123', text: 'Skip the docs' },
  { type: 'set_pause', ref: '15', paused: true },
  { type: 'prompt', ref: '16', text: 'Think hard', boost: true },
  { type: 'set_worker', ref: '17', worker: 'qwen-9b', model: 'gemma4-26b' },
  { type: 'clear', ref: '18' },
  { type: 'compact', ref: '19' },
  { type: 'set_model', ref: '20', model: 'sonnet' },
  { type: 'broadcast', ref: '21', text: 'Status, everyone?' },
  { type: 'pty_open', ref: '22', kind: 'shell', cols: 100, rows: 30 },
  { type: 'pty_attach', ref: '23', id: 'pty-abc123' },
  { type: 'pty_input', ref: '24', id: 'pty-abc123', data: 'ls\r' },
  { type: 'pty_resize', ref: '25', id: 'pty-abc123', cols: 120, rows: 40 },
  { type: 'pty_close', ref: '26', id: 'pty-abc123' },
  { type: 'delegate', ref: '27', worker: 'apple-ipad', prompt: 'Summarize the errors', files: ['/home/you/proj/build.log'] },
  { type: 'apple_status', ref: '28', available: true, variant: 'AFM 3 Core', contextSize: 4096, capabilities: ['guidedGeneration', 'toolCalling'], platform: 'ipad', simulator: false },
  { type: 'apple_status', ref: '29', available: false, reason: 'modelNotReady', platform: 'iphone' },
  { type: 'apple_progress', ref: '30', taskId: 't-abc123', text: 'Read part 1 of 3: disk full on /var' },
  { type: 'apple_done', ref: '31', taskId: 't-abc123', ok: true, result: 'Three errors, all disk full.', stats: { inputTokens: 3900, outputTokens: 120, wallMs: 5200, firstTokenMs: 900, parts: 4, genMs: 3100 } },
  { type: 'apple_done', ref: '32', taskId: 't-abc123', ok: false, error: 'The text was too long for the on-device model' },
  { type: 'resume_session', ref: '33', sessionId: 'f35790a0-07ad-4715-9450-8b37023a3197' },
  { type: 'side_ask', ref: '34', text: 'Why two GPUs?', about: { kind: 'file', path: '/home/you/proj/fleet.ts', start: 12, end: 20 }, model: 'haiku' },
  { type: 'side_ask', ref: '35', chatId: 'sc-abc123', text: 'And the 9B?' },
  { type: 'side_ask', ref: '36', text: 'What is this?', about: { kind: 'text', label: "qwen-27b's result", text: 'Finished: 3 files' }, image: 'BASE64', imageType: 'image/jpeg' },
  { type: 'side_stop', ref: '37', chatId: 'sc-abc123' },
  { type: 'fs_watch', ref: '38', paths: ['/home/you/proj', '/home/you/proj/src'] },
  { type: 'fs_files', ref: '39' },
  { type: 'prompt', ref: '40', text: 'What does auto do?', voice: true },
  { type: 'side_ask', ref: '41', chatId: 'sc-abc123', text: 'Why that one?', voice: true },
  { type: 'delegate', ref: '42', worker: 'qwen-27b', prompt: 'What changed in Speech in iOS 27? Start at https://developer.apple.com/documentation/updates/speech', profile: 'research' },
  { type: 'annotation_update', ref: '43', id: 'note-1', reroute: 'claude' },
  { type: 'side_reroute', ref: '44', chatId: 'sc-abc123' },
  { type: 'note_reply', ref: '45', id: 'note-1', text: 'Why not undefined?' },
  { type: 'note_reply', ref: '46', id: 'note-1', text: '', image: 'BASE64', imageType: 'image/png' },
  { type: 'outside_follow', ref: '47', sessionId: 'ce46f81f-ec40-4c7d-885d-547ef9d911b3' },
  { type: 'outside_unfollow', ref: '48', sessionId: 'ce46f81f-ec40-4c7d-885d-547ef9d911b3' },
  { type: 'outside_continue', ref: '49', sessionId: 'ce46f81f-ec40-4c7d-885d-547ef9d911b3' },
  { type: 'set_permission_mode', ref: '50', mode: 'plan' },
  { type: 'set_permission_mode', ref: '51', mode: 'bypassPermissions' },
  { type: 'hello', protocol: 1, token: 'TOKEN', device: 'studio', lastSeq: 0, kind: 'mac' },
  { type: 'send_place', ref: '52', to: 'ipad', place: { file: { path: '/home/you/proj/Lexer.swift', line: 27 } }, title: 'Lexer.swift' },
  { type: 'notes', ref: '53', surface: { kind: 'plan', conversationId: 'f35790a0-07ad-4715-9450-8b37023a3197' }, items: [{ id: 'n-1', intent: 'change', text: 'Tests first', elements: [{ id: '3', label: 'Refactor the lexer' }] }] },
  { type: 'send_place', ref: '54', to: 'ipad', place: { diagram: { _0: 'g1' } }, title: 'Lexer states', write: true },
  { type: 'place_seen', ref: '55', id: 'p-1' },
  { type: 'open_places', ref: '56', places: [{ place: { file: { _0: '/home/you/proj/Lexer.swift', line: 27 } }, title: 'Lexer.swift' }, { place: { diagram: { _0: 'g1' } }, title: 'Lexer states' }], current: 1 },
  { type: 'open_places', ref: '57', places: [] },
  { type: 'side_title', ref: '58', chatId: 'sc-abc123', title: 'Why the Hub Uses Two GPUs' },
  { type: 'diagnostic', ref: '59', id: 'f-1a2b', kind: 'freeze', summary: 'Freeze 2.9 s on the conversation', at: '2026-10-19T09:02:11Z', durationMs: 2900, build: '0.1 (1) debug', os: 'iPadOS 27.2', model: 'iPad16,6', context: { place: 'lead', recent: ['tab lift', 'drop: split right'] } },
  { type: 'diagnostic', ref: '60', id: 'mx-crash-1', kind: 'crash', summary: 'Crash: EXC_CRASH (SIGABRT)', payload: '{"callStackTree":{}}' },
  // Settings → Agents.
  { type: 'agents_list', ref: '61' },
  { type: 'agents_scan', ref: '62' },
  { type: 'endpoints_list', ref: '63' },
  { type: 'endpoint_add', ref: '64', name: 'LM Studio', baseUrl: 'http://127.0.0.1:1234/v1', model: 'qwen3-coder-30b', apiKey: 'local-key' },
  { type: 'endpoint_update', ref: '65', id: 'lm-studio', model: 'gemma4-26b', apiKey: null, enabled: false },
  { type: 'endpoint_update', ref: '66', id: 'lm-studio', name: 'LM Studio (Mac)', apiKey: 'new-key' },
  { type: 'endpoint_remove', ref: '67', id: 'lm-studio' },
  { type: 'endpoint_test', ref: '68', baseUrl: 'http://127.0.0.1:1234/v1', apiKey: 'local-key' },
  { type: 'endpoint_test', ref: '69', id: 'lm-studio' },
  { type: 'endpoint_add', ref: '70', name: 'vLLM', baseUrl: 'http://my-gpu-box:8000/v1', model: 'qwen3-coder', enabled: false },
];

test('client message fixtures', () => {
  const dir = process.env.DUET_FIXTURES_DIR;
  if (!dir) return;
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, 'client.jsonl'), CLIENT_MESSAGES.map((m) => JSON.stringify(m)).join('\n') + '\n');
});
