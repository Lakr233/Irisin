# The command line

**Not in a release yet.** This is the design being built; what exists
so far is underneath it: the read-only catalogue (`PackageIndex.readOnly`),
the vendor sign-in and endpoints shared with the app (`IrisinVendor`), the
command line's entitlements and the check that keeps them the app's, and
irisind serving every client but the app only as root.

`<root>/usr/bin/irisin-cli` installs, removes and looks up packages from a
shell, for the bootstraps that no longer ship apt or dpkg. It is a program of
its own, not the app started another way, and it does less than the app on
purpose: it reads the catalogue the app keeps and never writes it, and it
drives the same helper through the same daemon with a pipeline a fraction of
the app's.

## Root, and only root

`irisin-cli` runs as root or not at all; it says so and exits 77 under any other
uid. Raising privilege is the user's to do (`sudo irisin-cli install ...`).

The daemon enforces this, not the program: every client other than Irisin's
own app must call with euid 0 (`PeerAuthenticator`, the same rule an external
client such as Apelin's session host meets). A check in the program alone
would be a check a library injected into it could skip; the euid in the
audit token is the kernel's.

## What it reads, and how

Everything the app knows is under mobile's `Documents/wiki.qaq.irisin`
(the folder is found through `getpwnam("mobile")`, never `HOME`, which is
`/var/root` under sudo):

| what | how `irisin-cli` reads it |
|---|---|
| repositories, packages, search, virtual packages | `apt.db`, opened read-only |
| installed packages | dpkg's `status` file, read directly; the helper replaces it by `rename`, so a read never sees half of one |
| auto-installed marks | `extended_states`, as the resolver reads it |
| blocked updates, Compatibility Updates | the app's setting files, read |
| vendor sign-in | the Keychain, read |

**Root never creates or changes a file in mobile's folder.** A file root
made there is one the app, running as mobile, cannot change afterwards. So
the catalogue is opened read-only, and opened at all only when `apt.db`,
`apt.db-wal` and `apt.db-shm` exist and are mobile's: SQLite would otherwise
make the `-shm` file itself, root's. When they do not, `irisin-cli` asks the
user to open Irisin once. The read-only open is its own path in
`AptDatabase`: none of what the app's open does first (creating tables,
FTS5 auto-merge, auto-backup) runs, and WAL hands the reader the catalogue
as the last committed write left it while the app goes on refreshing.

`irisin-cli` does not refresh repositories or add them. A refresh writes the
catalogue, and the catalogue has one writer, the app. `irisin-cli` says when the
catalogue was last refreshed and warns when that is more than a day ago;
`irisin-cli repo add <url>` hands the app an `irisin://repository/add` link.

## Commands

| command | |
|---|---|
| `search <words>` | full-text search of the catalogue |
| `show <package>` | every repository's record of it, and the installed one |
| `list [--installed \| --upgradable]` | |
| `install <package \| ./file.deb>...` | resolve, download, prepare, run |
| `remove <package>...` | resolve, run |
| `upgrade` | every update the Updates page would list |
| `repo list` / `repo add <url>` | the second opens the app |
| `vendor status <repo>` | signed in or not, and the account's purchases |
| `vendor login <repo>` | prints the sign-in URL; the sign-in finishes in the app |
| `vendor purchase <package>` | prints the purchase URL |
| `udid` | the device identifier vendors are sent |
| `respring` | |
| `dpkg-query ...` | the read-only subset maintainer scripts use (below) |

`install`, `remove` and `upgrade` show the plan and ask, unless `-y`;
`--dry-run` runs the transaction as a dry run. Every command takes `--json`:
one JSON object per line, the shape below kept stable, since icli's bridge
and scripts read it. The exit status is the helper's for a transaction,
otherwise 0, 1 for a refusal, 2 for a usage error, 77 when not root.

Text is English only: it is a shell tool, as apt is.

## The pipeline

1. **Resolve.** `PackageIndex.resolutionSnapshot()` against the read-only
   catalogue, then `PackageResolver.resolve` with a `ResolutionRequest`. No
   `ResolutionPool`: one solve per run.
2. **Download.** One `URLSession` download per package into a 0700
   directory of root's (`<root>/var/tmp/irisin.<pid>`), with the app's
   request headers and a signed-in vendor's download link. Nothing is cached
   and nothing is resumed; the file is checked with
   `Package.validateArchive`, as the app checks it.
