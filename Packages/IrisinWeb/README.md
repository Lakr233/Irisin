# IrisinWeb

Managing a device from a browser on the local network: the server, the key,
the sealed envelope and the page. Why it is shaped this way is
`Documentation/WebManagement.md`; this is the contract the page and the
device's responder (`WebResponder`) both keep.

## Keys and envelopes

1. The device shows a six-digit code and `http://<address>:<port>/#<code>`.
2. The page takes the code from `location.hash` (then clears the hash) or
   asks for it, fetches `GET /api/v1/hello` → `{"version": 1, "salt": "<base64>"}`,
   and derives the key: `hkdfSHA256(utf8(code), salt, utf8("irisin-web/1 key"), 32)`.
   It keeps `{salt, key}` in `localStorage`; a hello with another salt is a
   new start, and the stored key is dropped.
3. Every call is `POST /api/v1/call` with the body `{"n": "<base64 nonce>",
   "c": "<base64 ciphertext and tag>"}`: ChaCha20-Poly1305 under the key, a
   fresh 12-byte nonce (`crypto.getRandomValues`), associated data
   `irisin-web/1 call`, plaintext `{"op": "<name>", "args": {...}}`.
   The answer is the same shape, associated data `irisin-web/1 answer <n>`
   (the call's own `n`, as sent), plaintext `{"ok": true, "result": ...}` or
   `{"ok": false, "error": "<text, in the device's language>"}`.
   A call that does not open, or repeats a nonce, is answered 403 and
   nothing else: to the page that means the code is wrong or the device
   has started again with a new one.
4. An operation's lines are `POST /api/v1/stream`, body sealed with
   associated data `irisin-web/1 stream`, plaintext `{"after": <sequence>}`.
   The answer is `application/x-ndjson`: one envelope a line, line *i*
   (from 1) sealed with `irisin-web/1 frame <n> <i>`; it ends when the
   operation does or the device closes it.
5. `GET /api/v1/strings` → `{"<name>": "<text>"}`: every word the page
   shows, in the device's language, in the clear. The page has no text of
   its own but the fallback for a missing name, which is the name itself.

## Calls

Identifiers are package ids (`com.example.tweak`) and repository URLs.
Sizes are bytes; dates are ISO 8601 or null.

| op | args | result |
| --- | --- | --- |
| `device` | | `{name, model, system, bootstrap, architecture, irisinVersion, freeSpace, busy}`: `system` reads like "iOS 27.0.1", `busy` is whether an operation is running |
| `repositories` | | `[{url, name, packageCount, refreshed, refreshing, problem}]` |
| `refresh` | | `{}`: every repository starts refreshing; `repositories` shows how far |
| `addRepository` | `{url}` | a request (below) |
| `removeRepository` | `{url}` | a request |
| `search` | `{query, limit}` | `[{id, name, version, section, summary, repository, installed}]`, ranked as the app ranks it; `installed` is the installed version or null |
| `package` | `{id}` | `{id, name, version, versions, section, author, maintainer, summary, description, depends, repository, installed, size, installedSize, homepage}`; `versions` lists what the repositories offer, newest first; `depends` is the raw field |
| `installed` | | `[{id, name, version, section}]` |
| `updates` | | `[{id, name, installed, available, repository}]` |
| `propose` | `{install: [{id, version}], remove: [id], updateAll}` (each optional; `version` null for the newest) | the plan below, or `ok: false` with why it cannot be done |
| `plan` | | the queue's plan, or null |
| `clear` | | `{}` |
| `confirm` | `{plan}` (the plan's id) | a request: the device asks its owner to run that plan |
| `respring` | | a request |
| `request` | `{id}` | `{id, state, detail}`: `state` is `asking`, `declined`, `running`, `done` or `failed`; `detail` says why, in words, or null |

A plan is `{id, install: [{id, name, version, repository, size}], remove:
[{id, name, version}], downloadSize, notes}`; `notes` are what the resolver
said beside it, in words.

A request answers at once with `{id, state: "asking"}`: every change waits
for the owner's yes on the device (Face ID or the passcode on iOS, the
remote on Apple TV), however long that takes. The page polls `request`
about once a second until the state is no longer `asking` or `running`.
A confirmed plan becomes the operation whose lines `stream` carries.

## Stream frames

`{seq, line}` for each line of the transcript as the device spells it;
`{seq, package, step}` when a package reaches a step (`verifying`,
`removing`, `unpacking`, `configuring`, `triggering`, `done`, `failed`);
`{seq, progress: {completed, total}}`; and last `{seq, end: true,
succeeded, status}`. `after` is the last `seq` the page has, so a page that
reconnects misses nothing; with no operation running, the last one's frames
are sent and the stream ends.
