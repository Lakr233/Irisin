# Apple TV: the privileged layer

`irisind` and `irisin-install` on tvOS 17 and later, inside a RootHide
bootstrap, doing the same closed jobs they do on iOS. The app on tvOS is the
launchpad (`IrisinLaunchpad`), which serves a page a browser manages the
device from (`Documentation/WebManagement.md`); everything here is what it
stands on.

## What was decided

| | |
| --- | --- |
| Floor | tvOS 17: `UIContextMenu` is there, and nothing below it is served |
| Bootstrap | RootHide alone. A rootful or rootless Apple TV is refused by both the daemon and the helper before either does anything |
| Package architecture | `appletvos-arm64e` |
| `posix_spawn` | through a C shim, on iOS as well as tvOS |
| Home screen | PineBoard, through icli 0.10.0 and later |

## Starting a process

The AppleTVOS SDK marks `posix_spawn` and every call that sets it up
`__API_UNAVAILABLE(tvos)`, and Swift refuses to name them. tvOS's libSystem
exports every one of them all the same (`libSystem.B.tbd` lists
`_posix_spawn`, `_posix_spawnattr_*`, `_posix_spawn_file_actions_*`), as
iOS's exports `posix_spawn_file_actions_addchdir_np`, which the iPhoneOS SDK
marks unavailable too and the helper used to reach with `@_silgen_name`.

`CIrisinSpawn` is a header-only module: each function the daemon and the
helper use, declared again under an `irisin_` name with an assembler label
naming the libSystem symbol and no availability attribute. Nothing is
defined, nothing is looked up at run time, and the binaries import
`_posix_spawn` itself.

`ProcessSpawn`, in IrisinProtocol because that is all `irisind` links,
starts a program the one way both callers want: every signal at its
default and none blocked, every descriptor closed but the ones named,
optionally in a session of its own (the daemon's helper) or another working
directory (a maintainer script). A file action that cannot be added fails
the spawn instead of being dropped. `DaemonServer.spawnHelper` and
`ToolSpawn` both call it, and no other Swift file names a `posix_spawn`
function: `make check` greps the app, the daemon, the helper, the command
line and every package's Swift but `ProcessSpawn.swift` for `posix_spawn`.

## Which bootstrap is served

`RoothideRoot` holds libroothide's `is_jbroot_name` (`.jbroot-` and sixteen
hex digits, the last byte the xor of the seven before it), moved out of the
app's `JailbreakRoot` so the app, the daemon and the helper read one rule.

`BootstrapSupport.serves(installRoot:)` answers whether this system serves
a bootstrap at that install root:

- **iOS:** every install root it served before. Nothing changes.
- **tvOS:** only a RootHide root: the install root, which the daemon and
  the helper peel off their own `proc_pidpath`, ends in a name
  `RoothideRoot` accepts. An empty install root (rootful) and `/var/jb` or
  whatever it links to (rootless) are not. This is stricter than iOS's
  rule, which takes any other root holding a `usr/libexec`, because tvOS
  has no older install to stay compatible with.

`irisind` asks right after it finds its install root, before its listener
exists, and exits `EX_CONFIG` when the answer is no, as it does when it is
not at its installed path. `irisin-install` answers such a job with
`helperMisplaced` and `EX_CONFIG`: a helper outside a bootstrap this system
serves is misplaced, and the failure needs no new case or string.

`BootstrapArchitecture` gains `appleTVRoothide`, raw value `appletvos-arm64e`.
An external client's package must name it or `all`: on tvOS the helper's
`nativeArchitecture` is `appleTVRoothide`, so an iOS RootHide package
(`iphoneos-arm64e`) is refused there as it is on a rootless iPhone.
`probeOrder` is iOS's and stays so: which index directories a tvOS suite
probes is decided with the name.

`IrisinWire.clientPaths`, the exact path that admits Irisin's own app as
mobile, is the launchpad's on tvOS, `/Applications/irisin.app/irisin` as on
iOS: it is the one mobile client, and every other is root's.

## The system's processes

`SystemProcess` names the processes the helper signals, per system:

| | iOS | tvOS |
| --- | --- | --- |
| home screen (safe mode: `SIGSEGV`) | SpringBoard | PineBoard |
| respring fallback (`SIGTERM`) | backboardd | backboardd |
| AirDrop reload (`SIGKILL`) | sharingd | none |

A respring is icli's first (PineBoard's on tvOS, from icli 0.10.0, which
waits for FrontBoard and stops PineBoard through launchd); backboardd is
the fallback on both, and that PineBoard comes back after it on tvOS is
still to be seen on a device. `reloadAirDrop` on tvOS fails as `invalidJob`
(status 64): tvOS has no AirDrop, and no one on tvOS sends it. Whether a
tweak injector on tvOS enters safe mode on PineBoard's `SIGSEGV` is the
injector's to honor, as it is on iOS.

## icli

IcliKit is linked on iOS and tvOS (`.when(platforms: [.iOS, .tvOS])`),
from icli 0.10.0. On tvOS registration lists bootstrap apps as user apps,
since PineBoard disables a system app tvOS did not provision. IcliKit links
IOKit, which tvOS ships and the AppleTVOS SDK leaves out: the tvOS build
links against the stub icli's `scripts/tvos-iokit-stub.sh` makes from the
iPhoneOS SDK. icli's own sources include IOKit's headers, and a package
target never reads a native target's settings, so the stub reaches every
target through xcodebuild's command line
(`FRAMEWORK_SEARCH_PATHS='$(inherited) <stubs>'`), made from the resolved
icli checkout before the build.

## Building and packaging

