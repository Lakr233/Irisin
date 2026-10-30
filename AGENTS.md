# Irisin — Agent Notes

APT package manager for jailbroken iOS 15+, roothide and rootless bootstraps
both. **iOS first.** Apple TV and Vision Pro get the launchpad
(`IrisinLaunchpad`): the app's services and one screen of its own, managed
from a browser on the same network (`Documentation/WebManagement.md`). The
privileged layer (`irisind`, `irisin-install`) builds for Apple TV too: tvOS
16, RootHide alone, whose decisions and open questions are
`Documentation/AppleTV.md`. No bootstrap serves Vision Pro yet, so the
launchpad there browses, and installs only in the simulator.
The app runs as `mobile` and never becomes root; the
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
end. Another package's program (Apelin's session host first) installs the
same way through the external operations, where the helper writes into a
transaction's journal on disk instead of a pipe: `Documentation/ExternalClients.md`.

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
  icon cache, register Irisin's own app, respring, bootstrap or boot out
  Irisin's own daemon, reload AirDrop, enter safe mode, make the app's data
  folder. The daemon jobs carry
  no path or label: the helper derives its own installed plist, and the home
  from the layout (`<jbroot>/var/mobile` on roothide, where icli registers
  apps' HOME and a bootstrap need not have it). The helper validates
  package inputs and composes script arguments itself from those fields.
  There is no `exec(path, argv)` and there will not be one: a root daemon
  that can be talked into running a command is a root shell for whoever can
  talk to it. An external client's operations are closed the same way: a
  package by descriptor, a removal by id, a respring, each under a
  transaction id it chose (`InstallerJob.external` carries the id and the
  digest or package id, never a path).
- **The app's data lives in `~/Documents/wiki.qaq.irisin`, and the package
  makes it.** An app without a container shares mobile's home with every
  other one, so its data goes in a folder named for its bundle id — the
  isolation a sandbox's container would give — inside a `Documents` mobile
  owns, which a container would have had too. The postinst (dpkg, as root)
  and irisind's `prepareUserHome` (which the app asks for when it cannot make
  the folder) follow one rule: each missing level of home, `Documents` and the
  folder is made and handed to mobile on its own, a level that exists is left
  alone, and no level is followed through a symlink. Never `mkdir -p` as
  root: 4.3.4 through 4.5.25 did, and on a bootstrap with no `Documents` it
  left `Documents` root's, so every other app without a container could keep
  nothing there (a roothide iPad's iGhostVT lost its log to it). Both hand a
  root-owned `Documents` back to mobile. The vphone never showed it: vphoned
  installs Irisin without dpkg, so the postinst never ran there. The siblings
  and the platformize-app-ios template do the same in their postinst.
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
  which runs the re-solved queue in a new controller in the same sheet, and
  holds the button that closes the page while it stages. The
  button that closes it is the monitor's `Ending`: Done, Done that leaves
  after an update of Irisin, or Reload Home Screen when the run, failed or
  not, left the tweak loader's directories different (`TweakInjection`,
  read before the helper starts and after the installed list is read back;
  a daemon a tweak injects into is the tweak's own to restart). Touch and
  hold has Skip for Now, and a run Try Again follows keeps the change. An
  update of Irisin stays Done: registering stops the app, so nothing can
  follow it. A
  footnote under the list fades in while the helper finishes after the last row, and the helper's
  lines are on the log page and on the failed package's page, never on the
  list. The
  log file beside the pipe
  (`<root>/var/log/irisin-install.log`, previous run in `.previous`) is
  the same events as timestamped plain text. Add a case, not a prefix.
- **No tool is spawned for the home screen, and no icli ships.** `uicache`,
  `sbreload` and `killall` are gone and `uikittools` is not a dependency.
  icli is our own repository and is linked into `irisin-install` as the
  `IcliKit` library (`Packages/IrisinKit/Package.swift`, a minimum version,
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
  with a `rebuildIconCache` job, except under Irisin's own helper, which sets
  `IRISIN_INSTALLER_*` in every maintainer script's environment (dpkg sets
  none). **A transaction never registers or unregisters Irisin's own
  bundle:** depending on the system, LaunchServices stops the app it
  registers, halfway through its own update. The helper skips the bundle
  (found through the list that has the helper, never by name), and so do
  the file triggers of Irisin's own package (uikittools' `uicache -a` on
  `/Applications`). The app sends `registerOwnApplication` from its
  Updating App alert as it exits, and at the next launch, once per build,
  when LaunchServices still has an older build. On tvOS the helper lets
  the launchpad's process go first, ten seconds at most, and writes its
  `Info.plist` again before registering it (`prepareForRegistration`): a
  launchpad updated from the page was otherwise refused at every launch,
  and only a registration after that rewrite opened it. A removed bundle is
  unregistered after the transcript's `exit` (`finishAfterExit`). A fix
  to the LaunchServices code goes to the icli repository and arrives here as
  a version bump.
