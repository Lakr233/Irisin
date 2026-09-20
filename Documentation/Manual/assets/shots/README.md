# The manual's screenshots

Every figure in the manual is one screen in two appearances:
`en/<slug>-light.png` and `en/<slug>-dark.png`. The pair is the same screen in
the same state, taken one after the other without touching the device in
between, so the reader who switches the page's theme sees the figure change and
nothing else. A page declares the pixel size of both files, so a retake that
changes the size changes every page that shows it.

## The device

- iPhone 17 Pro, iOS 26.5, a simulator of its own (this set was taken on one
  named `Irisin Manual`).
- **1206 × 2622 pixels** — 402 × 874 points at 3×. That is what the `width` and
  `height` attributes on every `<img>` say. Another device means another size
  and an edit to every page.
- Irisin 4.3.0, the release commit `3117597`, a Debug build installed with:

      make sim SIMULATOR=<udid> DERIVED_DATA=~/Library/Caches/irisin-manual-shots

  The app runs against `<data container>/Documents/SimulatorRoot`, which stands
  in for a rootless bootstrap, so resolution, downloads, staging, the
  transcript and the dpkg database are the real code. Maintainer scripts, icli
  and signals are announced in the transcript and not carried out.

## The commands

    UDID=<udid>

    # the status bar every shot has
    xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged \
        --batteryLevel 100 --cellularBars 4 --wifiBars 3

    # the language (the app reads it at launch, so terminate first)
    xcrun simctl terminate "$UDID" wiki.qaq.irisin
    xcrun simctl launch "$UDID" wiki.qaq.irisin -AppleLanguages '(en)' -AppleLocale en_US

    # the appearance
    xcrun simctl ui "$UDID" appearance light
    xcrun simctl ui "$UDID" appearance dark

    # the file, straight to its place in the tree
    xcrun simctl io "$UDID" screenshot \
        Documentation/Manual/assets/shots/en/<slug>-light.png

Taps, typing and swipes are `idb ui tap|text|swipe --udid "$UDID"`. Nothing
outside the simulator is automated: no scripting of the Simulator app, no
synthetic events to the Mac.

Check the language from a screenshot before you shoot: a launch argument that
did not take leaves the last language in place.

## The state behind the set, in order

1. A device with nothing installed: delete `SimulatorRoot` and launch. The
   Welcome page opens (`installing-*`), and its recommended list is the
   rootless one.
2. **Add All** on the Welcome page's second page, then `roothide.github.io`
   from the add sheet by hand, for the packages built for the other bootstrap.
   The set was taken with five repositories: `apt.procurs.us` (the suite the
   recommended list picks for the runtime, component `main`), `ellekit.space`,
   `havoc.app`, `repo.chariz.com`, `roothide.github.io`. Havoc and Chariz sell
   packages, which is what puts **Vendor Accounts** in Settings.
3. Refresh everything and let the catalogue fill — about two thousand packages.
4. Install `lsof` through the app's own queue. It brings `libiosexec1`,
   `libncursesw6` and `ncurses-term`, and that run is a real one: the Installed
   page, the dpkg database and the transcript all come from it.
5. Install three tweaks, two of them at an older version through **Choose
   Version**: Artemis 1.3.1, UnderDock 1.2, Vivacity 1.3. The two older ones are
   what the Updates page and the badge have to show. Block Artemis's update for
   `updates-blocked`.
6. Settings → Packages → **Auto Translate** on, for the translation shots.
7. Leave the download cache
   (`<data container>/Documents/wiki.qaq.irisin/Downloads`) alone: a retake that
   runs an install again is much quicker with it.

Keep a copy of `SimulatorRoot` before any shot that installs something. The
operation shots need the same install to run twice, once per appearance, and
restoring that copy is what gives the second run the same work to do.

Search terms in the shots are neutral (`open`, `vim`), and nothing personal is
on the screen. Notifications stay off.

## What each file shows

