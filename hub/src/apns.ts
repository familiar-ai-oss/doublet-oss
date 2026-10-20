// APNs over HTTP/2 with a token-based (.p8) key: just enough to start, update and end Live Activities.
import { createPrivateKey, sign, type KeyObject } from 'node:crypto';
import { readFileSync } from 'node:fs';
import http2 from 'node:http2';

export type ApnsEnv = 'development' | 'production';
export type ApnsConfig = { keyFile: string; keyId: string; teamId: string; bundleId: string };

const b64url = (b: Buffer | string) => Buffer.from(b).toString('base64url');

/** The provider token APNs expects: an ES256 JWT, valid for an hour (reused for 50 minutes). */
export function apnsJwt(key: KeyObject, keyId: string, teamId: string, now = Math.floor(Date.now() / 1000)): string {
  const head = b64url(JSON.stringify({ alg: 'ES256', kid: keyId }));
  const claims = b64url(JSON.stringify({ iss: teamId, iat: now }));
  const sig = sign('sha256', Buffer.from(`${head}.${claims}`), { key, dsaEncoding: 'ieee-p1363' });
  return `${head}.${claims}.${b64url(sig)}`;
}

export class Apns {
  private key: KeyObject;
  private token = { jwt: '', at: 0 };
  private sessions = new Map<ApnsEnv, http2.ClientHttp2Session>();
  private cfg: ApnsConfig;
  private log: (m: string) => void;

  constructor(cfg: ApnsConfig, log: (m: string) => void) {
    this.cfg = cfg;
    this.log = log;
    this.key = createPrivateKey(readFileSync(cfg.keyFile));
  }

  private jwt(): string {
    const now = Math.floor(Date.now() / 1000);
    if (!this.token.jwt || now - this.token.at > 50 * 60) this.token = { jwt: apnsJwt(this.key, this.cfg.keyId, this.cfg.teamId, now), at: now };
    return this.token.jwt;
  }

  private session(env: ApnsEnv): http2.ClientHttp2Session {
    let s = this.sessions.get(env);
    if (!s || s.closed || s.destroyed) {
      s = http2.connect(env === 'production' ? 'https://api.push.apple.com' : 'https://api.sandbox.push.apple.com');
      s.on('error', (e) => this.log(`apns ${env}: ${e.message}`));
      s.on('close', () => this.sessions.delete(env));
      this.sessions.set(env, s);
    }
    return s;
  }

  /** One Live Activity push (start, update or end). Priority 10 is immediate and budgeted; 5 is opportunistic. */
  liveActivity(token: string, env: ApnsEnv, payload: object, priority: 5 | 10): Promise<{ status: number; reason?: string }> {
    return new Promise((resolve) => {
      const req = this.session(env).request({
        ':method': 'POST',
        ':path': `/3/device/${token}`,
        authorization: `bearer ${this.jwt()}`,
        'apns-topic': `${this.cfg.bundleId}.push-type.liveactivity`,
        'apns-push-type': 'liveactivity',
        'apns-priority': String(priority),
        'content-type': 'application/json',
      });
      let status = 0;
      let body = '';
      req.on('response', (h) => (status = Number(h[':status'])));
      req.on('data', (d) => (body += d));
      req.on('end', () => {
        let reason: string | undefined;
        try { reason = body ? (JSON.parse(body) as { reason?: string }).reason : undefined; } catch { reason = body.slice(0, 200); }
        resolve({ status, reason });
      });
      req.on('error', (e) => resolve({ status: 0, reason: e.message }));
      req.setTimeout(10_000, () => {
        req.close();
        resolve({ status: 0, reason: 'timeout' });
      });
      req.end(JSON.stringify(payload));
    });
  }

  close(): void {
    for (const s of this.sessions.values()) s.close();
  }
}