- **Peer authentication is the whole trust boundary.** Audit token (pid > 1,
  euid 0; 501 only for Irisin's own app at its exact path, since a client
  mobile could run would be root for whoever runs it), then the `wiki.qaq.irisin.client`, `platform-application`
  and `no-sandbox` entitlements, each strictly true, then the executable on
  disk: canonical (`realpath`, a NUL refused first), inside the install root
  by component or on the read-only volume at `/`, every directory from the
  install root down owned by root or a system account and writable by no one
  else, the file regular, root-owned, owner-executable and not group- or
  world-writable (`ExecutableAdmission`). Irisin's own app keeps its exact-path
  rule beside that. Before the first request field is read. This trusts
  every installed package that meets the checks; the entitlement is
  eligibility, not identity (Decisions below).
- **mobile reaches root only through the app, and the owner says yes.**
  A change to the system is staged once the owner confirms it with Face ID,
  Touch ID, Optic ID or the passcode (`OperationConfirmation`, on by
  default, asked at Execute, Try Again and a recovery operation; a device
  with no passcode is not asked). Every other client is root's, which the
  user grants with `sudo`. `irisin-cli` (`Documentation/CommandLine.md`) is
  such a client and has the app's Keychain groups, in the app's order
  (`Scripts/check-cli-entitlements.py`).
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
  An update of Irisin must finish where the bootstrap's shell is gone (a
  vphone set up without one): the package that places the helper itself
  (`SelfPackage`, never a name) may fail its postinst, prerm and postrm as
  a `scriptFailureIgnored` warning, its preinst still stops it, and once its
  files are placed the helper loads `irisind` itself at the end of the run,
  whatever the run did, a `daemonNotLoaded` warning and never a failure.
  The app has the same helper as itself, so the first update into this
  rule still runs under the old one.
