# Bootstrap detection

Irisin's package architecture and the device's bootstrap are independent
facts. `package-deb.sh` stamps `IrisinCurrentArchitecture` into Info.plist
for each package flavor. That value remains the app's architecture for its
entire run; a mismatch stops setup and shows the user how to reinstall.
An unpackaged Xcode or simulator build uses the runtime's architecture.

## Why the previous check failed

`JailbreakRoot` used `prefix != "/var/jb"` to identify roothide. The
[libroot contract](https://github.com/opa334/libroot#providing-paths)
explicitly allows `libroot_get_jbroot_prefix()` to return either `/var/jb`
or the directory it points to. Dopamine's
[implementation](https://github.com/opa334/Dopamine/blob/2.x/Packages/libroot/src/paths.c)
returns its runtime jbroot and an empty rootfs prefix. A different path
spelling therefore does not identify a different bootstrap.

The wrong flag affected both the Settings label and `diskPath(ofListed:)`,
which selects how to locate the files in dpkg's lists. The old architecture
fallback also counted architectures in the status file, so the package mix
could change its answer. Neither package counts nor CPU architecture
describe the runtime's filesystem conventions.

## Runtime evidence

0. The app's own bundle path. A bundle under a directory named
   `.jbroot-` and sixteen hex digits (the last byte the xor of the seven
   before it) is inside a roothide bootstrap, and that directory is the
   root. It is libroothide's own method: its
   [`init.c`](https://github.com/roothide/libroothide/blob/master/init.c)
   reads the root off its image path and checks the name with
   `is_jbroot_name`. It comes first because the `.jbroot` link the next
   step loads through is, by
   [RootHide's account](https://github.com/roothide/Developer/blob/main/roothide.md),
   made by its dpkg hook or by the jailbreak when it loads a binary, and
   is not promised: without it a roothide device fell through to the
   rootless default and the arm64e package was refused as mismatched
   (4.3.6, iOS 16.1 roothide).
1. A successful call to `jbroot("/")` in the app-adjacent
   `libroothide.dylib` supplies both the roothide root and its identity.
   RootHide documents the generated `.jbroot` links and its distinct
   [path semantics](https://github.com/roothide/Developer/blob/main/roothide.md),
   as well as the [API](https://github.com/roothide/Developer/blob/main/interface.md).
2. Otherwise libroot supplies the bootstrap root and rootfs prefix. An
   empty rootfs prefix identifies the supported rootless layout;
   `/rootfs` identifies roothide. This takes precedence over path spelling
   or the existence of a `/var/jb` symlink.
3. For older libroot implementations without the rootfs API, compare the
   canonical bootstrap root with canonical `/var/jb`. This fallback needs
   a working symlink to recognize a relocated rootless installation.
4. Without either library, preserve the conventional rootless fallback.
   The simulator explicitly uses its own rootless mount.

The package architecture is `iphoneos-arm64` for
[Theos rootless](https://theos.dev/docs/rootless), and `iphoneos-arm64e` for
[RootHide's package scheme](https://github.com/roothide/theos/blob/master/vendor/mod/roothide/package/deb.mk).
These are Debian package conventions, not an arm64/arm64e CPU probe.

## Installation contract and verification

Irisin ships native packages for both supported bootstraps. Its compatibility
adapter explicitly refuses to convert Irisin itself. A converted copy with
a mismatching Info.plist stamp cannot start the engines, enter the main
interface, refresh packages, or process incoming links and imports.
The stamp is a compatibility contract, not tamper-proof attestation:
deliberately rewriting or removing it is outside this check's guarantee.

`PackagedArchitectureTests` covers a bundle path inside a roothide root and
the names that only look like one, relocated rootless paths, the rootfs API
without a symlink, roothide with a compatibility alias, both directions of
package mismatch, and matching/unpackaged builds. `PackageAdaptersTests`
checks that refusing Irisin leaves the prepared manifest unchanged and
still permits the native package.
