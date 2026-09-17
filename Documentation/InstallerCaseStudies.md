# Installer case studies

Failures of the native installer that reached a device, what caused them,
and what now keeps them from coming back. Each one names the dpkg or apt
behavior the fix follows. See `NativeInstaller.md` for the installer itself.

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