- **Only what the bootstrap installs is listed, and nothing is converted.**
  The catalogue keeps a package's builds for the device's architecture and
  for `all` (dpkg's architecture-independent packages: certificates,
  keyrings, themes, metapackages) and drops every other build as the index
  is read (`readPackageIndex`); a package with no build left is not listed.
  A suite's directories are still probed past the device's own
  (`BootstrapArchitecture.probeOrder`), since a directory's name is not the
  architecture of what it holds (Procursus keeps its rootless packages in
  `binary-iphoneos-arm`), and an index whose every entry is for another
  bootstrap is an empty catalogue, not a failed refresh. There is no
  adapter, no Patch step and no compatibility setting: 5.0 removed them,
  with MachOKit. A `.deb` opened by hand or a record dpkg already has that
  is built for another bootstrap says Unsupported, and its alert suggests
  rebuilding it with Apelin. A catalogue written before 5.0 keeps another
  bootstrap's rows until its repository next refreshes, so the checks on
  architecture that remain on catalogue reads (`isSupportedOnDevice`,
  `versions(builtFor:)`, the pool's own) stay.
  The bootstrap the package was built for is
  `IrisinCurrentArchitecture` in the app's Info.plist, written by
  `package-deb.sh` per flavor; a build that was never packaged uses the
  bootstrap runtime's layout, never a vote of installed packages. A packaged
  Irisin never switches architecture to fit the device: startup compares
  that key with the independently detected bootstrap, alerts on a mismatch
  and does not open the interface.
  Install the matching official package; Irisin itself must not be converted
  with a patcher.
- **The queue's button says what its tap does.** Execute, and while files
  download Queue Install, which once tapped reads Cancel Auto Install in
  the delete colour and takes it back. On a system whose status has no
  `dpkg` the tap asks first (`QueueInstallChecks`): Bootstrap Install where
  the plan allows it, Install Anyway, which reads the files' `control.tar`
  member names (`ArchiveStream.debianControlMembers`) and names the
  packages that run maintainer scripts before anything is staged, or
  Cancel.
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
  under `Irisin/`, `IrisinShared/`, `IrisinLaunchpad/`, `IrisinDaemon/` or
  `IrisinInstall/` joins its target by existing, and one under
  `IrisinShared/` joins both the app and the launchpad. A folder inside a
  synchronized group cannot be left out of a target or added to one (Xcode
  honours a file in `membershipExceptions`, never a folder, and ignores
  `EXCLUDED_SOURCE_FILE_NAMES` there), so what both apps compile lives in
  `IrisinShared/`, and what the launchpad takes from `Irisin/Resources`
  (the string catalog and the recommended lists) is named there file by
  file. `make check` fails if Xcode rewrites `objectVersion`.
- **Everything builds through `Irisin.xcworkspace`.** It holds the project
  and every package under `Packages/`, and a package there stands in for a
  remote one of the same name anywhere in the graph. The Makefile passes
  `-workspace`, and `make check` fails on a package under `Packages/` the
  workspace does not list. Open the workspace in Xcode, not the project.
- **No Swift file names the SDK's XPC constant macros.** They come from
  `CIrisinXPC` through `IrisinXPC`; naming them in Swift links
  `libswiftXPC.dylib`, which iOS 15 does not have. `make check` greps for
  them and `verify-deb.sh` checks the load commands.
- **A process is started with `ProcessSpawn`, nowhere else.** The AppleTVOS
  SDK marks `posix_spawn` and its setup calls unavailable, though tvOS's
  libSystem exports them; `CIrisinSpawn` declares them again under labels
  naming the same symbols, for iOS and tvOS alike, and `ProcessSpawn` is the
  one Swift file that calls them. `make check` greps every other Swift file
  for `posix_spawn`, and the symbols are in `floor-imports.txt`, since a
  labelled declaration carries no availability.
- **On tvOS, RootHide or nothing.** `BootstrapSupport.serves(installRoot:)`
  takes, on tvOS, only an install root whose name libroothide would make
  (`RoothideRoot`): irisind will not start and irisin-install answers
  `helperMisplaced` anywhere else. iOS serves every root it always has.
- **No absolute build paths in a shipped binary.** `#file` is concise
  (`SWIFT_UPCOMING_FEATURE_CONCISE_MAGIC_FILE`), and a dependency that still
  spells `#file` in a default argument in Swift 5 mode leaks the *caller's*
  path — SnapKit before 6.0 did. `package-deb.sh` fails the build on one.
- **Nothing third-party links into `irisind`, and only icli's own
  dependency into `irisin-install`.** The daemon links `IrisinProtocol`
  and nothing else. The helper links `IrisinProtocol`,
  `IrisinInstaller` and, through it, `IcliKit`, which is ours and brings
  libarchive with it, and `IrisinPreparation`, which reads a submitted
  `.deb` with that same libarchive. Nothing else is added to either.
  `Packages/IrisinExternalClient`, the library other packages vendor into
  their own root process, links system libraries alone.
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
- **One asset catalog per app.** Everything the app draws from a file is in
  `Irisin/Resources/Assets.xcassets`; the launchpad's icons (tvOS brand
  assets with their Top Shelf images, the Vision Pro image stack) are in
  `IrisinLaunchpad/Resources/Assets.xcassets`, rendered from
  `Documentation/Icon` by `Scripts/render-launchpad-icons.sh`. Compiling
  the Vision Pro stack needs a visionOS simulator runtime on the Mac
  (`xcodebuild -downloadPlatform visionOS`), device builds included.
- **The launchpad links nothing third-party, and the page signs in to no
  vendor.** `IrisinLaunchpad` links IrisinProtocol, IrisinClient,
  IrisinVendor (the device's identity for repositories, never its
  Keychain), AptRepository and AptResolver (and WCDB, libsolv and
  libarchive with them), Dog and IrisinWeb; its interface is plain UIKit.
  `IrisinShared/` and `IrisinLaunchpad/` import none of the app's UI
  libraries, and `make check` greps for them. A paid package says so and
  does not install from a browser. Every change a browser asks for is put
  to the owner on the device first (`WebManagement.ask`, `WebRun`), Decline
  focused, one at a time; reads answer at once, and an operation's lines
  are polled from a feed (`OperationFeed`), not pushed.
