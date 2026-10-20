// Your own settings for this hub, kept out of the repository: hub/local.env (git-ignored; see local.env.example).
// main.ts imports this first, so every module sees the values. Variables already in the environment win.
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const file = fileURLToPath(new URL('../local.env', import.meta.url));
if (existsSync(file)) process.loadEnvFile(file);