- `irisind` and `irisin-install` build for `appletvos` beside `iphoneos` and
  the simulator the app's tests run in (`SUPPORTED_PLATFORMS`), with `TVOS_DEPLOYMENT_TARGET = 17.0` in
  `Base.xcconfig`, through the shared scheme `irisin-privileged`. xcodebuild
  refuses a tvOS destination until Xcode's tvOS platform is installed
  (`xcodebuild -downloadPlatform tvOS`).
- The tvOS package carries the launchpad, the daemon, the helper and the
  daemon's launchd plist, with an empty prefix (RootHide's dpkg relocates
  it), the architecture `appletvos-arm64e` and `Depends: firmware (>= 17.0)`.
  Its postinst makes the launchpad's data folder by the iOS postinst's rule,
  loads the daemon and registers the app (`rebuildIconCache`), except when
  Irisin's own helper runs it. The launchpad is signed with
  `irisin-launchpad.entitlements`: the client entitlement, no sandbox, the
  network server, and no keychain. vphoned's `bootstrap.install`, which
  until now allowed the package's missing app on `appletvos-*`, has an app
  to register and a data folder to make from this release on.
- `check-floor-imports.py` reads the AppleTVOS SDK and tvOS 17 for the
  tvOS binaries (`--sdk`, `--floor`), with IOKit's names read from the
  stub's headers, since the AppleTVOS SDK has none, and what a tvOS 17
  target adds in `floor-imports-appletv.txt`. The spawn calls are listed in
  `floor-imports.txt`: their labelled declarations carry no availability
  for the compiler to weak-link by, and every one is older than both
  floors. `audit-ios-floor.sh`, the template's, reads iOS's simulator
  runtimes and is not run for tvOS: the packager checks each binary's
  platform and minimum instead.
- The package is `package-appletv-deb.sh`'s and `verify-appletv-deb.sh`'s,
  scripts of its own beside iOS's; `make check` checks its control file's
  `firmware` dependency, and `check-floor-sources.py` the tvOS floor of a
  package that declares one.
- `IrisinExternalClient` declares tvOS 17, so a program on tvOS can be a
  client; the test client below is one.

## How it is tested

The tvOS guests (`tv4k` on jp-01, `tvhd` on jp-02) have no bootstrap, so a
RootHide root is made by hand: a directory with a valid `.jbroot-` name under
`/var/containers/Bundle/Application`, holding `usr/libexec/irisind`,
`usr/libexec/irisin-install`, `Library/LaunchDaemons/wiki.qaq.irisind.plist`
and a dpkg database at `Library/dpkg` whose status lists `firmware`. Every
directory from the root down is root's and writable by no one else, as the
daemon's admission requires of a client's. There is no shell, so a test
package has no maintainer scripts. Programs run as root through vphoned.

The root also holds an empty `Applications` (icli refuses to refresh a
directory that is not there) and `var`.

1. Refusals: copies of the helper and the daemon in a root that is not
   RootHide's, run directly, answer `helperMisplaced` and exit 78
   (`EX_CONFIG`); `reloadAirDrop` is `invalidJob` (64). `/usr/libexec` is on
   the sealed system volume and cannot be written, and a refused helper
   cannot load a daemon, so the daemon is run by hand. The rule itself is
   tested on the Mac (`BootstrapSupportTests`).
2. The helper directly: `prepareUserHome`, `rebuildIconCache`, `respring`
   (PineBoard's pid changes), its log in the root. A transaction is
   exercised through the daemon below, which composes one.
3. The daemon: `bootstrapIrisinDaemon` through the helper, then a client
   built on `IrisinExternalClient` for tvOS, root-owned in the root's
   `usr/libexec` with the three client entitlements, run as root:
   `serviceInfo`, `submitInstall` of packages for this bootstrap and for
   `all`, an upgrade, an iOS RootHide package refused, `removePackage` of
   both, `respring`, and `bootoutIrisinDaemon`.

Passed on both guests on 2026-10-26: `tvhd` (Apple TV HD template) on jp-02
and `tv4k` (Apple TV 4K template) on jp-01, tvOS 26.6, with the binaries
from `make deb-appletv`. tvOS 17 itself is untested: no guest runs it.

## Irisin updating itself

A launchpad updated from the page asks for `registerOwnApplication` as it
leaves, as the iOS app does. Through 5.0.2 it was then refused at every
launch: PineBoard answered `Denying open-application request for reason:
Disabled`. Registering it again changed nothing (`rebuildIconCache` found
it unchanged), a respring neither, and changing the mode of its
`Info.plist` neither; registering it once its `Info.plist` had been written
again, by `files.push` or `files.plist_set` over vphoned, opened it. The
helper on tvOS now lets the launchpad's process go first, ten seconds at
most, and writes each of Irisin's own `Info.plist`s again, the same bytes
under a new inode and time, before it registers them. The helper that does
this is the one the update installs, so an update from 5.0.2 gets it too.
Found on `tv4k` (tvOS 26.6) on 2026-10-28. Whether an update of another
package's app needs the same is open: no other app is published for this
bootstrap yet.

## Open questions

- What loads `<root>/Library/LaunchDaemons` on a RootHide Apple TV after a
  re-jailbreak, and whether its launchctl rewrites plists marked
  `__Patched` (`LaunchDaemon.preparePlist`) as RootHide's does on iOS.
- Which tweak injector there is on tvOS, and whether it takes PineBoard's
  `SIGSEGV` as the request for safe mode.

iOS is tested as every release is: `make harness`, `make build`, and the
package on the RootHide guests (`ios27`, `ipad27`).
