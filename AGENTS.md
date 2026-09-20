# Irisin — Agent Notes

APT package manager for jailbroken iOS 16+, roothide and rootless bootstraps
both. **iOS only.** The app runs as `mobile` and never becomes root; the
bundled `irisind` LaunchDaemon starts `irisin-install`, which installs
package files natively and, as root, tells LaunchServices about app bundles
through [icli](https://github.com/owngoal-dev/icli), our own code, linked into
the helper as a library. Without
a daemon (a wrapper that did not ship one) the app browses repositories and
installs nothing. The simulator has no daemon either and installs all the
same, into a directory of its own: see `make sim` below.

The single idea the design hangs off: **the daemon starts one helper for one
closed job and hands the app the helper's output pipe.** No command line ever
crosses the XPC boundary, the daemon keeps no state, and the helper runs in
its own session so the package that replaces this app still installs to the
end.

## Hard rules

- **The project is Irisin.** The product is Irisin, the codename is `irisin`,
  the bundle is `wiki.qaq.irisin`, and the GitHub repository is
  `Lakr233/Irisin`. `chromatic` and `Saily` are gone from every file and
  every filename, with no exception left; `make check` greps the tracked
  tree for both, case-insensitively, and fails on a hit.
- **The user never reads "jailbreak".** What the app runs on is custom
  firmware, in the app's text, in every translation (where the word comes
  back on its own), on the Settings page and in the package's control
  file. `make check` runs `Scripts/check-wording.py`, which reads every
  locale's value for the word in each language and fails on a hit. Code,
  comments and these notes say jailbreak where that is the plain word.
- **Two links and two file types, and nothing to repair.** The app answers
  `irisin://repository/add?url=…[&suite=…][&component=…]` and
  `irisin://package/<identity>`; `IrisinLink` parses with `URLComponents` and
  refuses what it cannot read rather than patching it, which is what
  `apt-repo://` spent its life doing. A link to a package no added
  repository offers opens nothing and says so. Repositories are shared and
  exported as our own property lists — `.irisinrepos`
  (`wiki.qaq.irisin.repository-list`, XML, addresses only) and `.irisinrepo`
  (`wiki.qaq.irisin.repository`, binary, one repository whole) — and a
  package list is exported as `.txt`, nothing else. **An import takes the
  addresses and nothing else**, even from a `.irisinrepo` that carries a
  catalogue: the file's description of a repository is the file's, not the
  server's, and the refresh after the import is what the user sees. `.deb`
  stays a type we only view, and a `.deb` opened in place is copied, never
  moved out of the user's folder.
- **The app never raises privilege.** No `setuid`, no persona spawn, no
  re-exec of itself as root. `make check` greps for the old shapes and fails.
  Everything privileged is an `InstallerJob` sent through `PrivilegedBackend`.
- **The wire carries jobs, never commands.** `InstallerJob` is a closed enum:
  an ordered package transaction (prepared files and identities), rebuild the
  icon cache, respring, bootstrap or boot out Irisin's own daemon, reload
  AirDrop, enter safe mode. The daemon jobs carry no path or label: the helper
  derives its own installed plist. The helper validates
  package inputs and composes script arguments itself from those fields.
  There is no `exec(path, argv)` and there will not be one: a root daemon
  that can be talked into running a command is a root shell for whoever can
  talk to it.
