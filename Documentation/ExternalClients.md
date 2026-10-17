# External clients

From 4.7, `irisind` serves programs other than Irisin's own app: another
package's root process (Apelin's session host first) installs a `.deb`,
removes a package, resprings, and follows each as a transaction. This is the
contract, and `Packages/IrisinExternalClient` is its client: system libraries
only, no dependency on the rest of Irisin, meant to be vendored (the two
folders under `Sources/`, with this repository's `LICENSE` beside them) into a
process that takes nothing third-party.

## Trust model

Admission (`IrisinDaemon/PeerAuthenticator.swift`,
`IrisinProtocol/Wire/ExecutableAdmission.swift`) runs before the first request
field is read, on the kernel's audit token:

1. pid above 1; effective uid 0 (root) or 501 (mobile).
2. Three entitlements, each a boolean `true`:
   `wiki.qaq.irisin.client`, `platform-application`,
   `com.apple.private.security.no-sandbox`.
3. The executable `proc_pidpath` names, canonicalised with `realpath(3)` (a
   NUL refused before anything is resolved), is admitted when
   - it lies inside the daemon's install root, compared component by
     component (`/var/jb2` is not inside `/var/jb`), and every directory from
     the install root itself down to the file's own is a real directory owned
     by root or a system account (uid below 500) and writable by neither group
     nor others; or
   - it is on the volume mounted at `/`, and that volume is mounted read-only
     (iOS's sealed system volume);

   and the file is regular, owned by root, executable by its owner and
   writable by neither group nor others. Irisin's own app is also admitted by
   its pre-4.7 rule, its exact path and a root-owned file, so a bootstrap
   whose directories the wider rule distrusts cannot lock Irisin out of its
   own daemon.

What this means:

- **Irisin trusts every installed package that meets these checks, not Apelin
  alone.** A package that can install, sign itself and leave a root-owned
  executable in a root-owned directory is already a trusted participant of
  the system; this admits it as one.
- **The entitlement is eligibility, not identity.** Any installed package can
  sign a program with `wiki.qaq.irisin.client`; it says the program means to
  be a client and nothing about which package it came from. Installed
  packages are not isolated from one another here, and nothing on this wire
  should be read as if they were. Isolating them would need an identity a
  package cannot declare for itself, which is a new decision, not a new
  entitlement name.
- A client's own approval (Apelin's Confirm mode, for one) protects the work
  that goes through that client. It does not stop another program with the
  same standing from calling irisind directly, and a malicious installed
  package, root, or a tampered Irisin are outside what any of these checks
  can defend against.
- What the path rule does stop: a mobile process placing or swapping a binary
  where it would be admitted. mobile's own home is inside the install root on
  roothide (`<jbroot>/var/mobile`), and is refused because mobile owns it.

## Transport

The Mach service `wiki.qaq.irisin.service`, on-demand: looking it up starts
the daemon, which exits about three seconds after its last client leaves.
A client connects with `xpc_connection_create_mach_service(name, queue, 0)`
and sends each request with `xpc_connection_send_message_with_reply`.
A refused program learns nothing about why: the daemon cancels the peer
connection, and on a device every request on it then fails with
`XPC_ERROR_CONNECTION_INTERRUPTED`, the same error a daemon that went away
(idle exit, or Irisin updating itself) gives. `XPC_ERROR_CONNECTION_INVALID`
means no such service. So a client asks again for a while, and if every
attempt is interrupted it reads irisind's log, where each refusal is one
line with its reason (`peer rejected: <path> untrustedDirectory(...)`,
`untrustedFile`, `outsideTrustedPlaces`, `lacks a client entitlement`). No
state is lost to an interruption: transactions live on disk.

Every request is a dictionary with:

| key  | type   | value |
|------|--------|-------|
| `v`  | uint64 | `3`, the base protocol version. Anything else is `invalidRequest`. |
| `op` | uint64 | the operation, below |

Every reply carries `v` (uint64, 3) and `code` (int64). When `code` is not 0
it also carries `errno` (int64, 0 when the refusal was the daemon's own) and
may carry `path` (string).

| `code` | name | meaning |
|---|---|---|
| 0 | success | |
| 1 | invalidRequest | malformed request, unknown operation, a field out of range. An Irisin before 4.7 answers every external operation with this. |
| 2 | notPermitted | the daemon could not use its own records directory |
| 3 | notFound | no such transaction |
| 4 | operationFailed | anything else; `errno` says what |
| 5 | conflict | the transaction id is taken by a different request, or by a record that was never completed |

## Transactions

Every operation that changes something runs under a **transaction id the
client chooses**: a UUID spelled lowercase, `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`
(36 characters, hexadecimal `0-9a-f`). Choosing it is what makes a submission
safe to repeat: a client that lost the reply submits again with the same id
and gets the same transaction back, marked `dup`, and nothing runs twice. The
same id with a different request is `conflict`.

A transaction is a directory, `<install root>/var/lib/irisin/transactions/<id>/`,
root's and mode 0700, holding the request, the helper's journal (one event per
line) and, for an install, what the package turned out to be. The daemon
keeps nothing in memory: a restarted daemon or a reconnecting client reads the
same directory. A finished record is removed a week after its last event, the
next time a transaction starts.

States:

| `state` | meaning |
|---|---|
| `running` | the helper holds the journal and has not written its exit |
| `succeeded` | the journal ends with exit status 0 |
| `failed` | the journal ends with a non-zero exit status |
| `interrupted` | no exit, and no process holds the journal: the helper died or the device restarted mid-run. What it changed is in the events. |

The helper runs in a session of its own and finishes whether or not the
client, or the daemon, is still there.

### Transaction status fields

`submitInstall`, `removePackage`, `respring`, `transactionStatus` and
`transactionEvents` replies all carry:

| key | type | |
|---|---|---|
| `txid` | string | the transaction id |
| `kind` | string | `install`, `remove` or `respring` |
| `state` | string | above |
| `next` | uint64 | one more than the last event's sequence number |
| `exit` | int64 | the helper's exit status, once there is one |
| `package` | string | the package id: the one asked to be removed, or the one an install's control file named, once read |
| `pkgver` | string | an install's version, once read |
| `failure` | string | the last failure's problem name (below), when there was one |
| `failtext` | string | that failure in English plain text |

## Operations

### `serviceInfo` (op 4)

Request: nothing else.

Reply: `xv` (uint64, the external protocol version, currently 1), `caps` (array
of strings: `submitInstall`, `transactionStatus`, `transactionEvents`,
`removePackage`, `respring`), `root` (string, the install root the daemon
derived from its own path). `invalidRequest` here means an Irisin older than
4.7: the client should say which Irisin it needs.

`xv` changes when an operation's shape changes; a new operation is a new
capability, not a new version.

### `submitInstall` (op 5)

| key | type | |
|---|---|---|
| `txid` | string | the transaction id |
| `fd` | file descriptor (`xpc_dictionary_set_fd`) | the `.deb`, a regular file, 1 byte to 4 GiB |
| `sha256` | string | SHA-256 of the whole file, 64 lowercase hexadecimal digits |

Reply: the status fields, and `dup` (bool).

The daemon checks the descriptor is a regular file of an acceptable size, makes
the transaction's directory and starts `irisin-install` with the descriptor as
its descriptor 3. The helper copies the file from offset 0 into the directory
(a new file, never through a link), hashing as it copies, and from then on
reads only the copy: what the client does to its own file afterwards changes
nothing. The copy must hash to `sha256` — the digest the client's own approval
is bound to — or nothing is installed. The copy is then prepared, verified
and installed as any package Irisin installs, and removed when the run ends.

There is no dependency resolution: a package whose dependencies are not
installed fails while verifying, before anything is written. The package's
`Architecture` must be `all` or the bootstrap's own (`iphoneos-arm64e` on
roothide, `iphoneos-arm64` on rootless). Irisin's own packages
(`wiki.qaq.irisin*`) are refused. Maintainer scripts run as they do for any
install. The installed apps are registered with the home screen as in any
transaction.

### `removePackage` (op 8)

| key | type | |
|---|---|---|
| `txid` | string | the transaction id |
| `package` | string | the package id: lowercase `a-z 0-9 + - .`, 2 to 256 characters, starting with a letter or digit |

Reply: the status fields, and `dup`.

Removes that one package. Nothing that depends on it is removed with it: such
a removal fails before anything is written, as does removing a package that
is essential, protected or held, one that is not installed, or one of
Irisin's own.

### `respring` (op 9)

| key | type | |
|---|---|---|
| `txid` | string | the transaction id |

Reply: the status fields, and `dup`. The helper asks SpringBoard to restart
gracefully and signals backboardd if it refuses.

### `transactionStatus` (op 6)

| key | type | |
|---|---|---|
| `txid` | string | |

Reply: the status fields. `notFound` for an id with no record.

### `transactionEvents` (op 7)

| key | type | |
|---|---|---|
| `txid` | string | |
| `after` | uint64 | return events with a sequence number above this; 0 for all |
| `limit` | uint64 | at most this many; 0 or above 256 means 256 |

Reply: the status fields and `events`, an array of dictionaries in order:

| key | type | present |
|---|---|---|
| `seq` | uint64 | always; the first event is 1, numbers never repeat or skip |
| `kind` | string | always: `started`, `phase`, `progress`, `package`, `packageProgress`, `script`, `output`, `notice`, `warning`, `failure`, `exit` |
| `text` | string | always: the event in English plain text, as Irisin's log has it |
| `raw` | string | always: Irisin's own JSON line for the event. Its shape is Irisin's and may change in any release; the other keys do not. |
| `phase` | string | `phase`: `preparing`, `verifying`, `applying`, `processingTriggers`, `registeringApplications`, `completed` |
| `step` | string | `package`: `verifying`, `removing`, `unpacking`, `configuring`, `triggering` |
| `package` | string | `package`, `packageProgress`, `script` |
| `pkgver` | string | `package` (empty while verifying) |
| `done`, `total` | int64 | `progress` (package steps), `packageProgress` (files) |
| `exit` | int64 | `exit` |
| `failure` | string | `warning`, `failure`: the problem name |

Problem names: `invalidJob`, `helperMisplaced`, `installationStopped`,
`packageFailed`, `scriptFailed`, `scriptFailureIgnored`,
`homeScreenNeedsAttention`, `registrationFailed`, `unregistrationFailed`,
`leftoverBundle`, `refreshFailed`, `daemonNotLoaded`, `noProcess`,
`packageNeedsRepair`, `markingsNotSaved`, `helperUnreachable`. A failure
before the package was identified (the digest did not match, the archive
could not be read, the architecture is another bootstrap's) is
`installationStopped` with the reason in its text.

`exit` is always the last event. `phase` `completed` comes before an exit of 0
and nothing else. A line the helper is still writing is not returned until it
is complete.

To follow a transaction, ask with `after` set to the last sequence number
received, every quarter second or so, until `state` is not `running` and
`next - 1` has been received. A client that reconnects (or restarts) asks
again from its last sequence number; replay is exact.

## The client library

```swift
let irisin = IrisinExternalClient()
let info = try await irisin.serviceInfo()            // .serviceTooOld before 4.7
let id = UUID()                                        // keep it with the request
let digest = try IrisinExternalClient.sha256(ofDescriptor: fd)
var status = try await irisin.submitInstall(transaction: id, packageDescriptor: fd, sha256: digest)
for try await event in irisin.follow(id) { /* event.kind, event.text, ... */ }
status = try await irisin.status(of: id)              // .succeeded / .failed / .interrupted
```

`IrisinClientError.Code` adds to the reply codes: `serviceUnavailable` (no
such service), `connectionInterrupted` (the daemon went away, or refused this
program: on a device the two look the same),
`serviceTooOld` and `malformedReply`. `follow` retries a dropped connection for
about a minute, so a daemon replaced mid-run loses nothing.

`Tests/IrisinExternalContractTests` in IrisinKit holds the library's
constants to `IrisinProtocol`'s.

## A client's own package

The program needs, in its own entitlements, `wiki.qaq.irisin.client`,
`platform-application` and `com.apple.private.security.no-sandbox`, all
`true`; it must be installed root-owned and not group- or world-writable, in
root-owned directories that no one else can write, inside the bootstrap. Its
package should depend on `wiki.qaq.irisin (>= 4.7.0)`.