| Slug | Page | How to reach it | What the state is |
| --- | --- | --- | --- |
| `installing-welcome` | Installing Irisin | A fresh install, or Dashboard → gear → … → **Welcome Page**; wait a second for the rows | Page one, all eight feature rows drawn, **Next** at the bottom |
| `installing-add-repositories` | Installing Irisin | **Next** from page one | The recommended rows resolved to names and icons, one already added (checkmark), the rest with **Add**, **Add All** in the header |
| `installing-caution` | Installing Irisin | **Next** from page two | The triangle, the warning, **Get Started** |
| `repositories-add` | Repositories | **Repositories** → plus → type `repo.chariz.com` | The lookup has finished: the row under the field carries the repository's own name and icon, **Add** is enabled, the **Clipboard** section is visible |
| `repositories-from-link` | Repositories | `xcrun simctl openurl "$UDID" "irisin://repository/add?url=https://havoc.app&url=https://repo.chariz.com"` with one of the two already added | The **From Link** header with **Add All**, one row offering **Add**, one with a checkmark |
| `repositories-advanced` | Repositories | Plus → **Add Advanced Source** → fill the Procursus values (`https://apt.procurs.us`, suite `2000`, component `main`) | Three fields filled and **Add** enabled; the sheet is not submitted |
| `repositories-menu` | Repositories | **Repositories** → … | The menu open over the list, green dots and the count line behind it |
| `packages-search` | Finding and Installing Packages | **Search** → type `open` | Results grouped under **Installed** and **Packages**, the match highlighted in each row's third line |
| `packages-page` | Finding and Installing Packages | Tap a package row from that search | The artwork, then the banner with INSTALL, then the description and the architecture footer |
| `packages-queue-changes` | Finding and Installing Packages | Tap INSTALL on a package that has dependencies | The **Queue Changes** sheet: an **Install** group, an **Install (Dependencies)** group, the sizes, **Confirm** |
| `packages-queue` | Finding and Installing Packages | **Confirm**, then tap the floating bar | The queue page while it downloads: a percentage or **Downloaded** at each row, **Execute** in the bar |
| `updates-page` | Updates | **Installed** → the up-arrow, with older versions installed (step 5) | Two rows or more, each with installed version → new version and the repository, **Update All** in the bar |
| `updates-update-all` | Updates | **Update All** | The **Queue Changes** sheet with one **Update** group and **Confirm** |
| `updates-blocked` | Updates | Block one package's update, then **Settings** → **Packages** → **Blocked Updates** | The blocked package listed, the trash button in the bar |
| `compatibility-unsupported` | Compatibility Mode | With `roothide.github.io` added, open a package built only for `iphoneos-arm64e` | The banner button reads UNSUPPORTED and the footer reads `Architecture: iphoneos-arm64e` |
| `compatibility-unsupported-alert` | *(spare — no page uses it)* | Tap UNSUPPORTED on that page | The **Unsupported Architecture** alert, naming the package's architecture and the device's |
| `translation-setting` | Translation | Dashboard → gear | The **Packages** group with **Auto Translate** on as its first row |
| `translation-menu` | Translation | A package page → … → **Translate** | The submenu open: Original, Translated, Compared with one checked, then the two language rows with their values |
| `translation-translated` | Translation | Auto Translate on, open a package whose page is written in another language | The line **This page is translated.** under the banner, the name in the banner translated, the navigation title as written |
| `translation-compared` | Translation | The same page → **Compared** | Each paragraph as written with its translation under it |
| `settings-top` | Settings and Exports | Dashboard → gear | The top of Settings, with **Vendor Accounts** above **Packages**, **Downloads** and **System** |
| `settings-export` | Settings and Exports | Settings → … → **Export…** | The submenu open, five exports in two groups |
| `settings-clear-downloads` | Settings and Exports | Tap **Clear Downloads** | The red one-item menu open over the size |
| `settings-footer` | Settings and Exports | Scroll Settings to the bottom | **License** and the grey lines under it; in the simulator the last one begins with `irisind` |
| `troubleshooting-operation` | When Something Fails | Queue `vim` → **Execute**, and shoot while it runs | Titled **Installing**: `vim` on **Installing…** with a turning ring, its three dependencies on **Waiting to be set up** |
| `troubleshooting-failed` | When Something Fails | The same queue, with the staged archive truncated (below) | Titled **Failed**: `vim` with a red mark and **Failed verification**, the other three **Not started** with dashed rings, the **Try Again** link under the list |
| `troubleshooting-problem` | When Something Fails | Tap the marked row on that page | **Problem**: the package, **What Happened** (`Unable to verify vim: Archive changed: vim`), **What to Do**. No **Script Output**: scripts do not run in the simulator |
| `troubleshooting-unable-to-prepare` | When Something Fails | Open a local `.deb` whose dependency no added repository offers, then INSTALL, then drag the sheet to full height | **Unable to Prepare Installation**: the reason under **What Happened**, the check group with one red mark, the **Install Using Recovery Mode** row |

## The three shots that need a failure

They are failures the app really had. Nothing is staged in the picture that did
not happen on the device.

**A run to photograph while it works.** `vim` from Procursus brings
`libintl8`, `libsodium23` and `xxd`, and its own 42 MB take several seconds to
unpack, so **Installing…** stands still long enough to shoot. The light and the
dark file are two runs of that same install with `SimulatorRoot` restored in
between, each shot from a burst
(`xcrun simctl io "$UDID" screenshot` every 0.4 s) at the same step.

**A package that fails verification.** The app stages each archive, digests it
and hands the installer the digest; the installer reads the file again before it
touches anything. Truncate the staged archive in that window and the installer
refuses it, exactly as it would refuse a file that rotted on disk:

    # while the queue runs, watch the staging directory and cut the file in half
    # <data container>/Documents/wiki.qaq.irisin/Installer/<id>/vim.contents/manifest.json
    # is written last, so the app is done reading vim.deb when it appears

Nothing is installed by such a run, so it can be repeated for the second
appearance, and the queue is still there afterwards.

**A change that cannot be planned.** VolumeFLEX 0.0.6 from `havoc.app` depends
on `libvolumeflex`, which none of the five repositories offers. Copy that `.deb`
into the device's `data/tmp` and hand it to the app:

    xcrun simctl openurl "$UDID" \
        "file:///Users/<you>/Library/Developer/CoreSimulator/Devices/$UDID/data/tmp/VolumeFLEX.deb"

The package page opens. INSTALL reports the failed check, and because the file
is on the device and this device can install it, the sheet offers **Install
Using Recovery Mode**, which is what the figure is for.

## What the simulator cannot show

Do not try to fake these; the manual leaves them out on purpose. The
**Unsupported Architecture** screen at startup and the roothide list of
recommended repositories (a simulator build carries no packaged architecture),
**Browsing Only** and its footer line (the simulator answers for the daemon),
**Script Output** and a script failure (maintainer scripts are not run),
**Hide** (two silent minutes of a real installer), a real
**Ignoring Configuration Errors** run, and **Updating App…**.
