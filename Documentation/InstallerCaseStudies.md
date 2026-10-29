# Installer case studies

Failures of the native installer that reached a device, what caused them,
and what now keeps them from coming back. Each one names the dpkg or apt
behavior the fix follows. See `NativeInstaller.md` for the installer itself.

## dpkg's own upgrade (2026-10-29)

### What happened

On a RootHide iPhone (iOS 16, OwnGoal Stripe's `1900` suite), the update of
dpkg from 1.21.21 to Stripe's 1.22.6-1 stopped at unpacking: "Package data
cannot overwrite the package database". Every retry stopped the same way.
Apple TV's dpkg from the same suite has the same shape.

### Why

dpkg's package ships the database's own directories (`/Library/dpkg`,
`info`, `parts`, `updates`, `alternatives`) and `/var/lib/dpkg` as a link
to `/Library/dpkg`. `location` refuses a database path for anything but a
directory, and it is told an entry's kind by the overload that takes the
entry. `removeOldFiles` asked where every *new* path leads, to keep an old
path that reaches a new file through a directory link, and asked it by path
alone, so `/Library/dpkg` was taken for package data written over the
database. That question is asked only when the old version had paths the
new one drops, which 1.21.21 has (seven: man pages and their directories),
so a first install and a reinstall of the same version went through and the
upgrade did not. The step in the message, unpacking and not verifying, says
the device's `Library/dpkg` is the directory and `var/lib/dpkg` the link,
as on the vphones: the other way round, the link entry itself would be
refused at verifying.

### What changed

That question skips a database path, as the loop over the old paths below
it already did. A file or link inside the database is still refused at
verifying and again when it is placed, so only a directory is skipped, and
a directory has no `FileIdentity`: for every path that did not stop the run
the answer is the one it was.

Tests: `DpkgParityTests` upgrades a package shaped as Stripe's dpkg (the
database's directories, the `var/lib/dpkg` link the bootstrap already has,
a man page the old version had and the new one drops) on rootless `/var/jb`,
on RootHide, and on RootHide with `var` linked through `private/var` to a
directory outside the root. All three stopped with the device's message
before the change. A review ran Stripe's real package, prepared as the app
prepares it, through install, upgrade, reinstall, downgrade, removal and
purge on the same three layouts.

### On the vphones

jp-01's ios264 (iOS 26.4) and ios27 (iOS 27.0.1), RootHide with dpkg
1.21.21 and `var/lib/dpkg` a link to `Library/dpkg`, as Stripe's package
ships it. A test package shipping the same directories and link, version 1
with one file more than version 2, through `irisin-cli`:

- The released 5.0.4 installed version 1 and stopped version 2 at unpacking
  with the device's message, on both, and put version 1 back.
- The fix upgraded to version 2 on both: the dropped file gone,
  `Library/dpkg` and the link as they were. Removing the package left both
  too, and the installed list as it was before the test. `tree` installed
  and removed, and the app launched and came to the front.
- The device's own `dpkg -i` of the two versions and `dpkg -r` gave the
  same result. `dpkg --audit` and `apt-get check` found nothing new after
  any step.
- Stripe's dpkg itself was not installed there: it needs Stripe's
  `roothide` and `libiosexec1`, newer than the vphones'.
- Each guest was put back on the Irisin it had, with no test package.

## A statoverride naming the bootstrap's own user (2026-10-28)

### What happened

Apelin asked Irisin 4.7.5 to install a toolchain package on a RootHide
vphone, and the helper stopped before verifying anything: "Installation
stopped: Unknown statoverride account". The device's statoverride file had
two lines that redis-server's postinst writes,
`redis redis 640 /etc/redis/redis.conf` and the same for
`sentinel.conf`, and every install on that device stopped the same way,
whatever it installed.

### Why