3. **Prepare.** `ArchiveStream.prepareDebianPackage`, then
   `PackageAdapters.installed.adapt` for a package built for another
   bootstrap. If an adapted package's control paragraph differs from the
   preview the plan was solved with, the run stops before anything is sent
   and says so; the app's Patch, which solves again, is not repeated here.
4. **Run.** `InstallerJob.transaction` through `DaemonLink`, the same job
   the app sends, and the transcript printed as it arrives.
5. **Tell the app.** A Darwin notification once the run ends, so a running
   app reads the installed list again. The install origins of what `irisin-cli`
   installed are not recorded: the catalogue is the app's to write.

## Locks, crashes and what `irisin-cli` leaves behind

- The helper holds dpkg's `lock-frontend` and `lock` for the whole
  transaction, as it does for the app. `irisin-cli` never takes either: it asks
  with `F_GETLK` who holds `lock-frontend`, waits while someone does, and a
  run refused at the lock all the same wrote nothing and is sent again.
- `irisin-cli` dying changes nothing anyone else holds. The catalogue was open
  read-only. The helper runs in its own session and ignores `SIGPIPE`, so a
  transaction finishes without the program that started it, and its account
  is in `<root>/var/log/irisin-install.log`; Ctrl-C says so. The working
  directory is removed after the helper's `exit`; one left by a run that
  died is removed by the next run once no process has that pid.

## Installing Irisin with itself

`sudo irisin-cli install wiki.qaq.irisin` (or `upgrade` with an update of
Irisin in it) replaces the program that is running it, the app and irisind
in one transaction, and it is the case to test first on every device:

- The running `irisin-cli` keeps the image it started from when the package
  replaces `usr/bin/irisin-cli`: the file is unlinked and a new one placed,
  never written over in place.
- The transcript is the helper's pipe, handed to `irisin-cli` before the
  postinst restarts irisind, so the restart ends nothing `irisin-cli` reads.
  The helper finishes in its own session whether or not `irisin-cli` is
  still there, and loads irisind itself at the end of the run.
- The app is not stopped by a transaction (Irisin's own bundle is left to
  the app, `SelfPackage`): `irisin-cli` tells a running app to read the
  installed list again, and the app's own rule for a newer build of itself
  (Updating App, then registering at the next launch) does the rest.
- What to check, on RootHide and rootless: the upgrade from the release
  before, the same version again, a run killed with Ctrl-C and one killed
  with SIGKILL partway (the transaction still ends, `irisin-install.log`
  says how), the app open meanwhile and closed meanwhile, and `irisin-cli`
  working at once afterwards as the new version.

## Kept in step with the app

Some things exist on both sides and must change together. `make check`
fails when they do not:

- **Keychain.** The vendor sign-in is read with the app's account names
  (`KeyChain.[<repository>].token` and `.secret`) and without an access
  group, so it is found in whichever group the app wrote it to: the first
  of the app's `keychain-access-groups`. `irisin-cli`'s entitlements list the
  same groups in the same order. The names live in one shared type, never
  spelt twice. The token and the secret are never printed, logged or put in
  `--json`.
- **Entitlements.** `irisin-cli`'s are the client set
  (`wiki.qaq.irisin.client`, `platform-application`, `no-sandbox`), the
  Keychain groups, `network.client` and the system-keychain key, and
  nothing of the helper's; `Scripts/check-cli-entitlements.py` compares
  them with the app's.
- **The catalogue's schema.** `irisin-cli` reads the tables the app writes,
  through the same `AptDatabase` types; the read-only path is tested
  against a database the writable one made.
- **The package.** `verify-deb.sh` checks `usr/bin/irisin-cli` is there,
  root-owned, signed with those entitlements, and that its WCDB is the app's
  (`@rpath` through `@executable_path/../../Applications/Irisin.app/Frameworks`,
  the same relative path under rootless and roothide).

## `dpkg-query`

What maintainer scripts ask of dpkg most, answered from `status` and
`info/*.list`: `dpkg-query -W [-f=<format>] [<package>...]`,
`dpkg-query -s`, `dpkg-query -L`, `dpkg --compare-versions`,
`dpkg --print-architecture`. Anything that would change something is
refused. It is a subcommand, not a `dpkg` in the package: that would clash
with the bootstrap's own dpkg while one is installed. Routing a package's
own `dpkg` calls to it is icli's to do later.
