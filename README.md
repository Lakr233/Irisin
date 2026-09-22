# Irisin

## Modern. Fast. Beautiful.

Irisin is a package manager for jailbroken iPhone and iPad on iOS and iPadOS 16 or later. It works with both rootless jailbreaks, such as Dopamine, and roothide.

![Preview](Resources/main.jpeg)

## Features

- Designed for both iPhone and iPad
- A welcome page on first launch, with recommended repositories for your jailbreak
- Add a repository from a link, and export or import your repository list to move it to another device
- Search across packages, repositories, and authors, and narrow any package list with its own search bar
- Package pages that follow light and dark mode
- Install any version a repository offers, and block updates for packages you want to keep as they are
- Buy paid packages and sign in to your vendor accounts
- On roothide, install rootless packages in Compatibility Mode, which refuses a package it cannot convert safely
- Rebuild icons and reload the Home Screen from Settings
- Update Irisin from inside Irisin
- Available in 19 languages
- Open source under the MIT License

## Installation

Download the package for your jailbreak from [Releases](https://github.com/Lakr233/Irisin/releases):

| Jailbreak | Package |
| --- | --- |
| roothide | `iphoneos-arm64e` |
| rootless (`/var/jb`) | `iphoneos-arm64` |

Irisin checks your jailbreak when it opens. If you installed the wrong package, Irisin names the architecture it was built for and the one your device uses, asks you to install the matching package, and does not open.

## Report a Problem

Choose Report Issue in Settings, or [open an issue on GitHub](https://github.com/Lakr233/Irisin/issues/new). Search the existing issues first to avoid duplicates.

If Irisin crashes or an installation fails, include the log from View Logs in Settings. The log may contain your searches and repository addresses, so review it before you share it.

## Build from Source

Open `Irisin.xcodeproj` in Xcode. To build the packages:

```sh
make harness      # run the tests on the Mac
make deb-all      # build the roothide and rootless packages
make install      # update a device connected through `iproxy 2333 22`
```

You need `ldid` and `dpkg` from your preferred package manager. Notes for contributors are in [AGENTS.md](AGENTS.md).

## Acknowledgements

This product includes software developed by the Sileo Team.

#### "While the world sleeps, we dream."

## Sponsor

[LookInside](https://lookinside-app.com/) lets you inspect the interface of a running iOS or macOS app from your Mac.

---

Copyright © 2026 OwnGoal Studio. Released under the [MIT License](LICENSE).