- **The transcript is typed.** The helper writes one `InstallerEvent` per
  line (`InstallerOutput` frames it as JSON): phases, a progress count,
  package steps (verifying, removing, unpacking, configuring, triggering),
  the files placed within a step (`packageProgress`, for the screen alone
  and kept out of both logs), script announcements, output, notices,
  warnings, a failure and the final `exit`. A failure that stopped at a
  package names it and its step (`packageFailed`), and the script and its
  exit status when one of the package's own scripts stopped it
  (`scriptFailed`). The app never parses
  prose; `OperationMonitor` publishes the events through Combine,
  `OperationPackages` reduces them to one state per package, and
  `InstallerEvent+Console` spells them in the user's language. The
  operation page is the queue's list with a ring per row and nothing else
  that moves; a failure offers Try Again as a small link below the list,
  which runs the re-solved queue in a new controller in the same sheet. A
  footnote under the list fades in while the helper finishes after the last row, and the helper's
  lines are on the log page and on the failed package's page, never on the
  list. The
  log file beside the pipe
  (`<root>/var/log/irisin-install.log`, previous run in `.previous`) is
  the same events as timestamped plain text. Add a case, not a prefix.
- **No tool is spawned for the home screen, and no icli ships.** `uicache`,
  `sbreload` and `killall` are gone and `uikittools` is not a dependency.
  icli is our own repository and is linked into `irisin-install` as the
  `IcliKit` library (`Packages/IrisinKit/Package.swift`, an exact version,
  iOS only), never copied into this tree and never packaged as an executable:
  a second icli on the device that the user did not install is a question
  they should not have to ask. `ApplicationRegistrar` makes one of four closed
  requests (register, unregister, refresh a directory, respring), while
  `LaunchDaemon` can only boot out or bootstrap and start Irisin's
  own daemon through IcliKit. The package has no `launchctl` dependency, and
  `verify-deb.sh` fails on a package that contains an `icli`. A refused
  respring falls back to signalling backboardd. Safe mode and the AirDrop
  reload are `kill(2)` from the helper itself (`ProcessTable`). What icli was
  signed with for this work is in `Packaging/irisin-install.entitlements`,
  the helper's alone; the daemon gets none of it. The package's own postinst
  first pipes `bootstrapIrisinDaemon` into the helper, then registers the app
  with a `rebuildIconCache` job. A fix
  to the LaunchServices code goes to the icli repository and arrives here as
  a version bump.
- **Peer authentication is the whole trust boundary.** Audit token, then the
  `wiki.qaq.irisin.client`, `platform-application` and `no-sandbox`
  entitlements, then the executable on disk equal to the installed app and
  root-owned. Before the first request field is read.
- **The daemon's absence is never surfaced as an error.** It is on-demand: a
  miss means launchd has not started it yet. `PrivilegedBackend.start()` keeps
  asking; a build with no daemon beside its bundle settles on the local
  backend after `DaemonLink.graceBeforeFallback`, a duration and never a count.
- **Self-update is the helper's problem, by design.** `irisin-install` is
  spawned with `POSIX_SPAWN_SETSID` and the daemon plist sets
  `AbandonProcessGroup`, so the postinst of our own package restarting
  `irisind` does not kill the transaction. The helper ignores `SIGPIPE`
  and mirrors its transcript to `<root>/var/log/irisin-install.log`, so a
  reader that went away (the app being replaced) loses nothing. The app exits
  after the transcript ends when `Transaction.touchesSelf`. `irisind` watches
  its opened executable inode and exits when replacement or removal drops its
  final link; the registration-completion check closes the startup unlink race.