The helper named statoverride accounts with the system's `getpwnam` and
`getgrnam`. The device's dpkg never does: Procursus builds it against
libiosexec, whose header turns both into `ie_getpwnam` and `ie_getgrnam`,
and on a rootless or roothide bootstrap those read the bootstrap's
`etc/spwd.db` (`etc/pwd.db` for anyone but root) and `etc/group`
(libiosexec 1.3.1's `getpwent.c` and `getgrent.c`, unchanged in
roothide's fork). redis-tools adds `redis` there; iOS has never heard of
it. A probe on the device gave `getpwnam("redis")` NULL from
`libsystem_info` and `ie_getpwnam("redis")` uid 1001 from libiosexec.

dpkg is no more forgiving of a name it cannot find: `ensure_statoverrides`
stops at one anywhere in the file. Only the lookup was wrong.

The same lookup named an archive entry's owner, in the app, as mobile:
`tar_entry_update_from_system` asks libiosexec there too, so a file the
archive gives to a bootstrap-only user kept the number beside the name.

### What changed

- `BootstrapAccounts` is libiosexec's two readers again, decision for
  decision: the db(3) hash keyed by `_PW_KEYBYNAME` and the name, the
  1024-byte record and `MAXLOGNAME` limits, `grscan`'s rules for a line of
  `etc/group`. A bootstrap's files answer alone, and a bootstrap without
  them knows no names, as libiosexec there does not; only a run without a
  bootstrap (rootful, the Mac harness) asks iOS.
- `PackageOverrides` names statoverride accounts through it, one instance
  per reading of the database (after each preinst, before each removal),
  and an unknown one says which user or group, and for which path.
- The prepared manifest carries an entry's user and group names beside
  its numbers (`PreparedEntry.userName`, `groupName`), and the helper
  decides: the statoverride's owner, else the names as the bootstrap knows
  them, else the numbers (`PackageOverrides.owner`). A manifest without
  names installs by its numbers, as before.
- A transaction that unpacks nothing reads no statoverrides, as dpkg reads
  them only in `archivefiles`. On the vphone, `dpkg -r` removed a package
  past an override naming a user nobody has, where Irisin stopped; with the
  override the device had, Irisin could not even remove redis-server.

Tests: `BootstrapAccountsTests` reads files written as `pwd_mkdb` and base
write them, as root and as anyone else; `DpkgParityTests` installs past a
`redis` statoverride, stops at an unknown user or group with its name and
path, removes past one, and gives archive owners as above. With the
system's lookup put back, the statoverride tests fail as the device did,
and with the statoverrides read for every transaction the removal does.
A copy of libiosexec 1.3.1's two readers, compiled on the Mac against the
same fixtures as root and as mobile, gave the same answer for every name.

### On the vphones

jp-01's ios264 (iOS 26.4) and ios27 (iOS 27.0.1), both RootHide with
dpkg 1.21.21 and libiosexec 1.3.1. A user and group `irisintest` (1077)
went into the bootstrap's `master.passwd` (then `pwd_mkdb`) and `group`,
and `dpkg-statoverride --add irisintest irisintest 640` named a file of a
test package whose archive gives one file to `irisintest` (777:778 beside
the name) and one to `root` (501:20 beside the name).

- 5.0.3 stopped installing the package at "Unknown statoverride account",
  on both.
- The fix installed it on both: the overridden file 1077:1077 0640, the
  named file 1077:1077, the other 0:0. The device's own `dpkg -i` gave the
  same three owners.
- With a line naming a user nobody has added, Irisin stopped the install
  with that user and path, and `dpkg -i` stopped too ("unknown system user
  … in statoverride file"). Irisin removed the package past it, as
  `dpkg -r` did.
- The app launched and came to the front on both afterwards. Each guest
  was put back with its account files, no statoverride file, and the
  released 5.0.3.

## Irisin closing during its own update (2026-10-18)

### What happened

Updating Irisin to 4.7.0 from the app closed the app partway through, before
the operation page showed how the update went. Registering an app with
LaunchServices can stop it while it runs (icli's `registerApp` says so), and
a self-update of Irisin registered the running `irisin.app` three times:

1. **Irisin's own postinst** piped `rebuildIconCache` into the helper, which
   is icli's `refreshApps` over `/Applications`: the bundle's build changed,
   so it was registered again, in the middle of the transaction.
2. **uikittools' file trigger.** `interest /Applications` in its
   `triggers`; its postinst runs `uicache -a` when anything under
   `/Applications` changes, Irisin's own bundle included.
3. **The helper itself** registered every bundle the run changed
   (`reconcileApplications`) once the database had committed. A removal of
   Irisin unregistered it the same way, before the transcript ended.

### What changed (4.7.1)

- The helper puts `IRISIN_INSTALLER_VERSION`, `_BUILD`, `_PROTOCOL`,
  `_CLIENT` (and `_TRANSACTION` for an external client) in every maintainer
  script's environment (`InstallerIdentity`; the version is the helper's own
  Info.plist, linked into the binary). dpkg sets none of them. Irisin's
  postinst skips its `rebuildIconCache` when the version is set; under dpkg,
  Sileo or Zebra it still registers the app.
- `SelfPackage` knows Irisin's bundles: those in the archive that places the
  helper and in its installed list (a renamed bundle on both sides), or in
  the list of the package being removed that has the helper. Never by name.
  Files in those bundles, and the directories above them, activate no file
  trigger for Irisin's own package. Its other files still do.
- `reconcileApplications` leaves Irisin's bundles alone. An updated one is
  registered by the new `registerOwnApplication` job, which the app sends
  from its Updating App alert as it exits. An app stopped before then finds
  LaunchServices one build behind at the next launch and asks once per
  build (`OwnRegistration`). A removed one is unregistered by
  `finishAfterExit`, after the helper has written `exit` and closed the pipe.
- The transaction's log is opened with `O_APPEND`: the helper the postinst
  starts appends to the same file, and the transaction's own descriptor
  wrote over those lines at its offset.

Tests: `OwnApplicationTests` (each fails with the fix taken out, save the
environment ones). The postinst was run on a Mac with a stand-in helper,
with and without the variable.

### On the vphones

On both vphones (iOS 26.6.2 and 27.0.1, RootHide) the 4.7.0 → 4.7.1 update
registered the running app three times and the app kept its pid: there the
registration does not stop it. Whether it does depends on the system, so
the fix stays whatever the vphone shows. `dpkg -i` of 4.7.1 over itself
registered the app through the postinst as before (build 474 read back from
LaunchServices).

### Still open

- **The 4.7.0 → 4.7.1 update** runs 4.7.1's postinst under 4.7.0's helper,
  which sets no variable and still registers the bundle: that one update can
  still close the app.
- **Updating from 4.7.1 through the app** was not run on a device before
  the release.

## ElleKit and the tweaks around it (2026-09-18)

### What happened

A roothide iPad (Dopamine, jbroot
`/var/containers/Bundle/Application/.jbroot-…`) installed three packages
from the queue: Colorful Wallpaper X, which depends on `mobilesubstrate` and
`preferenceloader`, then ElleKit (`Provides: mobilesubstrate`) and
PreferenceLoader.

1. **First run.** The helper unpacked Colorful Wallpaper X first, which put
   its dylibs in a real `/Library/MobileSubstrate/DynamicLibraries`.
   ElleKit's preinst then failed: `mkdir` died of a bus error inside the
   script, an intermittent fault of the jailbreak. The helper ran
   `postrm abort-install` and stopped.
   - The row said "Failed while unpacking" and the headline said "Unable to
     unpack ellekit", although nothing had failed to unpack.
   - The failed page still showed "Finishing installation…" under the list.
2. **The retry.** ElleKit's preinst succeeded this time. It moved Colorful
   Wallpaper X's dylibs into `/usr/lib/TweakInject` and replaced the
   directory with a link to it. The helper then refused ElleKit's own link:
   `/Library/MobileSubstrate/DynamicLibraries is owned by
   wiki.qaq.colorfulwallpaperx; Replaces is required`.
3. **The simulator.** ElleKit (rootless, installed first), then Aemulo:
   `Directory collides with a file: var/jb/Library/MobileSubstrate/DynamicLibraries`.

### Why

Each numbered cause has a regression test named after it.

1. **Unpack order.** `TransactionPlanner` unpacked in the resolver's index
   order: installed packages, then repository URL, then name. apt's
   `OrderUnpack` puts a package's Depends and Pre-Depends targets first,
   through Provides. ElleKit's preinst was written for a system where
   nothing has used `DynamicLibraries` as a directory yet, so it has to run
   before the tweaks that use it. Test: `dependenciesUnpackBeforeTheirDependants`.
2. **A link over a directory.** dpkg's `tarobject` leaves a path alone,
   and skips the file-conflict loop, when the archive has a symbolic link
   and the path already is a directory, or a link to the same directory
   (`linktosameexistingdir`). The helper exempted only directory entries.
   Test: `loaderAfterTheTweakKeepsBothClaims`.
3. **Link text on roothide.** libroothide's vroot writes an absolute link
   target as the kernel path it means: the jbroot plus the target, or `/x`
   for `/rootfs/x`. Its `readlink` and `lstat` translate the text back and
   patch `st_size` to match. The helper wrote archive targets verbatim, so
   every absolute link it installed pointed at the system volume, ElleKit's
   `TweakLoader.dylib` among them. `BootstrapLayout.linkText` now writes
   what vroot writes. Test: `roothideLinkTextIsTheKernelPath`.
4. **Link text in the simulator.** Rootless packages keep `/var/jb` in their
   links, and the Mac has no `/var/jb`. `PackageFilesystem.physicalPath`
   resolves every path component by component and maps that prefix to the
   mount (`BootstrapLayout.linkedPath`). Test:
   `tweakAfterTheLoaderLandsInTweakInject`.
5. **roothide's `/var`.** The jbroot's `var` links through `private/var` to
   an app group container outside the jbroot. The helper refused every
   package path under `/var` as "traverses a symlink outside the
   bootstrap". That container is now an allowed place for files. Test:
   `roothideVarIsOutsideTheRoot`.
6. **Disappearing ElleKit.** `disappearOthers` counted every directory as
   shared. ElleKit's only path no tweak lists is `usr/lib/TweakInject`, so
   the first tweak installed after ElleKit made it disappear, and removing
   that tweak then deleted ElleKit's link. dpkg's `filesavespackage` lets a
   path save its package unless the new archive or a third package lists
   it. Test: `ownDirectorySavesAPackage`.
7. **Upgrading through the link.** A tweak whose update moves its dylib
   from `DynamicLibraries` to `TweakInject` lost the new file. The old path
   is the new file through the link, and the helper removed it. dpkg's
   `pkg_remove_old_files` keeps an old path with the same device and inode
   as a new file. Test: `upgradeKeepsTheOldPathOfTheNewFile`.
8. **A failed rollback.** Restoring a file into a directory the upgrade had
   already removed failed. The journal stayed behind, and every later
   transaction failed while recovering it. Test:
   `rollbackRecreatesARemovedDirectory`.
9. **Prose where a case belonged.** The failure event carried the script's
   exit as text. The last script the app heard of was the abort script, so
   the app could not tell which script had failed. `scriptFailed` names the
   script and its status, and the row now says "The preinst script failed".
   Test: `preinstFailureIsTheScriptsAfterItsAbort`.
10. **The footnote.** A table's update animation sets its footer view's
    alpha back to 1. The snapshot that added the failure row showed the
    footnote, which had never been turned on for that run. The label
    fades now, not the footer.
11. **Found while reviewing.**
    - A package that dropped from installed lost its Config-Version, so its
      next postinst heard `configure ""`. Test:
      `failedTriggerKeepsTheConfiguredVersion`.
    - A step was credited to whichever package ran the last script. Test:
      `testStepBelongsToThePackageThatOpenedIt`.
    - Removals ran dependencies before their dependants. Test:
      `dependantsAreRemovedBeforeTheirDependencies`.
    - A package left needing reinstallation blocked the reinstall that
      repairs it. Test: `unfinishedInstallIsRepairedByInstallingItAgain`.
12. **Found by comparing with dpkg's source.**
    - A removal that stopped halfway dropped Config-Version. Test:
      `failedRemovalKeepsTheConfiguredVersion`.
    - A diverted path neither saved a package from disappearing nor stayed
      in its owner's list. Tests: `divertedPathSavesTheDiverter`,
      `diverterLeavesTheDivertedPathToItsOwner`.
    - An old conffile that is the new one through a directory link stayed
      in the field as obsolete. The new path got no hash, so an unchanged
      file got a `.dpkg-dist`. Test:
      `conffileBehindADirectoryLinkHandsItsHashOver`.
    - A tweak unpacked ahead of a provider that was waiting on its
      Pre-Depends, which is the first failure again. The tweak now waits
      too, unless waiting gets nowhere. Tests:
      `dependantsWaitForADependencyThatWaits`,
      `waitingGivesWayWhenItGetsNowhere`.
    - A failed removal could not be retried. dpkg refuses to remove only a
      package that needs reinstalling. Test:
      `unfinishedRemovalIsRepairedByRemovingItAgain`.

### The false lead

The first diagnosis came from `ls -l` and `stat` on the device. Both showed
the link as `/usr/lib/TweakInject`, 20 bytes long, which suggested the raw
text was unprefixed and that the helper should read absolute targets as
paths inside the jbroot. Those tools are vroot-linked, however, and vroot
translates the text and the size it reports. The raw text is the kernel
path, and the kernel resolves it. `private/var -> /rootfs/var/mobile/…`,
reported as 74 bytes where the raw path has 67, gave that away. Read link
text with a process that is not vroot-linked, such as the helper, before
building on it.

### Still open

- **Signing on roothide Bootstrap (the TrollStore one).** Its basebin hooks
  `dpkg`'s `close()` to sign every Mach-O file and to create the `.jbroot`
  link beside it. The helper does neither. Dopamine-roothide, which the iPad
  runs, trust-caches instead and is not affected.
- **Conffiles.** Ownership of a conffile moving between packages, a purge
  deleting a conffile another package took over, and an installed
  package's Replaces on the new one still differ from dpkg.
- **Planner and state.**
  - Breaks has no `abort-deconfigure` path.
  - apt's early removal for a Conflicts replacement is not planned.
  - A Mach-O maintainer script runs under `/bin/sh`.
