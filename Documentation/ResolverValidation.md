# Resolver failure review — 2026-09-08

## Findings and ownership

Felicity Pro 4.1 contains `Replaces: com.xandesign.FelicityPro (3.3)`.
The shared requirement parser previously rejected the implicit equality.
Ubuntu dpkg accepts it with a warning and treats it as an exact version match.
`PackageRequirementGroup.Clause.Term` now owns that compatibility rule and lowercases package
references. The original requirement remains available for display. Exact
matching still rejects 3.4; unversioned Provides still cannot satisfy a
versioned dependency by borrowing its provider's package version.

Aemulo Trial requires `mobilesubstrate (>= 0.9.5000)`. The captured vphone
catalogue contains rootful substrate/substitute builds (`iphoneos-arm`), but
the device needs `iphoneos-arm64`. There is no compatible installed provider.
This request must fail; firmware is independently satisfied. An unavailable
provider is not repaired by weakening architecture or version constraints.

`ResolutionDiagnostics` derives evidence only after the solver fails and reuses
the solver's requirement/provider matching. It groups candidate version history
by package, architecture and source, showing the newest relevant version.
`ResolutionCheck` carries display evidence, not a second installation plan.
`PackageDiagnosticController` renders those checks in a diffable table grouped
by requiring package. Green checks mean a matching candidate exists; orange
rows explain missing packages, version/architecture mismatches or global
conflicts. Global conflicts remain visible even when individual dependencies
all have matches.

The queue previously kept its last successful plan when a subsequent request
failed. `TaskManager.beginResolving` now revokes that plan before asynchronous
work begins and retains the new user intent for editing. Failed queues cannot
create an operation payload; tapping Install opens their diagnostic table.
Clearing the queue also clears its report, and late failures cannot restore it.

## Reproduction and verification

- The 1,060-package catalogue was copied from the vphone SQLite database into
  ignored build artifacts. Replaying Felicity selected 4.1 with unpack then
  configure, no removals, in approximately 12 ms.
- `ResolverProbe` normalizes raw control package names like repository ingestion
  and limits implicit version selection to the requested architecture.
- `make harness` passes, including 27 resolver tests. Dedicated regressions cover
  implicit equality, uppercase references, wrong architectures, missing versus
  unsuitable versions, unversioned Provides, global conflicts and large version
  histories in diagnostic rows.
- All 14 hosted application tests pass. The queue regression starts with a
  successful plan, submits an invalid request, verifies staging is unavailable,
  then taps the installation entry point and checks it opens diagnostics.
- The Release iPhoneOS app, daemon and helper build successfully; the rootless
  package passes packaging verification and installs on the vphone.
- On the vphone, tapping Install for Felicity Pro 4.1 changes it to Queued.
  Aemulo Trial opens the diagnostic table with architecture evidence and a
  matched firmware dependency.
- With both requests retained after failure, tapping the task page's Install
  control opens the same diagnostic table directly, with no staging, busy alert
  or installation confirmation.

The confirmation dialog summarizes install, remove and update counts, omitting
zero counts. Individual identities, versions and reasons remain in the queue
and resolver plan rather than being repeated in the confirmation alert.

## Operation log and device delivery

The operation console now uses a diffable table, with an incremental transcript
value owning line boundaries. Repeated messages keep distinct row identities;
partial chunks continue the last row. Snapshot updates are throttled and follow
the latest output only while the user remains at the bottom. Completion
actions remain available. The presentation is full screen on iPhone
and a centered form sheet on iPad, with safe-area constraints in both layouts.
All 16 hosted application tests pass, including fragmented and repeated log
messages. The vphone UI smoke test installed a disposable local `.deb`, verified
the quantity-only confirmation and full-screen table, then removed the fixture.

The previous Release build had `ENABLE_CODE_COVERAGE=YES`, which caused the
helper to try writing `default.profraw` on exit. Device builds now explicitly
disable coverage for all targets, including Swift packages. Release xcconfig
also disables it for IDE builds. Packaging rejects LLVM profile/coverage
sections; the old package fails this check and the new packages pass. Real
helper execution no longer emits the profile error.

Build 54 was installed over SSH on both the rootless vphone (`iphoneos-arm64`)
and the roothide iPad8,9 on iPadOS 18.5 (`iphoneos-arm64e`). The device's apt/dpkg
packages and compatible database remain in place.

The screenshots, database copy and replay output stay under
`build/vphone-resolver-review`. They are not committed as fixtures. Regression
tests use independently authored minimal metadata; no upstream GPL test corpus
is copied into the repository.

The follow-up log design removes sharing and row dividers, adds quiet line
numbers and tighter spacing, and reserves the top-right control for operation
status. It spins while work is running, then becomes a green checkmark or an
orange warning that closes the log. This result comes directly from the helper
exit status, including rejected operations; no log text is parsed to infer
success. Vphone captures verified the spinner, successful completion and close
action. Both vphone and iPad received the updated packages over SSH.
