// Web access: what opens without asking (documentation and code-hosting sites, and sites a worker's task names), what
// doesn't, and the research profile that lets a local worker read pages.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { LEAD } from '../src/dialogue.ts';
import { describeProfiles, PROFILES } from '../src/profiles.ts';
import { wrapTask } from '../src/dialogue.ts';
import { fetchRefusal, fetchRules, sitesIn } from '../src/web.ts';
import { guard } from '../src/worker.ts';

test('documentation and code-hosting pages open without asking; other sites, odd schemes and long queries do not', () => {
  for (const url of [
    'https://developer.apple.com/documentation/speech/speechanalyzer',
    'https://github.com/anthropics/claude-agent-sdk-typescript/issues/12',
    'https://raw.githubusercontent.com/a/b/main/README.md',
    'https://docs.python.org/3/library/asyncio.html',
    'https://requests.readthedocs.io/en/latest/',
    'https://en.wikipedia.org/wiki/Echo_suppression_and_cancellation',
    'https://www.npmjs.com/package/node-pty',
  ]) assert.equal(fetchRefusal(url), null, url);
  assert.match(fetchRefusal('https://example.net/page') ?? '', /example\.net isn't a documentation or code-hosting site/);
  assert.match(fetchRefusal('https://github.com.evil.example/x') ?? '', /isn't a documentation/, 'a look-alike host is not github.com');
  assert.match(fetchRefusal('file:///etc/passwd') ?? '', /Only web pages/);
  assert.match(fetchRefusal(`https://github.com/search?q=${'x'.repeat(300)}`) ?? '', /long query/, 'no carrying text out in a query');
  assert.match(fetchRefusal('not a url') ?? '', /Not a URL/);
});

test('a site the task names opens too, and only for that task', () => {
  const task = 'Read https://blog.example.org/post/42 and https://example.net/notes, then summarize what changed.';
  assert.deepEqual(sitesIn(task), ['blog.example.org', 'example.net']);
  assert.equal(fetchRefusal('https://example.net/other-page', sitesIn(task)), null);
  assert.notEqual(fetchRefusal('https://another.example.com/', sitesIn(task)), null);
});

test("a worker's fetches go through the guard: allowed sites pass, others are refused with a reason the worker can act on", async () => {
  const hooks = guard('/tmp/proj', true, ['example.net'])[0].hooks;
  const call = async (url: string) => {
    const out = (await hooks[0]({ hook_event_name: 'PreToolUse', tool_name: 'WebFetch', tool_input: { url, prompt: 'what changed?' } } as never, undefined, { signal: new AbortController().signal })) as {
      hookSpecificOutput?: { permissionDecision?: string; permissionDecisionReason?: string };
    };
    return out.hookSpecificOutput;
  };
  assert.equal(await call('https://developer.apple.com/documentation/avfaudio'), undefined);
  assert.equal(await call('https://example.net/x'), undefined, 'named in the task');
  const refused = await call('https://evil.example/collect');
  assert.equal(refused?.permissionDecision, 'deny');
  assert.match(refused?.permissionDecisionReason ?? '', /Report the URL instead/);
});

test('Claude and side chats get one fetch rule per site, never a bare WebFetch that would open anything', () => {
  const rules = fetchRules();
  assert.ok(rules.includes('WebFetch(domain:developer.apple.com)'));
  assert.ok(rules.includes('WebFetch(domain:www.npmjs.com)'));
  assert.ok(!rules.includes('WebFetch'));
  assert.ok(rules.every((r) => /^WebFetch\(domain:[a-z0-9.-]+\)$/.test(r)));
});

test('the research profile reads pages and files, changes nothing, and reports its sources', () => {
  const p = PROFILES.research;
  assert.deepEqual([...p.tools].sort(), ['Glob', 'Grep', 'Read', 'WebFetch']);
  assert.equal(p.readOnly, true);
  assert.match(p.report, /URL/);
  assert.match(describeProfiles(), /"research" \(WebFetch, Read, Glob, Grep; no shell; read-only\): read web pages/);
  const brief = wrapTask('What changed in SpeechAnalyzer in iOS 27? Start at https://developer.apple.com/documentation/updates/speech', 'research');
  assert.match(brief, /Task profile: research \(read-only\)/);
  assert.match(brief, /rather than filling it from memory/);
  assert.match(brief, /when you could not check something, say so/, 'every worker is told not to guess');
  assert.equal(LEAD, 'lead');
});
