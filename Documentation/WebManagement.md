# Managing from a browser

Designed for 5.1.0 after three rounds of review and the owner's decisions
of 2026-10-26, and built for the launchpad (Apple TV, Vision Pro) the same
day; the iOS app's switch is still to come. A device running Irisin serves
a page on the local network, and a browser on another device (Safari on an
iPhone first) manages it: repositories, search, install, remove, update,
the operation as it runs, and the data Irisin keeps. On Apple TV and Vision
Pro it is the only interface Irisin has; on iPhone and iPad it will be a
second one, beside the app.

## The shape

```
browser ──HTTP/LAN──▶ Irisin (the app on iOS, the launcher on tvOS) ──XPC──▶ irisind ──▶ irisin-install
                      catalogue, resolver, downloads, preparation
```

The page is a front end. What a change needs (the catalogue, the
resolver, the downloaded `.deb` and the prepared tree the helper installs
from) is on the device, so the server is the process that already has all
of it: Irisin. It sends the daemon the `InstallerJob`s the app sends,
through `PrivilegedBackend`, and the network never carries a job: it
carries what a person asked for, which the device resolves, shows,
confirms and runs.

A bridge putting the daemon's XPC on the network was set aside: a job names
prepared trees on the device, so a remote client would need the device's
files to make one, and a root service that takes jobs from the network is
root for whoever reaches it.

## Trust

The server runs in the one mobile process irisind trusts with every
`InstallerJob`, so whoever drives the page drives root. The owner chose a
light design for it: nobody turns this on but to use it at once, an iPhone
rarely, and an Apple TV holds little of anyone's data.

1. **Every change is the device owner's yes, on the device, always.** An
   install, removal, update, a repository added or removed, a respring: the
   device shows the plan (each package, its version and repository) and
   goes ahead only on the owner's answer there: Face ID, Touch ID or the
   passcode on iOS, a passcode-less iPhone's tap, the remote on Apple TV
   with Decline focused first. This holds whatever the app's own "Confirm
   with Face ID" setting says. The answer is bound to the plan's id; a plan
   that changed since it was shown is asked again.
2. **No pairing; a code each time.** When the server starts (iOS: Manage
   from a Browser switched on, the app in front; tvOS: the launcher open),
   the device makes a fresh six-digit code and shows it, with a QR code of
   the address and the code in the URL's fragment
   (`http://<address>:<port>/#<code>`), which a browser never sends. The
   page reads the code from the fragment or asks for it, derives a key from
   it and the server's salt for this start (HKDF-SHA256: the code stretched
   to a key's length, no more), and keeps
   the key in its own storage for that start, so a reload needs no code.
   The code and the key never cross the network.
3. **Everything after the page itself is sealed.** Each request and each
   answer, and each line of an operation's stream, is ChaCha20-Poly1305
   under that key, with a fresh nonce and a sequence the other side checks.
   What does not open is dropped without an answer. The page, its script and
   its words are served in the clear: nothing in them is secret.
4. **What this does not stop, said plainly.** Six digits are a million
   codes: someone who recorded the traffic can try them all offline in
   moments. Someone who can change the traffic can do more: the page and
   its script travel in the clear, so they can serve a script of their own
   that reads the code from the URL as the browser opens it. Either way
   they would then read what the page reads; they still cannot change
   anything without the owner's yes on the device, which shows the plan
   itself, and the code is new each time the server starts.
5. **Small, careful defaults, and no more.** A repository's text is set
   as text, never as markup, under a Content-Security-Policy that allows the
   page's own script alone, since a script injected into the page could read
   the key. Requests have size limits and timeouts. The listener uses Wi-Fi
   and Ethernet, never cellular. iOS asks before an app listens on the local
   network: `NSLocalNetworkUsageDescription`, in `InfoPlist.xcstrings`.

## Where it runs

- **iOS:** inside the app, switched on in Settings, off by default. It
  serves while the app is in the foreground, and keeps the screen awake
  while a browser is connected; in the background it stops serving. iOS
  asks before an app listens on the local network:
  `NSLocalNetworkUsageDescription`, in `InfoPlist.xcstrings`.