- **Onboarding's recommended repositories are data, not code.**
  `Resources/Environments/default-list-<architecture>.plist`, one per
  bootstrap, and `default-list-managed.plist`, shipped empty for the
  jailbreak to overwrite: with any entry it is the list, whatever the
  architecture (`RecommendedRepositories`). No list recommends nothing, and
  the page has no such section. Each entry is a source line with optional
  inclusive iOS major bounds, which is how Procursus's per-release suite
  is picked. RootHide's bootstrap packages come from OwnGoal Stripe
  (`deb https://stripe.owngoal.dev 1900 main`, built for iOS and tvOS 16
  and later) on iOS 16 and later and on Apple TV, beside apt.owngoal.dev;
  iOS 15 keeps roothide's own Procursus build. `package-deb.sh` keeps the
  flavor's own list and the managed one and `verify-deb.sh` checks it; `PLIST_FILE_OUTPUT_FORMAT` keeps them
  XML, so the managed file's instructions reach the device.
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
  `Select` past the statement that made it. **The main actor reads and
  never writes.** SQLite has one writer, and a refresh holds the lock for
  as long as a repository's packages take, so a write asked for there
  waited up to a second (4.5.5's hangs): `RepositoryCenter.write(_:then:)`
  runs it off the main actor after every write asked before it, and a
  refresh writes its packages after every write asked before it began.
  FTS5 indexes nothing but its rowid, so a refresh drops a repository's
  search rows by the rowids its package rows keep (`searchRowid`), never
  by `repo`, which read every repository's rows. `Repository` keeps only its
  source, Release metadata and `packageCount`; the packages are in the
  database, never on the struct. Two things a list row asks for are never
  a query on the main actor. What dpkg reports installed and the install
  origins are `PackageIndex.installedSnapshot`, returned by
  `storeInstalled` off the main actor and committed with each reload. A
  repository package a row draws comes from `PackageCenter.lookups`
  (`PackageLookupCache`, an LRU on the main actor): a miss answers
  `.loading` and is read in one batch in the background, a repository
  written makes what is held stale and it is read again, and `loaded`
  wakes the row. A row that waits keeps every line it will have, so it is
  measured once.
- **The resolver reads the catalogue ahead, and never solves with a stale
  read.** What a solve does for every request alike (the catalogue
  decoded, every candidate's relations parsed and matched against every
  provider) is a `ResolutionPool`, read off the main actor by
  `PackageQueue`'s preflight once the packages settle (two quiet seconds,
  no refresh or operation running) and kept on the main actor; a tap
  solves only its own jobs against it, a tenth of the time. A pool
  answers only a snapshot of the same database at the same catalogue
  revision, with the same installed list, origins and architecture
  (`serves`), and a request for a package it does not
  hold gets a pool of its own: anything else is read again, so a pool
  kept too long costs time, never a plan. It is the one place the
  catalogue stays in memory between solves, and a memory warning drops
  it. `ResolverProbe bench` and `golden` measure and check it against real
  repositories (`Scripts/fetch-repository-indexes.py`); every resolver
  test solves both ways (`resolveBothWays`).
  A refresh is the one time a solve keeps a catalogue the database has
  moved past: it writes one repository after another, and a read in the
  middle is stale before it ends. While `obtainUpdateRemain()` is above
  zero, a solve takes the pool last read (`resolutionSnapshot(evenIfWritten:)`),
  and a repository written does not solve the queue or an open sheet
  again; the queue solves once when the last is written. An operation
  finishing is never held, and a refusal from the kept catalogue is solved
  once more against the one there is. Update All never takes the kept
  pool: which packages are updates is the catalogue's own answer, which
  nothing checks later, so it reads the catalogue the Updates page lists
  (an empty answer from a kept pool was "No changes" beside a list of
  updates). A plan so solved is checked, never
  trusted:
  `PackageQueue.currency(of:)` is current when the installed packages and
  settings are as they were and every package it installs is still
  offered as it was (`PackageIndex.withdrawn`). The sheet's Confirm and
  staging both ask (an install origin still counts as offered); a
  withdrawn package on Confirm is an alert with Check Again, which reads
  the catalogue now, and a plan staging refuses is solved again at once
  (`solveAgainNow`).
