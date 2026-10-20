// What's in a folder on the hub machine, and what's in a file: for the apps' file viewer. Each entry carries its git status, and
// a file its changed lines, so the work in progress shows. The hub reads as the user it runs as (as the terminal does).
import { execFile } from 'node:child_process';
import { lstat, open, readdir, realpath, stat } from 'node:fs/promises';
import { homedir } from 'node:os';
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { promisify } from 'node:util';
import type { FsEntry, FsFile, FsListing } from './protocol.ts';

const run = promisify(execFile);
const MAX_ENTRIES = 3000;
const MAX_FILE = 1 << 20;

/** `~` and relative paths, from a base folder. */
export function expandPath(p: string, base: string): string {
  if (p === '~') return homedir();
  if (p.startsWith('~/')) return join(homedir(), p.slice(2));
  return isAbsolute(p) ? resolve(p) : resolve(base, p);
}

async function git(cwd: string, args: string[]): Promise<string | null> {
  try {
    return (await run('git', ['-C', cwd, ...args], { timeout: 4000, maxBuffer: 8 << 20 })).stdout;
  } catch {
    return null;
  }
}

/** The repo a folder is in (its root and branch), if any. */
async function repoOf(dir: string): Promise<{ root: string; branch: string } | null> {
  const root = (await git(dir, ['rev-parse', '--show-toplevel']))?.trim();
  if (!root) return null;
  const branch = (await git(root, ['rev-parse', '--abbrev-ref', 'HEAD']))?.trim() || 'HEAD';
  return { root, branch };
}

/**
 * Each changed path in the repo with its two-letter status (`git status --porcelain`): ` M` modified, `A ` added,
 * `??` untracked, ` D` deleted, `R ` renamed.
 */
async function statuses(root: string): Promise<Map<string, string>> {
  const out = await git(root, ['status', '--porcelain=v1', '-z']);
  const map = new Map<string, string>();
  if (!out) return map;
  const parts = out.split('\0');
  for (let i = 0; i < parts.length; i++) {
    const p = parts[i];
    if (p.length < 4) continue;
    const code = p.slice(0, 2);
    map.set(p.slice(3).replace(/\/$/, ''), code);
    if (code[0] === 'R' || code[0] === 'C') i++; // the next part is the old name
  }
  return map;
}

/** One letter for the app: M changed, A added, ? new (untracked), D deleted, R renamed, U conflicted. */
function letter(code: string): string {
  if (code === '??') return '?';
  if (code.includes('U')) return 'U';
  for (const c of [code[1], code[0]]) if (c && c !== ' ') return c === 'T' ? 'M' : c;
  return 'M';
}

export async function listDir(input: string, base: string): Promise<FsListing> {
  const path = await realpath(expandPath(input, base));
  const info = await stat(path);
  if (!info.isDirectory()) throw new Error(`${path} is not a folder`);
  const names = await readdir(path, { withFileTypes: true });
  const repo = await repoOf(path);
  const changes = repo ? await statuses(repo.root) : new Map<string, string>();
  // Changed paths relative to this folder: the entry itself, or a folder that contains changes.
  const marks = new Map<string, string>();
  const rel = repo ? relative(repo.root, path) : '';
  for (const [p, code] of changes) {
    const under = rel ? (p.startsWith(rel + '/') ? p.slice(rel.length + 1) : null) : p;
    if (!under) continue;
    const [first, ...rest] = under.split('/');
    // The entry's own status (an untracked folder is listed as one entry), or a dot for a folder with changes inside.
    if (!rest.length) marks.set(first, letter(code));
    else if (!marks.has(first)) marks.set(first, '•');
  }
  const entries: FsEntry[] = [];
  for (const d of names) {
    if (d.name === '.git') continue;
    if (entries.length >= MAX_ENTRIES) break;
    const full = join(path, d.name);
    let kind: FsEntry['kind'] = d.isDirectory() ? 'dir' : 'file';
    let size = 0;
    let mtime = 0;
    try {
      const s = d.isSymbolicLink() ? await stat(full) : await lstat(full);
      if (d.isSymbolicLink()) kind = s.isDirectory() ? 'dir' : 'file';
      size = s.size;
      mtime = Math.round(s.mtimeMs);
    } catch {
      kind = 'file'; // a broken link
    }
    const e: FsEntry = { name: d.name, kind, size, mtime };
    if (d.isSymbolicLink()) e.link = true;
    const g = marks.get(d.name);
    if (g) e.git = g;
    entries.push(e);
  }
  entries.sort((a, b) => (a.kind === b.kind ? a.name.localeCompare(b.name, undefined, { sensitivity: 'base', numeric: true }) : a.kind === 'dir' ? -1 : 1));
  const listing: FsListing = { path, parent: path === sep ? null : dirname(path), entries, truncated: names.length > MAX_ENTRIES + 1 };
  if (repo) listing.repo = { root: repo.root, branch: repo.branch };
  return listing;
}