- **tvOS and visionOS:** the launchpad, the `IrisinLaunchpad` target,
  product `irisin` at `/Applications/irisin.app`, built from `IrisinShared/`
  (the services both apps compile) with an application delegate and one
  screen of its own: the QR code, the address and the code under it, a
  line when something is running, and the owner's answers as the system's
  alert, Decline its preferred and cancel action. Every line is one size,
  told apart by weight and opacity alone, with one gap between all of
  them; on Vision Pro the window is the size of what it shows. It serves
  while it is in front, with a new code each time it comes back, and keeps
  the screen from sleeping. irisind admits it as mobile by the exact-path rule iOS's app has
  (`IrisinWire.clientPaths`, the same path on tvOS now), and
  `PackagedArchitecture` takes `appletvos-arm64e` on tvOS, the simulator's
  stand-in root included. The tvOS package is the daemon, the helper and
  the launchpad; on its first launch with no repositories it adds the
  recommended list (apt.owngoal.dev), which nobody is at a screen to pick.
  No bootstrap serves Vision Pro yet: the launchpad there browses, and
  installs only in the simulator.

## The run without a view controller

The run from a proposal to its end lives in the app's interface
(`QueueController`, `OperationController+Completion`), but every step of it
is a service: `PackageQueue` proposes and commits, `Downloads` fetches,
`Installer` stages and begins, `OperationMonitor` follows. `WebRun`
composes the same services for a browser's plan, without moving the app's
pages: the owner's yes, the downloads (`Downloads.awaitFiles`, which the
queue page waits on too), on a system with no dpkg Bootstrap Install where
the plan allows it or else the owner hears which packages run scripts
(`QueueInstallChecks`), staging, the run, and the end: an update of Irisin
registers it and leaves (`OwnRegistration.request`), and changed tweaks
say the home screen should reload. The app showing an operation the web
started, as it shows its own, comes with the iOS switch.

The server also needs the helper's transcript not to stall: a suspended
reader would let the pipe fill and the helper block holding dpkg's lock.
The helper's standard output becomes non-blocking, and a line the pipe
cannot take now goes to the log alone, as it already does when the reader
has gone.

## The page

One page, minimal: no green dots, no badges, no pill-shaped buttons or
chips. Text, rules, one accent colour, the system font stack, light and
dark from `prefers-color-scheme`, Safari on iPhone first.

| view | what it shows | what it can do |
| --- | --- | --- |
| Device | name, system, bootstrap, Irisin's version, free space | respring |
| Repositories | each with its package count and last refresh | add by URL, remove, refresh |
| Search | the catalogue's search, ranked as the app ranks it | open a package |
| Package | name, version, section, author, description, depends, repository, installed version | install, update, remove, choose a version |
| Updates | what the Updates page lists | update one, update all |
| Installed | what dpkg reports | remove |
| Queue | the plan: installs, removals, sizes | send to the device for confirmation, clear |
| Operation | each package's step, the transcript, the result | close |

Not in 5.1.0: depictions beyond the description, paid repositories,
translation, settings. A package from a repository that needs a sign-in
says so and points at the device.

## Words

The page's words are its own, as Fila's are: `WebUI/src/i18n.ts`, English
and Chinese, chosen by the browser's language, using the app's terms (卸载,
重新载入主屏幕). What the device or a repository writes (names,
descriptions, a failure's reason, an operation's lines as
`InstallerEvent+Console` spells them) arrives spelled and is shown as it is.
Custom firmware, never jailbreak.

## The interface between them

Sealed JSON over HTTP. A call is one `POST /api/v1/call` whose body is a
sealed `{op, args}` and whose answer is a sealed result; an operation's
lines arrive on a streamed `fetch` of `POST /api/v1/stream`, one sealed
frame per line with its sequence number, and a page that reconnects asks
from the last number it has. No framework on either side: the server is
`Network.framework` with CryptoKit; the page is `WebUI/`, React and
TypeScript built with webpack and pnpm, the toolchain Fila's page has.
WebCrypto is not offered to a page served over plain HTTP, so the page
carries its own `cipher.js` (SHA-256, HMAC, HKDF, ChaCha20-Poly1305, a few
hundred lines, no dependency), checked on the Mac against the RFCs' vectors
and byte for byte against CryptoKit.

