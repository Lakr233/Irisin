# Managing from a browser

Draft, for 5.1.0, after three rounds of review and the owner's decisions
of 2026-10-26. A device running Irisin serves a page on
the local network, and a browser on another device (Safari on an iPhone
first) manages it: repositories, search, install, remove, update, the
operation as it runs. On Apple TV it is the only interface Irisin has; on
iPhone and iPad it is a second one, beside the app.

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
- **tvOS:** the launcher is a target of its own in the project, product
  `irisin` at `/Applications/irisin.app`, built from `Services/` with an
  application delegate and one screen of its own: the device's name and
  address, the code and its QR code, the operation running, and the owner's
  answers. It serves while it is open and keeps the screen from
  sleeping. irisind admits it as mobile by the exact-path rule iOS's app has
  (`IrisinWire.clientPaths`, empty on tvOS until the launcher ships), and
  `PackagedArchitecture` learns tvOS: RootHide's root found from the bundle
  path, and the package's architecture, the placeholder for now. The tvOS
  package becomes the daemon, the helper and the launcher.

## What has to move first

The run from a proposal to its end lives in the interface today
(`QueueController`: waiting for downloads, `QueueInstallChecks`, the
scripts warning, the confirmation, staging, the console; and the
operation's Ending, Try Again and Irisin's own registration in
`OperationController+Completion`). The web, and the launcher, need it
without a view controller, so it moves into a service both interfaces
call, and the app shows an operation the web started the way it shows its
own. That move is the first change of 5.1.0, made and tested on iOS before
the server exists.

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

The page says nothing of its own. Its words are a table in Swift, each a
`String(localized:)` under a stable name (`searchPlaceholder`), so Xcode
extracts every one and translates it with the rest; the page asks for the
table (`GET /api/v1/strings`, in the clear, since the page asks for the
code in words too) and a Mac test checks that every name the page uses is
in it.
An operation's lines reach the page as the device already spells them
(`InstallerEvent+Console`), never as events the page would have to spell.
Custom firmware, never jailbreak.

## The interface between them

Sealed JSON over HTTP. A call is one `POST /api/v1/call` whose body is a
sealed `{op, args}` and whose answer is a sealed result; an operation's
lines arrive on a streamed `fetch` of `POST /api/v1/stream`, one sealed
frame per line with its sequence number, and a page that reconnects asks
from the last number it has. No framework on either side: the server is
`Network.framework` with CryptoKit, the page is HTML, CSS
and JavaScript bundled in the app. WebCrypto is not offered to a page
served over plain HTTP, so the page carries its own `cipher.js` (SHA-256,
HMAC, HKDF, ChaCha20-Poly1305, a few hundred lines, no dependency),
checked on the Mac against the RFCs' vectors and byte for byte against
CryptoKit.

| | |
| --- | --- |
| `GET /`, `/page.js`, `/page.css`, `/cipher.js` | the page, in the clear |
| `GET /api/v1/hello` | the salt for this start, in the clear |
| `GET /api/v1/strings` | the page's words, in the device's language, in the clear |
| `POST /api/v1/call` | sealed: `device`, `repositories`, `addRepository`, `removeRepository`, `refresh`, `search`, `package`, `installed`, `updates`, `propose` (install, remove, update all; answers the plan and its id), `clear`, `confirm` (asks the owner for that plan id; answers at once) |
| `POST /api/v1/stream` | sealed frames: the running or last operation's lines, from a sequence number, until its end |

Every answer is `Cache-Control: no-store`.

## How it is built

- `Packages/IrisinWeb`: the HTTP server, the code, the key and the sealed
  envelope, routing and the limits, with no UIKit and nothing outside the
  system, tested on the Mac against the page's own cipher code. The page's
  files are its resources.
- The pipeline service, moved out of the interface (above).
- `Irisin/Services/WebManagement`: the API bound to the services, on the
  main actor like them.
- The tvOS launcher target, sharing `Services/` with the app through the
  synchronized group, minus what it cannot compile there. AptRepository and
  the rest declare tvOS 17; the WCDB and libsolv releases already pinned
  carry tvOS slices.

## Tested on

jp-01 and jp-02. The iOS package on the RootHide guests, managed from
Safari on the host Mac; the tvOS package (daemon, helper, launcher) on the
tvOS guests, the same way, once a repository serves the placeholder
architecture (a fixture repository until there is a real one). A wrong
code, a request that does not open, a confirmation declined and one given, a plan changed after it was shown,
an install, a removal, an update, Irisin updating itself from the page,
and a page reconnecting to an operation already running.
