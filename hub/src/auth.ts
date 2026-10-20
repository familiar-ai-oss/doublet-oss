// Two checks per connection:
//  1. Upgrade request: a Tailscale-User-Login header (added by `tailscale serve`) must be on the allowlist;
//     a request without one is accepted only from loopback (cli.ts on the hub machine).
//  2. hello frame: a per-device token. Only SHA-256 hashes are stored on disk.
import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import type { IncomingMessage } from 'node:http';

const LOOPBACK = new Set(['127.0.0.1', '::1', '::ffff:127.0.0.1']);

export function checkUpgrade(req: IncomingMessage, allowedLogins: string[]): string | null {
  const login = req.headers['tailscale-user-login'];
  if (typeof login === 'string') {
    return allowedLogins.includes(login) ? null : `tailscale login ${login} is not allowed`;
  }
  return LOOPBACK.has(req.socket.remoteAddress ?? '') ? null : 'no tailscale identity and not loopback';
}

type TokenFile = { devices: Record<string, string> };

const sha = (s: string) => createHash('sha256').update(s).digest();

export class Tokens {
  private file: string;
  constructor(file: string) {
    this.file = file;
  }

  private read(): TokenFile {
    if (!existsSync(this.file)) return { devices: {} };
    return JSON.parse(readFileSync(this.file, 'utf8'));
  }

  /** The devices tokens were made for: the user's devices. */
  names(): string[] {
    return Object.keys(this.read().devices);
  }

  // True when token is the one issued to this device.
  verify(device: string, token: string): boolean {
    const stored = this.read().devices[device];
    if (!stored || typeof token !== 'string') return false;
    const a = Buffer.from(stored, 'hex');
    const b = sha(token);
    return a.length === b.length && timingSafeEqual(a, b);
  }

  add(device: string): string {
    if (!/^[a-z0-9][a-z0-9-]{0,31}$/.test(device)) throw new Error('device name must be lowercase letters, digits and dashes');
    const token = randomBytes(24).toString('base64url');
    const f = this.read();
    f.devices[device] = sha(token).toString('hex');
    mkdirSync(dirname(this.file), { recursive: true, mode: 0o700 });
    writeFileSync(this.file, JSON.stringify(f, null, 2), { mode: 0o600 });
    return token;
  }

  remove(device: string): boolean {
    const f = this.read();
    if (!(device in f.devices)) return false;
    delete f.devices[device];
    writeFileSync(this.file, JSON.stringify(f, null, 2), { mode: 0o600 });
    return true;
  }
}