| | |
| --- | --- |
| `GET /`, `/_irisin/<name>` | the page (`index.html`, `app.js`, `app.css`, its icons), in the clear |
| `GET /api/v1/hello` | the salt for this start, in the clear |
| `POST /api/v1/call` | sealed: `device`, `repositories`, `addRepository`, `removeRepository`, `refresh`, `search`, `package`, `installed`, `updates`, `propose` (install, remove, update all; answers the plan and its id), `clear`, `confirm` (asks the owner for that plan id; answers at once) |
| `POST /api/v1/stream` | sealed frames: the running or last operation's lines, from a sequence number, until its end |

Every answer is `Cache-Control: no-store`.

## How it is built

- `Packages/IrisinWeb`: the HTTP server, the code, the key and the sealed
  envelope, routing and the limits, with no UIKit and nothing outside the
  system, tested on the Mac against the page's own cipher code. It serves
  the page from the folder it is handed.
- `WebUI/`: the page, as Fila's: `Scripts/build-webui.sh` installs it with
  pnpm and builds it with webpack, the app's Build Web UI phase copies
  `dist/` into `irisin.app/WebUI`, and `Scripts/collect-licenses.py` lists
  its runtime dependencies (React) with the app's. `IRISIN_WEB_DEMO=1 swift
  test --package-path Packages/IrisinWeb --filter WebUIDemo` serves it on
  the Mac with made-up answers.
- `IrisinShared/Services/WebManagement`: the server's start and stop and
  the owner's questions (`WebManagement`), the calls bound to the services
  on the main actor like them (`WebCalls`), the changes and their run
  (`WebRun`, above), and the lines of the operation a browser started
  (`OperationFeed`).
- The launchpad (`IrisinLaunchpad`), which shares `IrisinShared/` with the
  app and links nothing third-party. AptRepository and the rest declare
  tvOS 17 and visionOS 2; libsolv and libarchive carry both slices, and
  WCDB from 2.1.26102501, which is 2.1.16 built again with visionOS's.

## Tested on

So far, 2026-10-26: the tvOS simulator (Apple TV 4K, tvOS 26.5), the
launchpad installing into its container through `SimulatorDaemon`, called
from the Mac with the page's own cipher: `device`, `repositories` (the
recommended list added on first launch and refreshed), `search`,
`package`, `installed`, `updates`, `storage`, `propose` and the plan, a
wrong code refused (403), and `confirm` putting the owner's question on the
screen with Decline focused. The Vision Pro simulator build compiles; the
tvOS package builds and verifies.

On `tv4k` (jp-01: AppleTV14,1, tvOS 26.6, RootHide), the same day, with the
package's files pushed into the existing root over `vphone.sock` and the
postinst's three jobs run through `irisin-install` as root (`prepareUserHome`,
`bootstrapIrisinDaemon`, `rebuildIconCache`: "Registered 1"); the page called
from jp-01 with `cipher.js` in `jsc` and `curl`, the remote pressed with
`input.hid`. The launchpad showed its address, code and QR code, and
irisind admitted it as mobile by its path. `device`, `repositories` (the
recommended list added and refreshed on first launch), `search`,
`installed`, `storage`, `clearDownloads` (733184 bytes to 0), `exportRepositories`,
a wrong code (403) and the page's files (200) answered. Declined with Select
on the focused Decline and with Menu; confirmed with Right and Select: a
repository added (Procursus, an empty catalogue for `appletvos-arm64e`) and
deleted, and the queue's install of Irisin 5.0.1, the repository's one
package for this bootstrap, ran to the end: downloaded, Bootstrap Install (no
dpkg), staged, verified, unpacked and configured (its shell postinst failing
as a warning, there being no shell), the daemon loaded again, `succeeded`,
status 0, and the launchpad left as after an update of Irisin, dpkg listing
5.0.1. 5.0.2's files went back the same way, and the launchpad was admitted
again.

Still to do, on jp-01 and jp-02. The iOS package on the RootHide guests, managed from
Safari on the host Mac; the tvOS package (daemon, helper, launcher) on the
tvOS guests, the same way, once a repository serves the placeholder
architecture (a fixture repository until there is a real one). A wrong
code, a request that does not open, a confirmation declined and one given, a plan changed after it was shown,
an install, a removal, an update, Irisin updating itself from the page,
and a page reconnecting to an operation already running.