- **Every plan mends what a run that stopped partway left broken.** The
  packages before the one that failed keep their new versions, so an
  installed package can be left needing what is no longer there: apt
  2.6.0-2 beside libapt-pkg6.0 2.9.4-3 (issue 146), a dependency never
  installed, a Breaks not caught up with. libsolv keeps a package that was
  broken before as it is, and the final check refused every plan until
  the user found the one request that mended it. When the installed set
  fails that check (`PackageUniverse.broken`), the solve adds libsolv's
  verify (`Job(.verify, .all)`, from libsolv.xcframework 0.1.3) and keeps
  every package involved installed, so the mend installs and updates and
  never removes one the request does not; when nothing mends it beside the
  request, the request is solved as before and fails naming what is
  broken. A healthy installed set gets no extra job: `golden` answers alike.

## Layout

- `Irisin/` — the app: `Application/` (delegates), `Services/` (what only
  iOS has: `VendorAccount`, `OperationConfirmation`, translation),
  `Interface/`, `Extension/` (UIKit's), `Resources/`.
- `IrisinShared/` — what the app and the launchpad both compile:
  `Application/` (`AppPaths`, `AppEnvironment`, `AppBootstrap`),
  `Services/` (`PackageQueue`, `Installer`, `Downloads`,
  `Privilege/PrivilegedBackend`, `WebManagement`: the browser's calls, the
  owner's questions and the operation feed), `Extension/`.
- `IrisinLaunchpad/` — the launchpad, product `irisin` (bundle
  `wiki.qaq.irisin`, at `/Applications/irisin.app` like the app, which is
  how irisind admits it), tvOS 16 and visionOS 2: one screen with the
  address, the code and its QR code (`LaunchpadController`), the owner's
  question as the system's alert (`QuestionAlert`), its own tokens and
  asset catalog.
- `IrisinDaemon/` — the daemon, product `irisind`: listener, peer
  authentication, helper launch.
- `IrisinInstall/` — the helper, product `irisin-install`: one job
  from standard input, the transcript on standard output.
- `IrisinCLI/` — the command line, product `irisin-cli`, at
  `<root>/usr/bin/irisin-cli`: root only, the app's catalogue read-only,
  the queue cut down to one solve and one run, English only
  (`Documentation/CommandLine.md`). It finds WCDB in the app's
  `Frameworks` by `@executable_path/../../Applications/irisin.app/Frameworks`.
- `IrisinUnitTest/` — test bundle hosted in the app (`@testable import
  irisin`), for what only makes sense against the app's own types:
  `Services/Downloads/Downloader` against a `URLProtocol` stub, the
  operation page's reduction of the transcript (`OperationMonitor`,
  `OperationPackages`), queue resolution, notification bindings, the path
  list and the depiction's contact parsing.
- `Packages/IrisinKit/` — `IrisinProtocol` (`IrisinWire`, `InstallerJob`,
  `ExecutableAdmission`, `ExternalTransaction`, `BootstrapArchitecture`,
  `BootstrapSupport`, `ProcessSpawn`), `IrisinInstaller` (`BootstrapLayout`,
  `BootstrapAccounts`, `InstallerRunner`, `ToolSpawn`, `SystemProcess`),
  `IrisinPreparation` (`DebianPreparation`, a `.deb` into a prepared tree,
  the app's and the helper's), `IrisinClient` (`DaemonLink`,
  `JobTranscript`), `IrisinVendor` (a paid repository's Keychain
  names and every vendor request, the app's and `irisin-cli`'s alike, the
  stored `secert` spelling included), each with `swift test`.
- `Packages/IrisinWeb/` — managing a device from a browser
  (`Documentation/WebManagement.md`), served by the launchpad; an iOS switch
  is still to come. The server on Network.framework,
  the six-digit code, the HKDF key and the ChaCha20-Poly1305 envelope every
  call travels in. Its README is the contract the page and the device keep.
  Nothing outside the system.
- `WebUI/` — that page, built as Fila's is: React + webpack, TypeScript,
  pnpm (the version is `package.json`'s `packageManager`, run through
  corepack when there is no pnpm), no hand-written HTML. It is pure static
  output (`dist/index.html`, `app.js`, `app.css`, the icons) and talks to
  the device through the sealed calls only. The app's and the launchpad's
  *Build Web UI* phase (`Scripts/build-webui.sh`, in the app before Collect
  Licenses, which lists its runtime dependencies) builds it and copies
  `dist/` into `irisin.app/WebUI`; the server hands out `index.html` at `/` and the rest
  under `/_irisin/` by bare name, with a CSP that allows nothing inline.
  `scripts/sync-assets.js` takes the accent from `UIColor.buttonNormal` and
  the icon from AppIcon before every build. Its words are its own
  (`src/i18n.ts`, English and Chinese), outside the string catalogs, as
  Fila's are. `cipher.js` is checked against CryptoKit by IrisinWeb's tests.
  To look at it on the Mac: `IRISIN_WEB_DEMO=1 swift test --package-path
  Packages/IrisinWeb --filter WebUIDemo` serves `WebUI/dist` with made-up
  answers, so `pnpm watch` there plus a reload is the iteration loop.
- `Packages/IrisinExternalClient/` — the external clients' library and its C
  shim, no dependency on the rest of Irisin; `IrisinExternalContractTests`
  in IrisinKit holds its wire to `IrisinProtocol`'s.
- `Packages/<Name>/` — in-house or locally modified libraries
  (AptRepository, PackageDepiction, ...). Runestone and MarkdownView are
  vendored and cut down for size, and each README says from what and how:
  Runestone keeps the bash and JSON grammars alone, and MarkdownView is
  UIKit only, with no math and no code highlighting. A grammar or a feature
  put back is paid for in the app's binary.
  Every local package declares iOS 15, the app's own floor and what
  `IcliKit` asks of IrisinKit and everything above it;
  `Scripts/check-floor-sources.py` fails `make check` on one that does
  not, on an SF Symbol newer than the floor, and on a recommended list
  without one bootstrap suite (Procursus, or OwnGoal Stripe) for each iOS
  release from the floor up. PackageDepiction's views are
  laid out with SnapKit and configured with Then, like the app: a depiction
  is Auto Layout throughout, so its height is its own and nothing measures it.
  Everything with a usable upstream release is a remote package reference.
- `Configuration/`, `Packaging/`, `Scripts/`, `Makefile` — build inputs.

## Decisions

- **External clients (4.7).** irisind serves programs other than Irisin's
  app so that other packages install through Irisin rather than through
  dpkg behind its back (Apelin's session host first). Admission is a place
  and a shape, not a name: see the trust-boundary rule above and
  `Documentation/ExternalClients.md`. **The trust model: any installed
  package whose root-owned program meets the checks is trusted, not Apelin
  alone.** A package that can install, sign itself and leave a root-owned
  executable in root-owned directories is already a trusted participant;
  `wiki.qaq.irisin.client` is the public contract for third-party clients
  and says only that a program means to be one. It is not an identity and
  isolates no installed package from another. If that isolation is ever
  needed, it takes an identity a package cannot declare for itself, decided
  afresh, never another entitlement name.
- **External transactions live on disk, not in the daemon.**
  `<root>/var/lib/irisin/transactions/<id>/`, root's, 0700: the request, the
  helper's journal (its standard output, one `InstallerOutput` line per
  event, line n is event n, read back by sequence), the installed package's
  id and version. The daemon takes an exclusive `flock` on the journal that
  the helper inherits, so a journal with no `exit` that nobody holds is an
  interrupted run. `mkdir` makes an id taken: the same id and request twice
  answers from the record and installs once; a different request is
  `conflict`. Records go a week after their last event.
- **A submitted package is copied before it is read.** The client's
  descriptor reaches the helper as descriptor 3; the helper copies it from
  offset 0 into the transaction's directory, hashes the copy, refuses one
  that does not match the client's digest, and prepares and installs only
  the copy, removed when the run ends. The helper decodes it as root, unlike
  an app download, which is decoded as mobile: the client is a trusted root
  participant and the package's maintainer scripts run as root regardless.
  No resolver: missing dependencies fail at verifying, a removal never takes
  dependents with it, Irisin's own packages are refused.

## Strings

English is the source language and `zh-Hans` the reference translation the
other locales are made from, so a Chinese value that drifts from the English
drifts in every language after it. Everything the user reads is in one of
these, all under `Irisin/Resources/`:

- `Localizable.xcstrings` — everything the app says, plus the labels
  PackageDepiction's photo viewer asks for ("Share", "Close") and those of
  MarkdownView's code and table bars and sheets: a package's
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
  Release is built for size: `Configuration/Size.xcconfig` (`-Osize`,
  clang `-Oz`) reaches the project through `Release.xcconfig` and the
  packages through the Makefile's `-xcconfig`, since a package never reads
  the project's configuration files, and the executables export no symbols
  (`LD_EXPORT_SYMBOLS = NO`). A product is linked by its narrowest module
  (`OrderedCollections`, never the `Collections` umbrella): a Swift module
  linked in stays in the binary whole, used or not.
- `make deb` / `make deb-all` — roothide and rootless packages, verified.
- `make webui` — the browser page into `WebUI/dist` (the app's Build Web UI
  phase runs the same script in every build). pnpm reaches the registry
  directly; where a proxy is in the environment that it cannot pass, unset
  it for the build.
- `make build-appletv` / `make deb-appletv` — the launchpad (scheme
  `IrisinLaunchpad`), `irisind` and `irisin-install` (scheme
  `irisin-privileged`) for tvOS, and the Apple TV package, verified
  (`package-appletv-deb.sh`, `verify-appletv-deb.sh`, the floor imports
  against the AppleTVOS SDK with `floor-imports-appletv.txt` added). Needs
  Xcode's tvOS platform (`xcodebuild -downloadPlatform tvOS`). Its
  architecture is `appletvos-arm64e`.
- `make sim-appletv SIMULATOR=<udid>` / `make sim-vision SIMULATOR=<udid>` —
  the launchpad, Debug, on an Apple TV or Vision Pro simulator, installing
  into its container as `make sim` does. It serves on the Mac's own
  addresses, so a browser on the Mac (or the network) opens the page.
- `make install` — update an installation over `iproxy 2333 22`.
- `Scripts/prune-xcstrings.py Irisin/Resources/Localizable.xcstrings Irisin Packages`
  — after Xcode has marked catalog entries stale: a key still quoted in a
  Swift file of the app or a local package (a literal handed straight to
  AlertController, which the extractor cannot see) becomes `manual`, the
  rest are removed. Run it instead of letting Xcode delete translations on
  its own schedule.
- `Scripts/localize.py extract <dir>` then `merge <dir>` — the locales Fila,
  iGhostVT and CocoaInspector ship, and the six Irisin was asked for on its
  own (Bengali, Hindi, Indonesian, Swahili, Turkish, Yoruba). A locale is
  added there and in the project's `knownRegions`, nowhere else: the
  catalogs and `Settings.bundle/<locale>.lproj` are `merge`'s to write.
  `extract` writes one job per locale
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

- **One libarchive in the package graph.** icli depends on the
  libarchive.xcframework package, whose binary target is named
  `libarchive`; a second binary target of that name in
  `Packages/AptRepository` fails resolution ("multiple packages declare
  targets with a conflicting name"), so AptRepository takes the package's
  `ArchiveKit` product too, at a version icli accepts. Before 1.0.0
  that product was `LibArchive`, a name that differed from the binary
  module's by case alone, and on a case-insensitive volume the compiler
  refused it: "cannot load module 'LibArchive' as 'libarchive'". Swift
  imports `ArchiveKit` now; the C shim that worked around that is gone.
- **A clean build says nothing about the deployment target.** A bump of
  anything that follows the standard library closely is proven by launching
  a packaged Release build on a device below the newest iOS before it
  ships. `Scripts/audit-ios-floor.sh`, the
  template's (platformize-app-ios), runs over the app, `irisind` and
  `irisin-install` before every package is made and fails on a runtime
  symbol, library, or build version above the deployment target; a fix to
  it goes to the template first.
- **A strong import the floor lacks stops the process in dyld, and the
  build never says so.** icli's `xpc_user_sessions_get_foreground_uid`
  (iOS 16) stopped Xrash on iOS 15.8.6 before `main`. `make deb` runs
  `Scripts/check-floor-imports.py` over the app, `irisind` and
  `irisin-install` after the audit: every strong import must be declared
  outside a comment in an iPhoneOS SDK header (the compiler weak-links
  those from their availability) or listed in `Scripts/floor-imports.txt`,
  and no library iOS 16 or later introduced may be loaded strongly. A
  private symbol is listed only once iOS 15.0 is known to export it;
  otherwise it is looked up with `dlsym`, as `irisind` does
  `xpc_copy_entitlement_for_token`, with SecTask behind it. The list's top
  half is icli's own; keep the two in step.
- **A device build links the iOS 27.1 SDK, and CI's is Xcode 27.1's.** On
  an iPhone Duo the SDK decides the layout: built with 27.1 the app fills
  either display edge to edge and its bars stand on the side, a leading or
  trailing safe-area inset (the outer display, and the inner one in
  landscape); built with 27.0 it is kept clear of the status bar's side, and
  before 27 it sits in a box. `_build-ios` refuses an older iPhoneOS SDK
  (`MINIMUM_IPHONEOS_SDK`), and the build job runs on the `xcode-27` runner
  with Xcode 27.1 chosen by name, not the image's newest (a 27.2 release
  candidate); the host tests stay on `macos-26`, and so does the Apple TV
  package, in a job of its own: icli 0.10's `tvos-iokit-stub.sh` retargets
  the iPhoneOS SDK's `IOKit.tbd` by `arm64e-ios`, Xcode 27's also names
  `arm64e.x1-ios`, and the script stops at it ("still names an iOS
  target"), so `make deb-appletv` needs Xcode 26 until icli retargets that
  too. A third job puts the three packages, the dSYMs and their checksums
  in the one artifact `release.yml` takes. A page keeps to the safe
  area on every edge: a scroll view adjusts only the axis it scrolls on, and
  the dashboard's flow layout, laid out from its own content inset, put its
  last column and the Featured See All under the bar's Settings button
  (`contentInsetAdjustmentBehavior = .always` now). Xcode 27.0 has no 27.1
  simulator SDK, but a 27.0 simulator build takes the 27.1 layout on the
  27.1 runtime once both places that name the SDK say 27.1, the main
  executable's `LC_BUILD_VERSION` (`vtool -set-build-version`) and the
  `DT*` keys of its `Info.plist`, and it is signed again: the load command
  alone changed nothing. A layout check only, never a package.
- **LNPopupController crashed the iPad on launch and is gone.** Its
  `UISplitViewController` category asked a legacy-style split controller
  `isShowingColumn:`, which iOS 26 answers with an exception, and nothing
  used the popup bar any more. Do not add the package back; a bottom bar is
  a view of our own.
- **A stale dpkg files list breaks every install on the device.** A `.list`
  under `Library/dpkg/info` with a bare `/` or an empty line makes dpkg abort
  with "contains empty filename" for *any* package. Strip those lines.
- **A bootstrap's users and groups are not iOS's.** Procursus builds dpkg
  against libiosexec, whose `getpwnam` and `getgrnam` read the bootstrap's
  `etc/spwd.db` (`etc/pwd.db` for anyone but root) and `etc/group`, and
  never the system's. redis-tools adds `redis` there and redis-server names
  it in a statoverride; through 5.0.3 the helper asked iOS, which has no
  `redis`, and every install on that device stopped at "Unknown
  statoverride account", whatever it installed. `BootstrapAccounts` is
  libiosexec's two readers again, and both the statoverride's names and an
  archive's owner names go through it, in the helper: the prepared
  manifest carries the names, and the app, as mobile, never decides. A
  name is the bootstrap's or unknown, never the system's, even when the
  bootstrap has no account files; only a run without a bootstrap asks iOS.
  An unknown name in the statoverride still stops every install, as it
  stops `dpkg -i`, and no longer stops a removal, which dpkg never reads
  the statoverrides for (`Documentation/InstallerCaseStudies.md`).
- **launchd may print the daemon under `user/501` even though it is a system
  daemon.** IcliKit reads both the system proxy and foreground-user record;
  trust the helper transcript and the app's journal.
- **RootHide renames the bootstrap root at every jailbreak and rewrites the
  daemon plists to match.** Its launchctl patches each file in
  `Library/LaunchDaemons` in place: one marked `__Patched` has the old root
  taken off `ProgramArguments[0]` before the new one goes on, one without
  only gets the new root in front. The helper writes the kernel path (IcliKit
  translates nothing), so `LaunchDaemon.preparePlist` writes the mark with
  it. Through 4.3.5 it did not: after the next jailbreak the program was new
  root + old root, launchd answered `78: EX_CONFIG` once and left the job at
  `spawn scheduled`, and the app, which never falls back beside a daemon
  plist, said Waiting for good. `launchctl print system/wiki.qaq.irisind`
  shows the doubled `program`; installing the package again repairs it.
- **`extrainst_` is a maintainer script on every iOS bootstrap.** Procursus
  patches dpkg (`build_patch/dpkg/extrainst.diff`) to run the new one in
  `process_archive` once the files are extracted, before the old postrm:
  `install`, or `upgrade <old version>`. openssh-server has no postinst and
  loads sshd from it; through 4.5.11 the helper only kept the file, and sshd
  waited for the next boot. `PackageTransaction.runExtrainst` runs it there,
  a failure aborts the unpack, and the queue's package page lists it.
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
