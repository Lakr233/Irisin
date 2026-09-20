# Native package installation review

Irisin resolves the complete transaction with LibSolv, decodes `.deb` archives
with the existing libarchive binary, and executes the ordered package stages in
IrisinInstaller. The device's apt/dpkg packages remain installed. Irisin's
runtime does not invoke either executable for package transactions. Maintainer
scripts still run in the device bootstrap and can use its existing tools.

The package's own daemon lifecycle is native too. Its maintainer scripts feed
closed, argument-free jobs to `irisin-install`; the helper derives Irisin's
LaunchDaemon plist from its own installed path and uses IcliKit to boot out the
old instance, bootstrap the plist and start the new instance. Removal uses
the matching fixed bootout job. Before loading, the helper writes its own
daemon's kernel executable path into the installed plist: RootHide's rootful
program path is not usable by launchd directly. No `launchctl` executable or
package dependency is involved.

## Where to review

- `PackageInstaller.swift`: validation, locks and transaction lifetime.
- `PackageTransaction.swift`: resources shared by one job; captures
  app-owned prepared input before verification and execution.
- `PackageTransaction+Unpack.swift`: preflight, upgrade, payload and status
  commit in their execution order.
- `PackageTransaction+UpgradeScripts.swift`: maintainer script arguments
  and failure callbacks. `+Configure` and `+Remove` own the other stages.
- `PackageTransaction+Payload.swift`: installed files, conffiles, links and
  obsolete files. `+ControlFiles` owns package metadata replacement.
- `PackageDatabase.swift`: compatible status, updates and info records.
- `PackageFilesystem.swift`: bootstrap destinations and recoverable file writes.
- `Triggers.swift` and its extensions: registration, activation and
  processing using compatible trigger records.

Types have their own files. Transaction extensions share resources, avoiding a
second manager and repeated database/filesystem/script parameter lists. General
mechanisms reuse Foundation, CryptoKit, libarchive and the existing ToolSpawn.

## Bootstrap paths

The app's existing libroot/libroothide lookup is its bootstrap fallback. The
helper derives its installed root from its executable; daemon `hello` supplies
that same root to the app. BootstrapLayout owns all path spelling:

| Path | Rootless | Roothide |
| --- | --- | --- |
| Archive payload | Strip the package prefix and write below the resolved bootstrap | Write below jbroot |
| Shell executable | Bootstrap-prefixed kernel path, applied once | Kernel path inside jbroot |
| Installed script / admin directory | Real path | Bootstrap-relative absolute path |
| Script outside bootstrap | Real path | `/rootfs` bridge |
| PATH / HOME | Prefix-compiled bootstrap spelling | vroot spelling |

Symbolic links need the same care. On roothide, an absolute link target
is written as the kernel path vroot would write (`BootstrapLayout.linkText`).
In the simulator, a link keeps `/var/jb` and resolves to the mount
(`linkedPath`). `PackageFilesystem.physicalPath` resolves every path one
component at a time. `InstallerCaseStudies.md` tells how ElleKit's
`DynamicLibraries` link found each of these.

A script's argument vector is passed as separate strings, including filenames
containing spaces. The process receives an explicit environment and working
directory; no inherited command string or environment crosses XPC. On a device,
DPKG_ROOT is empty because the bootstrap shell already runs in its normal
namespace. The Mac harness supplies an isolated DPKG_ROOT to synthetic scripts.

## Reused process library evaluation

AuxiliaryExecute 2.1.0 (`7fb043c2d18ef947c23537f43be26f92e837d1af`)
was inspected and built in Swift 6 mode. It supports working directories and
output callbacks, but the build fails on its mutable singleton's concurrency
safety. Its spawn implementation merges the inherited environment, supplies no
spawn attributes for descriptor isolation or signal reset, and captures complete
stdout/stderr strings. These differ from the helper's existing execution
contract. This version was not added as a dependency; ToolSpawn remains the
process implementation. Replacing it requires those guarantees in the library.

## Validation

`make harness` includes native filesystem, script, conffile, trigger and recovery
tests, in addition to the resolver and existing protocol/client suites.
`make test` covers the hosted iOS application tests.

The synthetic APT oracle can now run both the native backend and real dpkg:

```sh
swift build --package-path Packages/AptRepository -c release --product ResolverProbe
swift build --package-path Packages/AptRepository -c release --product NativeInstallerProbe
python3 Scripts/apt-oracle/compare.py \
  --probe Packages/AptRepository/.build/out/Products/Release/ResolverProbe \
  --native-probe Packages/AptRepository/.build/out/Products/Release/NativeInstallerProbe \
  --output build/native-oracle
```

It requires the disposable Ubuntu container described in `Scripts/apt-oracle`.
Twelve cases cover Pre-Depends, old configured witnesses during upgrades,
versioned Provides, Debian revision zero, dependency cycles, reverse removals,
provider replacement, conflicts, Replaces and conservative updates. Real `.deb`
files pass through the app's libarchive preparation. Ubuntu dpkg-query then reads
the native database and checks the final installed versions. Reports and logs
stay under `build/`; external Ubuntu repository metadata is not vendored.

The rootless vphone smoke test also passed install, upgrade and remove through
the real helper. It exercised both `/bin/sh` and bootstrap-prefixed shebangs,
maintainer-script arguments/environment, a locally edited conffile and its
`.dpkg-dist`, and payload removal. Device `dpkg-query` read the native database
after every stage. The synthetic package was then purged with the device's dpkg
and its remaining test files removed. Logs stay in `build/native-vphone-smoke`.

These checks establish the tested behaviors, not complete equivalence to every
dpkg option. The closed API supports remove, unpack and configure; it has no
purge or force-overwrite command. Unsupported archive entry types and unsafe
filesystem changes fail. A maintainer script's arbitrary external effects cannot
be rolled back. Failed/interrupted operations retain a repair state and file
journal rather than reporting a successful installation.

## Reference material

Implementation and synthetic fixtures are independently authored; no apt/dpkg
source or upstream GPL test suite was copied. Protocol behavior was checked
against documentation and executable results:

- https://www.debian.org/doc/debian-policy/ch-maintainerscripts.html
- https://manpages.debian.org/bookworm/dpkg-dev/deb-conffiles.5.en.html
- https://manpages.debian.org/bookworm/dpkg-dev/deb-triggers.5.en.html
- https://github.com/opa334/libroot
- https://github.com/roothide/Developer/blob/main/roothide.md
- https://github.com/Lakr233/AuxiliaryExecute/tree/7fb043c2d18ef947c23537f43be26f92e837d1af
