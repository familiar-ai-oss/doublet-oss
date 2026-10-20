// How much a local model can hold, and what its worker's Claude Code needs told about it.
//
// Workers run Claude Code against the hub's proxy under the name "sonnet", so Claude Code sizes auto-compaction for
// Sonnet's window. A local model's real window (the running server says; models.toml otherwise) is what counts: past
// it the server refuses the request and the task fails. So each run gets the real window, a reply budget that fits,
// and the point to compact at (docs/orchestration.md).

/** What the running server says the model holds: llama.cpp's per-slot context, or vLLM's max_model_len. */
export async function servedContext(host: string, port: number, servedId: string, timeoutMs = 2000): Promise<number | null> {
  const get = async (path: string) => {
    const r = await fetch(`http://${host}:${port}${path}`, { signal: AbortSignal.timeout(timeoutMs) });
    return r.ok ? r.json() as Promise<Record<string, unknown>> : null;
  };
  try {
    // llama.cpp: n_ctx is per slot already (the -c total split over -np slots).
    const props = await get('/props').catch(() => null);
    const g = props?.default_generation_settings as { n_ctx?: number } | undefined;
    if (typeof g?.n_ctx === 'number' && g.n_ctx > 0) return g.n_ctx;
  } catch {}
  try {
    const models = await get('/v1/models');
    const data = (models?.data ?? []) as { id?: string; max_model_len?: number }[];
    const m = data.find((x) => x.id === servedId) ?? data.find((x) => typeof x.max_model_len === 'number');
    if (typeof m?.max_model_len === 'number' && m.max_model_len > 0) return m.max_model_len;
  } catch {}
  return null;
}

/**
 * Each model's window as models.toml sets it (vLLM's max-model-len, llama.cpp's -c over its -np slots), the smallest
 * where a model has several profiles. The fallback when the server can't be asked.
 */
export function tomlContexts(text: string): Map<string, number> {
  const out = new Map<string, number>();
  let model: string | null = null;
  let block: string[] = [];
  const flush = () => {
    if (!model) return;
    const n = blockContext(block.join('\n'));
    if (n !== null) out.set(model, Math.min(out.get(model) ?? Infinity, n));
  };
  for (const line of text.split('\n')) {
    const sec = line.match(/^\[models\."([^"]+)"(?:\.[^\]]*)?\]\s*$/);
    if (sec || line.startsWith('[')) {
      flush();
      block = [];
      model = sec ? sec[1] : null;
      continue;
    }
    if (model) block.push(line.replace(/#.*$/, ''));
  }
  flush();
  return out;
}

function blockContext(s: string): number | null {
  const nums = (re: RegExp) => [...s.matchAll(re)].map((m) => Number(m[1])).filter((n) => n > 0);
  const vllm = nums(/--max-model-len"?\s*,\s*"?(\d+)/g).concat(nums(/max_model_len\\?"?\s*[:=]\s*(\d+)/g));
  if (vllm.length) return Math.min(...vllm);
  const ctx = nums(/"(?:-c|--ctx-size)"\s*,\s*"(\d+)"/g);
  if (!ctx.length) return null;
  const slots = nums(/"(?:-np|--parallel)"\s*,\s*"(\d+)"/g);
  return Math.floor(Math.min(...ctx) / Math.max(1, ...(slots.length ? slots : [1])));
}

/** Claude Code takes a compaction window between these (it ignores smaller ones and caps larger). */
export const COMPACT_WINDOW_MIN = 100_000;
export const COMPACT_WINDOW_MAX = 1_000_000;

/**
 * The environment that fits a worker's Claude Code to a model holding `ctx` tokens:
 * - the reply budget (CLAUDE_CODE_MAX_OUTPUT_TOKENS): an eighth of the window, 4K to 32K, so a full prompt plus a reply
 *   still fits (a server refuses max_tokens past its window);
 * - the compaction window (CLAUDE_CODE_AUTO_COMPACT_WINDOW): the real window, but no smaller than Claude Code accepts;
 * - when to compact (CLAUDE_AUTOCOMPACT_PCT_OVERRIDE): at the share of that window that leaves room for the reply and a
 *   margin (10%, at most 16K) in the real one. For a 65K model the window reads 100K and compaction comes at about 50%.
 */
export function compactionEnv(ctx: number): Record<string, string> {
  const output = Math.min(32_000, Math.max(4_096, Math.floor(ctx / 8)));
  const window = Math.min(COMPACT_WINDOW_MAX, Math.max(COMPACT_WINDOW_MIN, ctx));
  const margin = Math.min(16_000, Math.floor(ctx / 10));
  const at = Math.max(5, Math.min(90, Math.floor(((ctx - output - margin) / window) * 100)));
  return {
    CLAUDE_CODE_MAX_OUTPUT_TOKENS: String(output),
    CLAUDE_CODE_AUTO_COMPACT_WINDOW: String(window),
    CLAUDE_AUTOCOMPACT_PCT_OVERRIDE: String(at),
  };
}

// How local servers say a request didn't fit: vLLM ("maximum context length", "max_model_len"), llama.cpp ("exceeds
// the available context size", exceed_context_size_error).
const OVERFLOW = /maximum context length|max_model_len|max_total_tokens|exceeds? the available context size|exceed_context_size|context (?:length|window|size) (?:exceeded|is too)|too many tokens/i;

/**
 * A local server's "doesn't fit" error, in the words Claude Code acts on: Anthropic's "prompt is too long", which makes
 * it compact the conversation and try again instead of failing. Other errors (nil) pass through as they are.
 */
export function overflowAsPromptTooLong(status: number, body: string): string | null {
  if (status !== 400 && status !== 413 && status !== 422) return null;
  if (!OVERFLOW.test(body)) return null;
  const n = (re: RegExp) => { const m = body.match(re); return m ? Number(m[1]) : null; };
  const limit = n(/max(?:imum)? context length is (\d+)/i) ?? n(/max_model_len(?:=max_total_tokens)?=(\d+)/i) ?? n(/n_ctx(?:_slot)?\s*[=:]\s*(\d+)/i);
  const asked = n(/(?:you requested|requested) (\d+) tokens/i) ?? n(/(\d+) tokens? \(?.{0,20}(?:prompt|input)/i);
  const sizes = limit && asked && asked > limit ? `: ${asked} tokens > ${limit} maximum` : '';
  return JSON.stringify({ type: 'error', error: { type: 'invalid_request_error', message: `prompt is too long${sizes}` } });
}

/**
 * What a worker is told as its turns run out, or nil while there are enough left: once when a tenth (at least 3) are
 * left, and again on its last turn. With a report tool it hands over properly; without one it writes its answer.
 */
export function turnWarning(used: number, max: number, canReport: boolean): string | null {
  const left = max - used;
  const warnAt = Math.max(3, Math.round(max / 10));
  if (left !== warnAt && left !== 1) return null;
  const how = canReport
    ? 'call report with kind "final": what you finished, what is left and anything the lead must know'
    : 'write your final answer: what you found or did, and what is left';
  return left === 1
    ? `This is your last turn of ${max}. Do nothing else: ${how}.`
    : `You have ${left} of your ${max} turns left. Don't start anything new. Now ${how}, then stop.`;
}
