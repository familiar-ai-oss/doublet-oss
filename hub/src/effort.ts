// Per-backend effort tables for local workers. The worker proxy applies these to every /v1/messages body.
// Measured in Phase 0 (spike 7): on llama.cpp only chat_template_kwargs reaches the template;
// Claude Code's own output_config.effort also reaches the 27B (and "max" is a 400), so the proxy strips it.

export type EffortTableId = 'qwen-levels' | 'ctk-onoff' | 'ollama-onoff' | 'gptoss-levels' | 'apple-none' | 'none';

export type EffortTable = {
  levels: string[];
  default: string;
  // Fields merged into the request body for a level.
  apply: (level: string) => Record<string, unknown>;
};

export const EFFORT_TABLES: Record<EffortTableId, EffortTable> = {
  // qwen3.8-27B: thinking on by default at medium. Low measured barely different from medium, so it isn't offered.
  'qwen-levels': {
    levels: ['off', 'medium', 'xhigh'],
    default: 'medium',
    apply: (l) => ({ chat_template_kwargs: l === 'off' ? { enable_thinking: false } : { enable_thinking: true, reasoning_effort: l } }),
  },
  // llama.cpp models whose template only has a thinking switch (the 3060 9B). Server default is off.
  'ctk-onoff': {
    levels: ['off', 'on'],
    default: 'off',
    apply: (l) => ({ chat_template_kwargs: { enable_thinking: l === 'on' } }),
  },
  // gpt-oss: its template reads reasoning_effort (model card; not yet measured on the hub machine).
  'gptoss-levels': {
    levels: ['low', 'medium', 'high'],
    default: 'medium',
    apply: (l) => ({ chat_template_kwargs: { reasoning_effort: l } }),
  },
  // Apple's on-device model has no effort setting; temperature is its only knob.
  'apple-none': {
    levels: [],
    default: 'default',
    apply: () => ({}),
  },
  // Claude's subagents use Claude's own settings.
  none: {
    levels: [],
    default: 'default',
    apply: () => ({}),
  },
  // Ollama >= 0.32 honours thinking:{type:"disabled"} on /v1/messages; models think by default.
  'ollama-onoff': {
    levels: ['off', 'on'],
    default: 'off',
    apply: (l) => (l === 'off' ? { thinking: { type: 'disabled' } } : {}),
  },
};

// Fields a worker's Claude Code sends that must not reach the backend unmodified.
export function stripClientEffort(body: Record<string, unknown>, table: EffortTableId): void {
  const oc = body.output_config as Record<string, unknown> | undefined;
  if (oc && typeof oc === 'object') {
    delete oc.effort;
    if (!Object.keys(oc).length) delete body.output_config;
  }
  delete body.reasoning_effort;
  // llama.cpp ignores thinking; Ollama honours it, so only the table may set it there.
  delete body.thinking;
  if (table !== 'ollama-onoff') delete body.chat_template_kwargs;
}

export function applyEffort(body: Record<string, unknown>, table: EffortTableId, level: string, temperature?: number): void {
  stripClientEffort(body, table);
  Object.assign(body, EFFORT_TABLES[table].apply(level));
  if (temperature !== undefined) body.temperature = temperature;
}

// Which table a local model uses, by id. null = not offered as a worker model (embeddings, rerankers,
// models whose effort mapping is unknown, or dsv4, which takes both GPUs).
export function tableForModel(id: string): EffortTableId | null {
  if (/embedding|reranker|zeta|dsv4/.test(id)) return null;
  if (/^qwen3\.8/.test(id)) return 'qwen-levels';
  if (/^gpt-oss/.test(id)) return 'gptoss-levels';
  if (/^(qwen3|glm|gemma4)/.test(id)) return 'ctk-onoff';
  return null;
}

// Effort mappings measured on the hub machine (Phase 0 spike 7, Phase 2 tests) or on the Mac (mac-models report).
export const VERIFIED_EFFORT = new Set(['qwen3.8-27b', 'qwen3.5-9b-3060', 'hf.co/ornith-ai/Ornith-1.5-9B-GGUF:Q8_0']);

export function validLevel(table: EffortTableId, level: string): boolean {
  return EFFORT_TABLES[table].levels.includes(level);
}