/** Lines changed since the last commit, from `git diff -U0`: added or changed lines, and where lines were removed. */
async function changedLines(file: string): Promise<{ changed: number[]; removedAfter: number[] } | null> {
  const dir = dirname(file);
  const out = await git(dir, ['diff', '--no-color', '-U0', 'HEAD', '--', basename(file)]);
  if (out === null) return null;
  const changed: number[] = [];
  const removedAfter: number[] = [];
  for (const line of out.split('\n')) {
    const m = line.match(/^@@ -\d+(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/);
    if (!m) continue;
    const removed = m[1] === undefined ? 1 : Number(m[1]);
    const start = Number(m[2]);
    const added = m[3] === undefined ? 1 : Number(m[3]);
    for (let i = 0; i < added; i++) changed.push(start + i);
    if (removed > 0 && added === 0) removedAfter.push(start);
  }
  return { changed, removedAfter };
}

export async function readFile(input: string, base: string): Promise<FsFile> {
  const path = await realpath(expandPath(input, base));
  const info = await stat(path);
  if (info.isDirectory()) throw new Error(`${path} is a folder`);
  const out: FsFile = { path, size: info.size, mtime: Math.round(info.mtimeMs), binary: false, truncated: info.size > MAX_FILE };
  const fh = await open(path, 'r');
  try {
    const buf = Buffer.alloc(Math.min(info.size, MAX_FILE));
    await fh.read(buf, 0, buf.length, 0);
    // A NUL byte early on: not text.
    if (buf.subarray(0, 8192).includes(0)) {
      out.binary = true;
      return out;
    }
    out.text = buf.toString('utf8');
  } finally {
    await fh.close();
  }
  const repo = await repoOf(dirname(path));
  if (repo) {
    const g = (await statuses(repo.root)).get(relative(repo.root, path));
    if (g) out.git = letter(g);
    if (g !== '??') {
      const lines = await changedLines(path);
      if (lines && (lines.changed.length || lines.removedAfter.length)) Object.assign(out, lines);
    }
  }
  return out;
}

const MAX_FILES = 20_000;
// Never worth listing for Quick Open, outside a git repo (inside one, .gitignore decides).
const SKIP = new Set(['.git', 'node_modules', '.venv', 'venv', '__pycache__', '.build', 'build', 'dist', 'DerivedData', '.cache', '.next', 'target']);

/** Every file under a folder, as paths relative to it, for Quick Open: git's files (tracked, and new ones it doesn't
 *  ignore) in a repo, else a walk that skips hidden folders and build output. At most 20,000. */
export async function listFiles(input: string, base: string): Promise<string[]> {
  const root = await realpath(expandPath(input, base));
  if (!(await stat(root)).isDirectory()) throw new Error(`${root} is not a folder`);
  if (await repoOf(root)) {
    const out = await git(root, ['ls-files', '--cached', '--others', '--exclude-standard', '-z']);
    if (out !== null) return [...new Set(out.split('\0').filter(Boolean))].slice(0, MAX_FILES);
  }
  const files: string[] = [];
  const queue = [''];
  while (queue.length && files.length < MAX_FILES) {
    const rel = queue.shift()!;
    let names;
    try { names = await readdir(join(root, rel), { withFileTypes: true }); } catch { continue; }
    for (const d of names) {
      const p = rel ? `${rel}/${d.name}` : d.name;
      if (d.isDirectory()) { if (!d.name.startsWith('.') && !SKIP.has(d.name)) queue.push(p); } else if (files.length < MAX_FILES) files.push(p);
    }
  }
  return files;
}

/** A folder Claude, new shells and worker tasks can work in. */
export async function checkFolder(input: string, base: string): Promise<string> {
  const path = await realpath(expandPath(input, base)).catch(() => {
    throw new Error(`${input} doesn't exist`);
  });
  if (!(await stat(path)).isDirectory()) throw new Error(`${path} is not a folder`);
  return path;
}