- **A package built for another bootstrap is rewritten in the app, never
  by the helper.** `IrisinAdapter` runs as `mobile` inside
  `PackageQueue.patch` (and inside `Installer.stage` for a package Patch
  never saw), after `prepareDebianPackage` and before the job is sent: it rewrites the prepared tree and hands back the new manifest
  digest, and the helper installs what it is given. `PackageAdapters.installed`
  is the switch: an adapter listed there makes its `source` architecture
  installable (`AptEnvironment.installableArchitectures`); there is no
  setting. One whose conversion is not written yet stays listed and throws
  `AdaptationFailure.unavailable` at Patch, typed, spelled by the app.
  `RootlessToRoothide` is roothide's own RootHidePatcher (`patch.sh`,
  Compat Layer) in Swift, nothing spawned: tweaks, apps, programs, daemons
  and hard links converted as the script converts them, and what it would
  make otherwise (files outside `/var/jb`, conffiles, a list sed would
  garble) refused with a typed failure, never installed as built. Its output
  must equal the script's, blob for blob, save the one difference below
  (`AdapterConformanceTests`, fed by `Scripts/adapter-reference.sh`, writes
  it down in `compare`); Mach-O is read through MachOKit, and
  ldid (AGPL) is matched byte for byte, never linked or ported, down to the
  way its libplist reads the entitlements it merges. A property list's
  paths are respelled on the parsed list, never by editing its text. It adds
  the `rootless-compat` Pre-Depends to a package with a Mach-O in it and
  never adds a repository. A package with none (a theme) gets no
  Pre-Depends, the one place it parts from the script on purpose. What an
  adapter adds to a package's relations is the adapter's to say, never a
  string the resolver is handed: `resolveAdaptedPackageManifestPreview`
  answers with the control paragraph it expects to leave, from the
  catalogue's alone, and the resolver solves an adapted package as that
  says before anything downloads. The file may show otherwise, so the
  queue page offers Patch in place of Execute while the plan installs an
  adapted package that has not been through it: `PackageQueue.patch` waits
  for the files, adapts each once, keeps the tree for staging (which hands
  it to the helper as it is and adapts only what Patch never saw) and
  solves again with the control paragraphs `adapt` wrote, so
  rootless-compat and patchloader leave a queue of themes before it runs.
  A queue that is not what it was says so in an alert, and the button is
  Execute from then on. On the same file the plan and the install never
  disagree, since the paragraph solved with is the one installed. The queue
  asks before an adapted package joins it (Compatibility Mode), and its
  sheet says the queue may change at Patch.
  A newer version an adapter would have to rewrite is not an update until
  the user turns on Compatibility Updates (Settings, off, confirmed, and no
  row where nothing is adapted): `PackageCenter.offersAdaptedUpdates` keeps
  it out of the Updates page, the badge, the dashboard and the banner, and
  the resolver locks it out of an update of everything without reporting
  it held back. Asked for by name it installs as ever.
  The bootstrap the package was built for is
  `IrisinCurrentArchitecture` in the app's Info.plist, written by
  `package-deb.sh` per flavor; a build that was never packaged uses the
  bootstrap runtime's layout, never a vote of installed packages. A packaged
  Irisin never switches architecture to fit the device: startup compares
  that key with the independently detected bootstrap, alerts on a mismatch
  and does not open the interface.
  Install the matching official package; Irisin itself must not be converted
  with a patcher, including its own compatibility adapter.
