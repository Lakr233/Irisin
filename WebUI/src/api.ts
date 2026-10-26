// The device's calls, sealed the way Packages/IrisinWeb/README.md says: the
// key from the code and the start's salt, every call and answer and stream
// frame ChaCha20-Poly1305 with associated data naming what it is.
import Cipher from './cipher';

const utf8 = Cipher.utf8Encode;
const KEY_INFO = utf8('irisin-web/1 key');

/** The call did not open on the device: a wrong code, or a new start. */
export class Unauthorized extends Error {}
/** The device did not answer at all. */
export class Offline extends Error {}
/** The device answered `ok: false`, with why in its own words. */
export class Refused extends Error {}

export interface Hello {
  version: number;
  salt: string;
}

export async function hello(): Promise<Hello> {
  let response: Response;
  try {
    response = await fetch('/api/v1/hello', { cache: 'no-store' });
  } catch {
    throw new Offline();
  }
  if (!response.ok) throw new Offline();
  return response.json();
}

export function deriveKey(code: string, salt: string): Uint8Array {
  const saltBytes = Cipher.base64Decode(salt);
  if (!saltBytes) throw new Offline();
  return Cipher.hkdfSHA256(utf8(code), saltBytes, KEY_INFO, 32);
}

/** The key as the page keeps it between loads of one start. */
export function encodeKey(key: Uint8Array): string {
  return Cipher.base64Encode(key);
}

export function decodeKey(text: string): Uint8Array | null {
  const key = Cipher.base64Decode(text);
  return key && key.length === 32 ? key : null;
}

interface Envelope {
  n: string;
  c: string;
}

function nonce(): Uint8Array {
  const bytes = new Uint8Array(12);
  crypto.getRandomValues(bytes);
  return bytes;
}

function seal(key: Uint8Array, purpose: string, value: unknown): Envelope {
  const n = nonce();
  const sealed = Cipher.seal(key, n, utf8(JSON.stringify(value)), utf8(purpose));
  return { n: Cipher.base64Encode(n), c: Cipher.base64Encode(sealed) };
}

function open<T>(key: Uint8Array, envelope: Envelope, purpose: string): T {
  const n = Cipher.base64Decode(envelope.n);
  const c = Cipher.base64Decode(envelope.c);
  const plain = n && c ? Cipher.open(key, n, c, utf8(purpose)) : null;
  if (!plain) throw new Unauthorized();
  return JSON.parse(Cipher.utf8Decode(plain)) as T;
}

async function post(path: string, body: Envelope, signal?: AbortSignal): Promise<Response> {
  let response: Response;
  try {
    response = await fetch(path, {
      method: 'POST',
      body: JSON.stringify(body),
      headers: { 'Content-Type': 'application/json' },
      cache: 'no-store',
      signal,
    });
  } catch (error) {
    if (signal?.aborted) throw error;
    throw new Offline();
  }
  if (response.status === 403) throw new Unauthorized();
  if (!response.ok) throw new Offline();
  return response;
}

export async function call<T>(key: Uint8Array, op: string, args: object = {}): Promise<T> {
  const envelope = seal(key, 'irisin-web/1 call', { op, args });
  const response = await post('/api/v1/call', envelope);
  const answer = open<{ ok: boolean; result?: T; error?: string }>(
    key,
    await response.json(),
    `irisin-web/1 answer ${envelope.n}`,
  );
  if (!answer.ok) throw new Refused(answer.error ?? '');
  return answer.result as T;
}

export interface Frame {
  seq: number;
  line?: string;
  package?: string;
  step?: string;
  progress?: { completed: number; total: number };
  end?: boolean;
  succeeded?: boolean;
  status?: number;
}

/** Hands each frame after `after` to `onFrame` until the stream ends. */
export async function stream(
  key: Uint8Array,
  after: number,
  onFrame: (frame: Frame) => void,
  signal: AbortSignal,
): Promise<void> {
  const envelope = seal(key, 'irisin-web/1 stream', { after });
  const response = await post('/api/v1/stream', envelope, signal);
  if (!response.body) throw new Offline();
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = '';
  let index = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    let newline: number;
    while ((newline = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, newline);
      buffer = buffer.slice(newline + 1);
      if (!line) continue;
      index += 1;
      onFrame(open<Frame>(key, JSON.parse(line), `irisin-web/1 frame ${envelope.n} ${index}`));
    }
  }
}

// What the calls answer (Packages/IrisinWeb/README.md, Calls).

export interface Device {
  name: string;
  model: string;
  system: string;
  bootstrap: string;
  architecture: string;
  irisinVersion: string;
  freeSpace: number;
  busy: boolean;
}

export interface Repository {
  url: string;
  name: string;
  packageCount: number;
  refreshed: string | null;
  refreshing: boolean;
  problem: string | null;
}

export interface SearchRow {
  id: string;
  name: string;
  version: string;
  section: string;
  summary: string;
  repository: string;
  installed: string | null;
}

export interface PackageDetail {
  id: string;
  name: string;
  version: string;
  versions: string[];
  section: string;
  author: string;
  maintainer: string;
  summary: string;
  description: string;
  depends: string;
  repository: string;
  installed: string | null;
  size: number;
  installedSize: number;
  homepage: string | null;
}

export interface InstalledRow {
  id: string;
  name: string;
  version: string;
  section: string;
}

export interface UpdateRow {
  id: string;
  name: string;
  installed: string;
  available: string;
  repository: string;
}

export interface Plan {
  id: string;
  install: { id: string; name: string; version: string; repository: string; size: number }[];
  remove: { id: string; name: string; version: string }[];
  downloadSize: number;
  notes: string[];
}

export interface Request {
  id: string;
  state: 'asking' | 'declined' | 'running' | 'done' | 'failed';
  detail: string | null;
}
