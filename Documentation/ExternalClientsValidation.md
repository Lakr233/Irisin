# External clients: device validation for 4.7.0

What was run on devices before 4.7.0 was published, and what was not. The
contract is `ExternalClients.md`; the Mac harness (`make harness`) covers the
same rules without a device.

## Devices

| | A | B |
|---|---|---|
| Kind | vphone, iPhone layout | vphone, iPad layout |
| iOS | 26.6.2 | 27.0.1 |
| Bootstrap | RootHide | RootHide |
| Irisin | 4.7.0, installed over 4.6.3 | 4.7.0, installed over 4.6.3 |
| Also installed | ElleKit 1.2-1 | ElleKit 1.2-1, Apelin 0.1.0 (a live external client) |

**Rootless was not tested**: no rootless device was available. The rootless
package was built and verified (`verify-deb.sh`, floor audit, floor imports)
and nothing more.

## The client

A small command-line client built from `Packages/IrisinExternalClient`
alone, signed with `wiki.qaq.irisin.client`, `platform-application` and
`com.apple.private.security.no-sandbox`, installed root-owned 0755 in the
bootstrap's `/usr/libexec`, and run as root. Test packages were made with
`dpkg-deb --root-owner-group`, each with a `postinst` that writes a file, so
a run shows the maintainer script ran. All of it, and every transaction
record it made, was removed afterwards.

## Results

| Case | A | B |
|---|---|---|
| `serviceInfo`: `xv` 1, five capabilities, the install root, as root and as mobile | pass | pass |
| `submitInstall` by descriptor: installed, `postinst` ran, `package` / `pkgver` recorded, the copy and prepared tree gone afterwards | pass | pass |
| Same id and package again: `dup=true`, the same record, nothing run | pass | pass |
| Same id, another package: `conflict`; same id as a removal: `conflict` | pass | pass |
| Digest mismatch: `failed`, `installationStopped`, nothing installed | pass | pass |
| Another bootstrap's architecture (`iphoneos-arm64`): refused | pass | pass |
| A `wiki.qaq.irisin*` package: refused | pass | pass |
| A missing dependency: refused while verifying, nothing written | pass | pass |
| Upgrade 1.0 → 1.1 through `submitInstall`, `postinst` ran as `configure` | pass | pass |
| `transactionEvents` paged (5 at a time, then from a sequence), by a new client process | pass | pass |
| Records read back after irisind was killed (SIGKILL) and started again on demand | pass | pass |
| irisind killed mid-install: the helper finished, a new client followed from sequence 3 to `exit 0` | pass | pass |
| `transactionStatus` for an unknown id: `notFound` | pass | pass |
| `removePackage` of a package another one depends on: refused, nothing removed | pass | pass |
| `removePackage` of an essential package (`dash`): refused | pass | pass |
| `removePackage` of a package that is not installed: `packageFailed` | pass | pass |
| `removePackage` of `wiki.qaq.irisin`: `invalidRequest` at the request | pass | pass |
| `removePackage` of the dependent, then the dependency: both removed | pass | pass |
| Same removal id again: `dup=true` | pass | pass |
| `respring`: `succeeded`, SpringBoard restarted (new pid on B) | pass | pass |
| Records directory made as `root:wheel 0700` under `<root>/var/lib/irisin`, files `0600` (`package.json` `0644` inside it) | pass | pass |

Admission, each refused, with irisind's log line:

| Client copy | Logged reason | A | B |
|---|---|---|---|
| root-owned 0755, in a mobile-owned directory under the bootstrap's `/var/mobile` | `untrustedDirectory(<root>/var/mobile)` | pass | pass |
| mobile-owned 0755 there | `untrustedFile` | pass | pass |
| root-owned 0775 in `/usr/libexec` | `untrustedFile` | pass | pass |
| root-owned 0755 in `/usr/libexec`, signed without `wiki.qaq.irisin.client` | `lacks a client entitlement` | pass | pass |
| root-owned 0755 on the data volume outside the bootstrap (`/private/var/tmp`) | `outsideTrustedPlaces` | pass | pass |
| a link in `/usr/libexec` to that copy | `outsideTrustedPlaces` (judged where it leads) | pass | pass |
| the signed client in `/usr/libexec` | admitted | pass | pass |

A refused client sees `XPC_ERROR_CONNECTION_INTERRUPTED` on each request,
the same as a daemon going away; `ExternalClients.md` says so.

Ownership the wider rule depends on, as found on both: the jbroot
`root:_installd 0755`, its parent `_installd 0755`, the bootstrap's
`/usr/libexec` `root:_installd 0755`, `/var/lib` `root:wheel 0755`.

## Irisin's own app

Admitted as before, by its own path, on both:

| Case | A | B |
|---|---|---|
| Launch, repositories refreshed | pass | pass |
| Update a package from a repository (fastfetch 2.69.0 → 2.70.0) | pass | pass |
| Install with dependencies (jq with libjq1 and libonig5) | — | pass |
| Remove with its no-longer-needed dependencies ticked | — | pass |
| Remove a package a meta-package depends on (the meta-package goes with it), then install the meta-package again, which brings it back | pass | — |

B also had Apelin's own session host installing through these operations
during the run, alongside the test client.