- **Translation is the system's engine, asked privately, and the json is
  what gets translated.** `SystemTranslator` speaks `_LTTranslator` (the
  same class from iOS 16 to 26; the public `TranslationSession` needs iOS 18
  and a SwiftUI view), opened by path and looked up by name. translationd
  rejects a client without `com.apple.private.translation`, in the simulator
  too, so the key is in `irisin.entitlements` and in
  `irisin-simulator.entitlements`, the simulator build's alone. A request
  goes the system's preferred route first (server or large model), then
  `forcedOfflineTranslation`, then fails typed. Auto Translate
  (Settings, off until `verify` passes) shows a package page as written,
  then renders the depiction again from `DepictionTranslation`'s answer and
  cross-dissolves to it; markdown syntax, links and code never reach the
  engine. The package's name in the banner goes with the page's
  prose and reads as the page does (`PackageBannerView.showName`); the
  navigation title stays as written.
  A failure alerts once per launch and logs every time. The page's
  menu has Translate under Select Version: Original, Translated or
  Compared (the translation under each piece), checked, then the source
  (detected unless named, the page's alone) and target language (kept)
  from the engine's own list; what is chosen there is always answered,
  alert included. With Auto Translate on, a line under the banner
  (`TranslationStatusView`, the page's own, outside the depiction, a note
  and never a control) says Translating…, then that the page is
  translated or could not be (the package page is a diffable table of
  the views it owns, `PackageRowCell` around each, and the line is a row
  that comes and goes by snapshot); with it off there is no line. A
  translation asked for from the menu waits behind a progress alert with
  Cancel, whatever the setting, and Cancel puts the menu back as it was:
  the checkmark, the language whose choice asked, the line.
  `TranslationCache` holds the answers of the fifty
  packages read last, in memory only.
- **No install prefix is written in Swift.** The daemon and the helper derive
  it from their own `proc_pidpath` (`ProcessPath.installRoot`); the app reads
  it from `hello`, and uses libroot (`JailbreakRoot`) only while there is no
  daemon to ask. `BootstrapLayout` decides how a path is spelled for a
  vroot-linked tool on roothide (`/rootfs/...` for the app's files) versus a
  prefix-compiled one on rootless.
- **Versions and the deployment target live in `Configuration/*.xcconfig`
  only.** `make check` rejects either in `project.pbxproj`.
- **No project generators.** `Irisin.xcodeproj/project.pbxproj` is
  hand-written, `objectVersion = 77`, file-system-synchronized groups: a file
  under `Irisin/`, `IrisinDaemon/` or `IrisinInstall/` joins its target by
  existing. `make check` fails if Xcode rewrites `objectVersion`.
- **No Swift file names the SDK's XPC constant macros.** They come from
  `CIrisinXPC` through `IrisinXPC`; naming them in Swift links
  `libswiftXPC.dylib`, which iOS 15 does not have. `make check` greps for
  them and `verify-deb.sh` checks the load commands.
- **No absolute build paths in a shipped binary.** `#file` is concise
  (`SWIFT_UPCOMING_FEATURE_CONCISE_MAGIC_FILE`), and a dependency that still
  spells `#file` in a default argument in Swift 5 mode leaks the *caller's*
  path — SnapKit before 6.0 did. `package-deb.sh` fails the build on one.
- **Nothing third-party links into `irisind`, and only icli's own
  dependency into `irisin-install`.** The daemon links `IrisinProtocol`
  and nothing else. The helper links `IrisinProtocol`,
  `IrisinInstaller` and, through it, `IcliKit`, which is ours and brings
  libarchive with it. Nothing else is added to either.
- **User-facing text is a `String.LocalizationValue` spelled out in
  English** (`String(localized: "Clear Downloads")`, `presentNotice(title:
  "Error")`), resolved against `Localizable.xcstrings`. No `NSLocalizedString`,
  no `SHOUTING_KEY` identifiers; `make check` greps for both.
  **Changing a string changes its English key**, never only a translation:
  the Swift literal, the catalog key with its `en` value, every translation
  and the comments and names that call the control by its old word, all in
  the same change. A translation that says something the English does not
  is a bug.
- **Menus are `UIMenu`.** A list of choices hangs off a `UIButton.menu` (or a
  `UIBarButtonItem`) with `showsMenuAsPrimaryAction`, built lazily through
  `UIDeferredMenuElement.uncached` when it depends on state. No custom
  drop-down views, no `UIAlertController` action sheets.
- **Every list is a diffable data source.** A `UITableView` or
  `UICollectionView` gets a `UITableViewDiffableDataSource` or
  `UICollectionViewDiffableDataSource` with `Hashable` row identities and
  changes by applying a snapshot (`reconfigureItems(survivingFrom:)` for
  rows that stay). No `UITableViewDataSource` or `UICollectionViewDataSource`
  conformance, no `numberOfRowsInSection`, no `reloadData()`; `make check`
  greps for all of them. Rows measured again are a snapshot that
  reconfigures them, never the view's own mutation calls
  (`performBatchUpdates`, `beginUpdates()`, `reconfigureRows(at:)`): iOS 16
  throws from any of them, an empty batch included, on a table whose data
  source is diffable (issue 125), and `make check` greps for those too, in
  the app and in `Packages/`.
- **Fonts and colors are design tokens.** `Interface/DesignTokens/` owns
  the type ramp (`TypeSize.swift`: `TypeSize`, `UIFont.rounded(.body,
  emphasized:)`, `.type`, `.monospaced`) and the named colors by purpose:
  grounds (`UIColor+Surfaces.swift`), what is drawn on them
  (`UIColor+Content.swift`) and states (`UIColor+Status.swift`). A call
  site picks a token: no `systemFont(ofSize:)`, no weight other than
  regular or semibold, no `UIColor(hex:)`, `UIColor(red:...)`,
  `UIColor(named:)`, `.systemRed` or `.gray` outside that folder, and no
  colour set in an asset catalog. A new look is a new token with a doc
  comment; `make check` greps for the literals.
- **Grounds step up, never down.** The iPad sidebar
  (`.panelBackground`) is the lowest ground, the detail column
  (`.pageBackground`) a step brighter, a card (`.cardBackground`) a step
  above whatever it sits on, in both modes. In the dark that step is the
  system's elevated level: `ColumnHostController` marks the detail
  column elevated, so a page's ground there is `#111111`, not black, and
  its cards the elevated `#2C2C2E`. A page picks its ground from
  `.pageBackground`, `.plainBackground` (rows on the ground itself) or
  `.groupedBackground` (inset-grouped lists and form sheets), never
  `.systemBackground` or `.systemGroupedBackground`, whose elevated
  `#1C1C1E` is a shade too bright; `make check` greps for both. The
  package page's photo sits on `.panelBackground`, a step below its card.
- **The share sheet is `ShareSheet.present(_:anchor:from:)`.**
  The iPad shows it as a popover and answers one with nowhere to point
  with an exception. A `PopoverAnchor` names the view or bar button that
  was touched; the sheet points there while it is still on screen, then
  at the page's bar button, then at the middle of the page. Nothing else
  makes a `UIActivityViewController` or touches a popover presentation
  controller; `make check` greps for both.
- **One asset catalog.** Everything the app draws from a file is in
  `Resources/Assets.xcassets`.
- **Swift 6 language mode, everywhere.** `SWIFT_VERSION = 6.0` on every
  target; concurrency diagnostics are errors, not warnings to be silenced.
  The app defaults to main-actor isolation (`SWIFT_DEFAULT_ACTOR_ISOLATION`).
- **State lives on the main actor; work that takes time runs on a copy.**
  `RepositoryCenter`, `PackageCenter`, `PackageQueue`, `Installer` and
  `Downloads` hold their state on the main actor, so a read or a commit
  is a dictionary operation and no lock guards anything. Parsing dpkg's
  status, resolving dependencies, hashing downloads and fetching a
  repository take a copy (`PackageCenter.default.index`,
  `RepositoryCenter.default.repositories`, an `UpdateRequest`) into a
  `nonisolated static` or `@concurrent` function and commit the result
  back. Every engine notification is posted on the main actor. UI bindings
  use Combine publishers scheduled on the main queue, with subscriptions
  owned by the view or controller; merge reload signals before throttling
  and deduplicate values, not invalidation events. Do not add an `NSLock`,
  a serial queue or an actor to a manager; add a snapshot.
- **The catalogue is the one exception: it lives in SQLite, not in RAM.**
  Every package a repository offers, the installed list, the virtual
  package map, the traces and the full-text search index are rows in
  `<working>/apt.db` through WCDB (`Packages/AptRepository/.../Storage/`).
  `PackageIndex` is a handle on that database, so a copy of it is free and
  every `obtain*` is a query; a repository refresh replaces its rows in one
  transaction. WCDB's `Database` pools a handle per thread, so a query runs
  from any actor without a lock; nothing keeps a `Handle`, `Insert` or
  `Select` past the statement that made it. `Repository` keeps only its
  source, Release metadata and `packageCount`; the packages are in the
  database, never on the struct.

## Layout

- `Irisin/` — the app: `Application/` (delegates, `AppPaths`),
  `Services/` (`PackageQueue`, `Installer`, `Downloads`, `VendorAccount`,
  `Privilege/PrivilegedBackend`, translation),
  `Interface/`, `Extension/`, `Resources/`.
- `IrisinDaemon/` — the daemon, product `irisind`: listener, peer
  authentication, helper launch.
- `IrisinInstall/` — the helper, product `irisin-install`: one job
  from standard input, the transcript on standard output.
- `IrisinUnitTest/` — test bundle hosted in the app (`@testable import
  irisin`), for what only makes sense against the app's own types:
  `Services/Downloads/Downloader` against a `URLProtocol` stub, the
  operation page's reduction of the transcript (`OperationMonitor`,
  `OperationPackages`), queue resolution, notification bindings, the path
  list and the depiction's contact parsing.
- `Packages/IrisinKit/` — `IrisinProtocol` (`IrisinWire`, `InstallerJob`),
  `IrisinInstaller` (`BootstrapLayout`, `InstallerRunner`, `ToolSpawn`),
  `IrisinClient` (`DaemonLink`, `JobTranscript`), `IrisinAdapter`
  (`PackageAdapter`, `PackageAdapters`, `BootstrapArchitecture`), each with
  `swift test`.
- `Packages/<Name>/` — in-house or locally modified libraries
  (AptRepository, PackageDepiction, ...).
  Every local package declares iOS 16, the app's own floor and what
  `IcliKit` asks of IrisinKit and everything above it. PackageDepiction's views are
  laid out with SnapKit and configured with Then, like the app: a depiction
  is Auto Layout throughout, so its height is its own and nothing measures it.
  Everything with a usable upstream release is a remote package reference.
- `Configuration/`, `Packaging/`, `Scripts/`, `Makefile` — build inputs.

## Strings

English is the source language and `zh-Hans` the reference translation the
other locales are made from, so a Chinese value that drifts from the English
drifts in every language after it. Everything the user reads is in one of
these, all under `Irisin/Resources/`:

- `Localizable.xcstrings` — everything the app says, plus the two labels
  PackageDepiction's photo viewer asks for ("Share", "Close"): a package's
  `String(localized:)` with no bundle resolves against the app's catalog.
- `InfoPlist.xcstrings` — the bundle names (marked not to translate) and
  "Debian Package", the name of the `.deb` document type.
- `Settings.bundle/<locale>.lproj/Root.strings` — Irisin's page in the
  Settings app. `Root.plist` names the table, and its title and footer
  text are the keys; a locale with no `Root.strings` shows English.

The local packages ship no catalog of their own. AlertController and Litext,
remote packages, each carry one for their own labels, and AlertController's
("Cancel", "Done") has only `zh-Hans`: that is fixed upstream and arrives as
a version bump, like icli.

- Xcode extracts a key only from a `String.LocalizationValue` handed to a
  function declared in the app's module. A literal passed straight to
  AlertController (hence `progressAlert`) or quoted only in a package is
  `manual`; Xcode never touches that state, so it goes only when the text
  stops being quoted anywhere, and a key Xcode does extract is not left
  `manual`.
- A key is finished when every locale has a `translated` value whose format
  specifiers match the English: `Scripts/localize.py extract` reports what
  is missing, and a new key with no translations is not finished.
- Stale entries go through `prune-xcstrings.py` (below), never through
  Xcode's own cleanup, which takes the translations with it. The open Xcode
  also re-sorts the catalog's keys on its own; that reordering is noise in a
  diff, not anyone's change.

## Build & verify

- `make harness` — the IrisinKit and AptRepository tests on the Mac. Run
  first.
- `make test` — the IrisinUnitTest bundle inside the app on the booted
  simulator (`SIMULATOR=<udid>` to pick one).
- `make check` — project and packaging validation.
- `make build` — the harness, then `make compile`: unsigned app, daemon
  and helper for iPhoneOS, checked and built with no tests (CI runs the
  harness as a job of its own beside it, then `make _packages`; a tag
  publishes the packages of its commit's CI run once that run has passed,
  and builds nothing of its own). The build
  number is the git commit count (`BUILD_NUMBER=n` to override; CI passes
  its run number), handed to xcodebuild on the command line. Nothing in the
  tree changes from building; `Version.xcconfig` holds only
  `MARKETING_VERSION` and a `0` fallback for builds from inside Xcode.
  The build has no warnings, Debug or Release, and a change keeps it that
  way. `run-xcodebuild.sh` shows each one as a `[!]` line (xcbeautify's
  mark; the raw `warning:` without it).
- `make deb` / `make deb-all` — roothide and rootless packages, verified.
- `make install` — update an installation over `iproxy 2333 22`.
- `Scripts/prune-xcstrings.py Irisin/Resources/Localizable.xcstrings Irisin Packages`
  — after Xcode has marked catalog entries stale: a key still quoted in a
  Swift file of the app or a local package (a literal handed straight to
  AlertController, which the extractor cannot see) becomes `manual`, the
  rest are removed. Run it instead of letting Xcode delete translations on
  its own schedule.
- `Scripts/localize.py extract <dir>` then `merge <dir>` — the locales Fila,
  iGhostVT and CocoaInspector ship. `extract` writes one job per locale
  with only the strings it is missing (catalogs and `Settings.bundle`);
  one translator per locale answers in `<locale>.out.json`; `merge`
  writes them back and refuses an answer whose format specifiers differ.
  A new English string is not finished until `extract` reports 0 missing.
- `make sim` — Debug build installed and launched on the booted simulator
  (`SIMULATOR=<udid>` to pick one). `xcrun simctl io booted screenshot` is
  the quickest layout check, and the whole install flow runs there:
  `IrisinClient/SimulatorDaemon` answers for the daemon under
  `#if targetEnvironment(simulator)` and runs the same `InstallerRunner` in
  the app's process against `<container>/Documents/SimulatorRoot`, which
  stands in for a rootless `/var/jb` (`BootstrapLayout.mount`). The app
  reads that directory through `JailbreakRoot` like a device's bootstrap,
  so resolution, downloads, staging, the transcript, the dpkg database and
  the Installed page are the real code. What a Mac must not have done to it
  is compiled out of the installer under the same condition: maintainer
  scripts, icli and signals are announced in the transcript and not carried
  out. The root starts with `firmware` in its status file, as a bootstrap's
  firmware script leaves it (the helper checks the final state against dpkg
  and makes nothing up, unlike the app's resolver); everything
  else a package depends on comes from a repository (add Procursus:
  `https://apt.procurs.us/`, suite `2000`, component `main`). Delete the
  directory for a fresh device. `IrisinClient` depends on
  `IrisinInstaller` for this alone, since SwiftPM has no simulator-only
  dependency: the installer, and icli with it, stays in the device app,
  never called.

Give every parallel worker its own `DERIVED_DATA=~/Library/Caches/<name>`.
Never under `/tmp`: Xcode spells it `/tmp` while FileManager resolves it to
`/private/tmp`, and some package manifests strip checkout paths by string
match; the two spellings then fail to match.

## Where things get tested

The Mac harness first; a jailbroken device or vphone for the privileged half.
On the vphone the helper can be driven directly as root:
`echo '{"transaction":{"_0":{"install":[],"remove":["x.y"],"dryRun":true}}}' | /var/jb/usr/libexec/irisin-install`.
It answers one JSON event per line; the plain-text account of the same run
is `/var/jb/var/log/irisin-install.log`.

## Gotchas that bit us

- **One libarchive in the package graph, and no Swift file imports it.**
  icli depends on the libarchive.xcframework package, whose binary target is
  named `libarchive`; a second binary target of that name in
  `Packages/AptRepository` fails resolution ("multiple packages declare
  targets with a conflicting name"), so AptRepository takes the package's
  `LibArchive` product too. That product is a Swift wrapper, `LibArchive`,
  around the binary module `libarchive`: the names differ by case alone,
  `xcodebuild` puts `LibArchive.swiftmodule` in one flat Products directory,
  and on a case-insensitive volume Xcode 26's compiler, asked for
  `libarchive`, opens that file and refuses it — "cannot load module
  'LibArchive' as 'libarchive'". Importing the wrapper asks the same
  question through its `@_exported import`. So nothing in Swift imports
  either: `CAptArchive`, a C target, declares the functions `ArchiveStream`
  calls, and its `.c` file includes libarchive's own headers so a prototype
  that drifts stops the build. icli reaches libarchive from Objective-C and
  never had the problem. If the error comes back, a Swift file has imported
  `LibArchive` again.
- **The project is built with Xcode 27 and CI has 26.6.** The runner image
  has no Xcode 27, so one thing is a workaround and comes out the day it
  does: `UITabBarController.prominentTabIdentifier` is in the iOS 27 SDK and
  not in Xcode 26's, and `#available` guards the call, not the reference, so
  `TabInterfaceController` sets it through KVC under its `iOS 27.0` check.
  Same behaviour, any SDK.
- **LNPopupController crashed the iPad on launch and is gone.** Its
  `UISplitViewController` category asked a legacy-style split controller
  `isShowingColumn:`, which iOS 26 answers with an exception, and nothing
  used the popup bar any more. Do not add the package back; a bottom bar is
  a view of our own.
- **A stale dpkg files list breaks every install on the device.** A `.list`
  under `Library/dpkg/info` with a bare `/` or an empty line makes dpkg abort
  with "contains empty filename" for *any* package. Strip those lines.
- **launchd may print the daemon under `user/501` even though it is a system
  daemon.** IcliKit reads both the system proxy and foreground-user record;
  trust the helper transcript and the app's journal.
- **The vphone loses its `/var/jb` symlink** after some boots because the
  first-boot script exits early on its done marker. Recreate it:
  `ln -sf /private/preboot/<hash>/jb-vphone/procursus /private/var/jb`.
- **The Settings app shows `Settings.bundle` only when LaunchServices was
  told.** On the iOS 26 vphone `registerApplication:` refuses a new Irisin,
  answers YES for an updated one without reading it, and never sets
  `HasSettingsBundle`. icli 0.3.2 reads the record back and registers Irisin
  from a dictionary with the key whenever the record is missing, stale or
  without it; its refresh also re-registers an app whose build changed.
  `uicache -p` drops the key again, and the page with it, until the next
  build is installed. A probe of `LSApplicationProxy.hasSettingsBundle` is
  the quickest check.
- **`await vc.dismiss(animated: true)` does not wait.** The iOS 27 SDK marks
  `dismissViewControllerAnimated:completion:` `NS_SWIFT_DISABLE_ASYNC`, so
  the call resolves to the synchronous overload, the compiler warns that
  nothing is awaited, and the next `present` meets a sheet still leaving.
  Await `dismissFinishing(animated:)` (`UIViewController+Alert.swift`).
- **roothide link text is a kernel path; `ls` and `stat` do not say so.**
  vroot writes an absolute link target as jbroot + target (`/rootfs/x` as
  `/x`), and its `readlink` and `lstat` translate the text *and `st_size`*
  back. Every bootstrap tool on the device shows the translated text, so
  check raw link text with a process that is not vroot-linked. The helper
  writes links as vroot does (`BootstrapLayout.linkText`). The jbroot's
  `var` lives in an app group container outside it. ElleKit's
  `DynamicLibraries` link broke tweak installs until all of this was known:
  `Documentation/InstallerCaseStudies.md`.
