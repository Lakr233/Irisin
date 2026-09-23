# Irisin — Xcode build, macOS harness, and jailbreak Debian packaging.

# Shared Xcode products must not be rebuilt while another flavour copies them.
.NOTPARALLEL:

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

ROOT_DIR            := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
PROJECT             := $(ROOT_DIR)/Irisin.xcodeproj
# Every build goes through the workspace: it holds the project and each
# package under Packages/, and a package there stands in for a remote one of
# the same name anywhere in the graph (Runestone, MarkdownView: vendored).
WORKSPACE           := $(ROOT_DIR)/Irisin.xcworkspace
SCHEME              := Irisin
CONFIGURATION       ?= Release
# Not under /tmp: Xcode spells that /tmp while FileManager resolves it to
# /private/tmp, and some package manifests strip checkout paths by string
# match; the two spellings then fail to match.
DERIVED_DATA        ?= $(HOME)/Library/Caches/irisin-deriveddata
APP_BUNDLE          := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)-iphoneos/irisin.app
DAEMON_BINARY       := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)-iphoneos/irisind
HELPER_BINARY       := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)-iphoneos/irisin-install
SIMULATOR_APP       := $(DERIVED_DATA)/Build/Products/Debug-iphonesimulator/irisin.app
SIMULATOR           ?= booted
APP_BUNDLE_ID       := wiki.qaq.irisin
PACKAGE_ID          ?= wiki.qaq.irisin
PROJECT_OBJECT_VERSION := 77

# FLAVOR selects the jailbreak layout the .deb is built for:
#   roothide - files ship at rootful paths; roothide's dpkg relocates them into
#              the randomized bootstrap root. Architecture iphoneos-arm64e.
#   rootless - files ship under /var/jb, the fixed rootless prefix (Dopamine,
#              palera1n rootless, ...). Architecture iphoneos-arm64.
# The Mach-O slices are identical for both; only the layout differs, and the
# daemon works out which one it landed in at runtime.
FLAVOR              ?= roothide
ifeq ($(FLAVOR),roothide)
INSTALL_PREFIX      :=
DEFAULT_ARCHITECTURE := iphoneos-arm64e
else ifeq ($(FLAVOR),rootless)
INSTALL_PREFIX      := /var/jb
DEFAULT_ARCHITECTURE := iphoneos-arm64
else
$(error FLAVOR must be roothide or rootless, got '$(FLAVOR)')
endif
PACKAGE_ARCHITECTURE ?= $(DEFAULT_ARCHITECTURE)

PACKAGE_DIR         := $(ROOT_DIR)/Packages/IrisinKit
CONFIG_DIR          := $(ROOT_DIR)/Configuration
VERSION_CONFIG      := $(CONFIG_DIR)/Version.xcconfig
BASE_CONFIG         := $(CONFIG_DIR)/Base.xcconfig
SIZE_CONFIG         := $(CONFIG_DIR)/Size.xcconfig
xcconfig_setting     = $(strip $(shell awk -F= '$$1 ~ /^[[:space:]]*$(1)[[:space:]]*$$/ { gsub(/[[:space:]]/, "", $$2); print $$2; exit }' "$(VERSION_CONFIG)"))
base_xcconfig_setting = $(strip $(shell awk -F= '$$1 ~ /^[[:space:]]*$(1)[[:space:]]*$$/ { gsub(/[[:space:]]/, "", $$2); print $$2; exit }' "$(BASE_CONFIG)"))
APP_VERSION         := $(call xcconfig_setting,MARKETING_VERSION)
# The build number is the commit count, handed to xcodebuild on the command
# line: nothing in the tree changes from building. CI passes its run number.
BUILD_NUMBER        ?= $(shell git -C "$(ROOT_DIR)" rev-list --count HEAD 2>/dev/null)
MINIMUM_IOS_VERSION := $(call base_xcconfig_setting,IPHONEOS_DEPLOYMENT_TARGET)
DEB_OUTPUT          ?= $(ROOT_DIR)/build/Packages/$(PACKAGE_ID)_$(APP_VERSION)_$(PACKAGE_ARCHITECTURE).deb

XCODEBUILD_WRAPPER  := $(ROOT_DIR)/Scripts/run-xcodebuild.sh
DEB_PACKAGER        := $(ROOT_DIR)/Scripts/package-deb.sh
DEB_VERIFIER        := $(ROOT_DIR)/Scripts/verify-deb.sh
VERSION_APPLIER     := $(ROOT_DIR)/Scripts/apply-version.sh
DEVICE_INSTALLER    := $(ROOT_DIR)/Scripts/install-device.sh

# `make install` talks to the device over a usbmuxd forward (`iproxy 2333 22`).
DEVICE_HOST         ?= 127.0.0.1
DEVICE_PORT         ?= 2333
DEVICE_USER         ?= mobile
DEVICE_PASSWORD     ?= alpine
CONTROL_TEMPLATE    := $(ROOT_DIR)/Packaging/DEBIAN/control
ENTITLEMENTS        := $(ROOT_DIR)/Packaging/irisin.entitlements
DAEMON_ENTITLEMENTS := $(ROOT_DIR)/Packaging/irisind.entitlements
HELPER_ENTITLEMENTS := $(ROOT_DIR)/Packaging/irisin-install.entitlements
LAUNCH_DAEMON       := $(ROOT_DIR)/Packaging/wiki.qaq.irisind.plist
INFO_PLIST_SUPPLEMENT := $(ROOT_DIR)/Packaging/Irisin-Info.plist

XCODEBUILD_BASE := $(XCODEBUILD_WRAPPER) \
	-workspace "$(WORKSPACE)" \
	-derivedDataPath "$(DERIVED_DATA)" \
	-skipMacroValidation \
	-skipPackagePluginValidation \
	ARCHS=arm64 \
	ONLY_ACTIVE_ARCH=YES \
	ENABLE_DEBUG_DYLIB=NO \
	CURRENT_PROJECT_VERSION=$(BUILD_NUMBER)
XCODEBUILD := $(XCODEBUILD_BASE) \
	ENABLE_CODE_COVERAGE=NO \
	CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
SIMULATOR_XCODEBUILD := $(XCODEBUILD_BASE) \
	CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=""

ifeq ($(APP_VERSION),)
$(error MARKETING_VERSION is missing from Configuration/Version.xcconfig)
endif
ifeq ($(BUILD_NUMBER),)
$(error BUILD_NUMBER is empty: not a git checkout, pass BUILD_NUMBER=n)
endif

.PHONY: all help print-version print-build-number print-deb-path print-flavor \
	set-version check harness test build compile sim _build-ios _package-deb \
	_packages deb deb-roothide deb-rootless deb-all install clean

all: deb-all

help:
	@echo "Irisin:"
	@echo "  harness     Run the IrisinKit and AptRepository tests on macOS (no device, no simulator)"
	@echo "  test        Run the IrisinUnitTest bundle inside the app on the booted simulator"
	@echo "  check       Validate the Xcode project and packaging inputs"
	@echo "  build       Run the harness, then compile"
	@echo "  compile     Build the unsigned irisin.app, irisind and irisin-install for iPhoneOS, no tests"
	@echo "  sim         Build Debug and launch the app on the booted simulator"
	@echo "  deb         Build, ad-hoc sign, package, and verify the .deb for FLAVOR (default roothide)"
	@echo "  deb-all     Package both the roothide and the rootless .deb"
	@echo "  install     Build for FLAVOR and update an installation on the device via iproxy"
	@echo "  set-version Write VERSION=x.y.z into Configuration/Version.xcconfig (build number: git commit count, or BUILD_NUMBER=n)"
	@echo "  clean       Remove derived data and generated packages"

print-version:
	@echo "$(APP_VERSION)"

print-build-number:
	@echo "$(BUILD_NUMBER)"

print-deb-path:
	@echo "$(DEB_OUTPUT)"

print-flavor:
	@echo "$(FLAVOR)"

set-version:
	@test -n "$(VERSION)" || { echo "usage: make set-version VERSION=4.0.1" >&2; exit 64; }
	@"$(VERSION_APPLIER)" "$(VERSION)"

check:
	@command -v xcodebuild >/dev/null || { echo "error: xcodebuild is required" >&2; exit 69; }
	@command -v ldid >/dev/null || { echo "error: ldid is required" >&2; exit 69; }
	@command -v dpkg-deb >/dev/null || { echo "error: dpkg-deb is required" >&2; exit 69; }
	@test -d "$(PROJECT)" || { echo "error: Irisin.xcodeproj is missing" >&2; exit 66; }
	@test -f "$(WORKSPACE)/contents.xcworkspacedata" || { echo "error: Irisin.xcworkspace is missing" >&2; exit 66; }
	@for package in "$(ROOT_DIR)"/Packages/*/Package.swift; do \
		name="$$(basename "$$(dirname "$$package")")"; \
		grep -qF "location = \"group:Packages/$$name\"" "$(WORKSPACE)/contents.xcworkspacedata" \
			|| { echo "error: Packages/$$name is not in Irisin.xcworkspace; the build would take the remote package of that name" >&2; exit 65; }; \
	done
	@test -f "$(CONTROL_TEMPLATE)" || { echo "error: Debian control template is missing" >&2; exit 66; }
	@test -f "$(PACKAGE_DIR)/Package.swift" || { echo "error: Packages/IrisinKit/Package.swift is missing" >&2; exit 66; }
	@for script in "$(DEB_PACKAGER)" "$(DEB_VERIFIER)" "$(VERSION_APPLIER)" "$(XCODEBUILD_WRAPPER)" "$(DEVICE_INSTALLER)"; do \
		test -x "$$script" || { echo "error: $$script is not executable" >&2; exit 66; }; \
	done
	@for xcconfig in Version Base Size Development Release; do \
		test -f "$(CONFIG_DIR)/$$xcconfig.xcconfig" || { echo "error: Configuration/$$xcconfig.xcconfig is missing" >&2; exit 66; }; \
	done
	@[[ "$(APP_VERSION)" =~ ^[0-9]+\.[0-9]+\.[0-9]+$$ ]] || { echo "error: MARKETING_VERSION must look like 4.0.0, got '$(APP_VERSION)'" >&2; exit 65; }
	@[[ "$(BUILD_NUMBER)" =~ ^[0-9]+$$ ]] || { echo "error: CURRENT_PROJECT_VERSION must be an integer, got '$(BUILD_NUMBER)'" >&2; exit 65; }
	@[[ "$(MINIMUM_IOS_VERSION)" =~ ^[0-9]+\.[0-9]+$$ ]] || { echo "error: IPHONEOS_DEPLOYMENT_TARGET must look like 15.0, got '$(MINIMUM_IOS_VERSION)'" >&2; exit 65; }
	@grep -qE '(MARKETING_VERSION|CURRENT_PROJECT_VERSION) =' "$(PROJECT)/project.pbxproj" \
		&& { echo "error: versions must live in Configuration/Version.xcconfig, not project.pbxproj" >&2; exit 65; } || true
	@grep -q 'IPHONEOS_DEPLOYMENT_TARGET' "$(PROJECT)/project.pbxproj" \
		&& { echo "error: deployment target must live in Configuration/Base.xcconfig, not project.pbxproj" >&2; exit 65; } || true
	@grep -Fq "Depends: firmware (>= @MINIMUM_IOS_VERSION@)" "$(CONTROL_TEMPLATE)" \
		|| { echo "error: Debian control must depend on firmware (>= @MINIMUM_IOS_VERSION@)" >&2; exit 65; }
	@objver="$$(sed -n 's/^[[:space:]]*objectVersion = \([0-9]*\);.*/\1/p' "$(PROJECT)/project.pbxproj")"; \
		[[ "$$objver" == "$(PROJECT_OBJECT_VERSION)" ]] || { echo "error: project.pbxproj objectVersion must stay $(PROJECT_OBJECT_VERSION) so Xcode 16+ can read it, got '$$objver' (newer Xcode rewrites it on save)" >&2; exit 65; }
	@if (( $$(cut -d. -f1 <<<"$(MINIMUM_IOS_VERSION)") < 16 )); then \
		hits="$$(grep -rnE 'XPC_(TYPE|ERROR)_[A-Z]|XPC_ARRAY_APPEND' --include='*.swift' "$(ROOT_DIR)/Irisin" "$(ROOT_DIR)/IrisinDaemon" "$(ROOT_DIR)/IrisinInstall" "$(PACKAGE_DIR)/Sources" || true)"; \
		if [[ -n "$$hits" ]]; then \
			echo "error: XPC SDK macros named in Swift link libswiftXPC.dylib, which iOS $(MINIMUM_IOS_VERSION) does not have; use IrisinXPC:" >&2; \
			echo "$$hits" >&2; \
			exit 65; \
		fi; \
	fi
	@grep -rnE 'setuid\(|posix_spawnattr_set_persona|exec-root|giveMeRoot' --include='*.swift' --include='*.m' "$(ROOT_DIR)/Irisin" \
		&& { echo "error: the app must never raise privilege; privileged work goes through irisind" >&2; exit 65; } || true
	@grep -rnE 'NSLocalizedString\(|"[A-Z][A-Z0-9]*(_[A-Z0-9]+)+"' --include='*.swift' "$(ROOT_DIR)/Irisin" \
		&& { echo "error: user-facing text is a String.LocalizationValue spelled out in English (\"Delete All Downloads\"), never NSLocalizedString or a SHOUTING_KEY" >&2; exit 65; } || true
	@grep -rnE 'numberOfRowsInSection|numberOfItemsInSection|\.reloadData\(\)|(UITableView|UICollectionView)DataSource($$|[^A-Za-z])' --include='*.swift' "$(ROOT_DIR)/Irisin" \
		&& { echo "error: every list is a diffable data source (UITableViewDiffableDataSource / UICollectionViewDiffableDataSource) applying snapshots; no classic data source protocol, no reloadData()" >&2; exit 65; } || true
	@grep -rnE '(^|[^A-Za-z])(performBatchUpdates\(|beginUpdates\(\)|endUpdates\(\)|(reconfigure|reload|insert|delete)Rows\(|moveRow\()' --include='*.swift' --exclude-dir=.build "$(ROOT_DIR)/Irisin" "$(ROOT_DIR)/Packages" \
		| grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' \
		&& { echo "error: a list whose data source is diffable changes by snapshot alone; iOS 16 throws from the view's own mutation calls (performBatchUpdates, beginUpdates, reconfigureRows), an empty batch included. Measure rows again with snapshot.reconfigureItems" >&2; exit 65; } || true
	@grep -rnE '[sS]ystemFont\(ofSize:|UIFont\(name:|UIFont\(descriptor:|preferredFont\(forTextStyle:|withDesign\(|weight: \.(ultraLight|thin|light|medium|bold|heavy|black)|UIColor\((hex|red|white|hue|named):|\.system(Red|Green|Blue|Orange|Yellow|Pink|Purple|Teal|Indigo|Mint|Cyan|Brown|Gray[2-6]?|Background|GroupedBackground)([^A-Za-z0-9]|$$)|(Color|color)(:| =|\() *\.(white|black|gray|lightGray|darkGray|red|green|blue|cyan|yellow|magenta|orange|purple|brown)([^A-Za-z0-9]|$$)|UIColor\.(white|black|gray|lightGray|darkGray|red|green|blue|cyan|yellow|magenta|orange|purple|brown)([^A-Za-z0-9]|$$)' --include='*.swift' "$(ROOT_DIR)/Irisin" \
		| grep -vE '/Interface/DesignTokens/' \
		&& { echo "error: fonts and colors are design tokens (UIFont.rounded(.body), UIColor.swipeDelete) from Interface/DesignTokens/; no literal size, weight, color or asset colour at a call site" >&2; exit 65; } || true
	@grep -rnE 'UIActivityViewController\(|\.init\(activityItems:|[pP]opoverPresentationController' --include='*.swift' "$(ROOT_DIR)/Irisin" \
		| grep -vF "$(ROOT_DIR)/Irisin/Interface/Components/ShareSheet/ShareSheet.swift:" \
		&& { echo "error: the share sheet is ShareSheet.present(_:anchor:from:), which always gives the iPad's popover somewhere to point; no UIActivityViewController, .init(activityItems: or popover presentation controller at a call site. Packages/ is not searched: PackageDepiction's PhotoViewerController cannot reach it and points its own sheet at the button that was tapped" >&2; exit 65; } || true
	@plutil -lint "$(ENTITLEMENTS)" "$(DAEMON_ENTITLEMENTS)" "$(HELPER_ENTITLEMENTS)" "$(LAUNCH_DAEMON)" "$(INFO_PLIST_SUPPLEMENT)"
	@targets="$$(xcodebuild -project "$(PROJECT)" -list)" || exit $$?; \
	for target in Irisin irisind irisin-install IrisinUnitTest; do \
		grep -Eq "^[[:space:]]*$$target[[:space:]]*$$" <<<"$$targets" \
			|| { echo "error: missing Xcode target $$target" >&2; exit 65; }; \
	done
	@test -x "$(ROOT_DIR)/Scripts/collect-licenses.py" || { echo "error: collect-licenses.py is not executable" >&2; exit 66; }
	@grep -qF 'collect-licenses.py' "$(PROJECT)/project.pbxproj" \
		|| { echo "error: the Collect Licenses build phase is missing from the Irisin target; the License page would be empty" >&2; exit 65; }
	@# The project is Irisin and so is the GitHub repository, so the old
	@# codename has nowhere left to hide. This rule and the Hard rule it
	@# enforces have to spell what they forbid, so the two files that state
	@# it are the only ones not searched.
	@hits="$$(cd "$(ROOT_DIR)" && git grep -nIi -e chromatic -e saily -- ':!AGENTS.md' ':!Makefile' || true)"; \
	names="$$(cd "$(ROOT_DIR)" && git ls-files | grep -i -e chromatic -e saily || true)"; \
	if [[ -n "$$hits$$names" ]]; then \
		echo "error: the project is Irisin; chromatic and Saily are gone" >&2; \
		[[ -n "$$hits" ]] && echo "$$hits" >&2; \
		[[ -n "$$names" ]] && echo "$$names" >&2; \
		exit 65; \
	fi
	@# What the user reads says custom firmware, in every language.
	@"$(ROOT_DIR)/Scripts/check-wording.py" "$(ROOT_DIR)"
	@# The manual quotes the app's controls by name, and a control renamed in
	@# the string catalog is renamed nowhere else on its own.
	@test -x "$(ROOT_DIR)/Scripts/check-manual.py" || { echo "error: check-manual.py is not executable" >&2; exit 66; }
	@"$(ROOT_DIR)/Scripts/check-manual.py" "$(ROOT_DIR)"
	@# A cell or a view is read for its subviews unless it is an
	@# accessibility element itself, and the sentence it assembled is then
	@# never spoken. Only the sources that ship are searched: a package's
	@# Tests and its .build checkouts are nobody's interface.
	@test -x "$(ROOT_DIR)/Scripts/check-accessibility.py" || { echo "error: check-accessibility.py is not executable" >&2; exit 66; }
	@"$(ROOT_DIR)/Scripts/check-accessibility.py" \
		"$(ROOT_DIR)/Irisin" \
		"$(PACKAGE_DIR)/Sources" \
		"$(ROOT_DIR)/Packages/AptRepository/Sources" \
		"$(ROOT_DIR)/Packages/PackageDepiction/Sources"
	@# Xcode writes `extractionState: stale` into a catalog during an
	@# ordinary build, in a file too large to read, and it rides into a
	@# commit as one green line otherwise. `manual` is deliberate here and
	@# is left alone; only what Xcode reaped by itself is refused. The fix
	@# is Scripts/prune-xcstrings.py, by hand, with Xcode closed.
	@test -x "$(ROOT_DIR)/Scripts/check-stale-strings.py" || { echo "error: check-stale-strings.py is not executable" >&2; exit 66; }
	@"$(ROOT_DIR)/Scripts/check-stale-strings.py" \
		"$(ROOT_DIR)/Irisin" \
		"$(ROOT_DIR)/IrisinDaemon" \
		"$(ROOT_DIR)/IrisinInstall" \
		"$(ROOT_DIR)/Packages"

# The IrisinKit and AptRepository tests on the Mac. This is where a
# malformed job that reaches an argv, a mis-spelled bootstrap path, a
# catalogue query or a version comparison gets caught, and it needs neither
# a device nor a simulator.
harness:
	swift test --package-path "$(PACKAGE_DIR)"
	swift test --package-path "$(ROOT_DIR)/Packages/AptRepository"

# The app's own unit tests, linked into irisin.app on the booted simulator:
# what only makes sense against the app's types (the downloader's byte
# accounting against a stubbed server, for one). SIMULATOR=booted picks the
# first booted device; pass a UDID to choose. Diagnostics are never collected:
# after a failing test xcodebuild asks the simulator for them and waits out a
# 600 second timeout before it reports the failure it already has.
test:
	@udid="$(SIMULATOR)"; \
	if [[ "$$udid" == "booted" ]]; then \
		udid="$$(xcrun simctl list devices booted | sed -n 's/.*(\([0-9A-F-]\{36\}\)).*/\1/p' | head -n 1)"; \
		test -n "$$udid" || { echo "error: no booted simulator; boot one or pass SIMULATOR=<udid>" >&2; exit 69; }; \
	fi; \
	XCBUILD_LABEL=test $(SIMULATOR_XCODEBUILD) \
		-configuration Debug \
		-scheme "$(SCHEME)" \
		-destination "platform=iOS Simulator,id=$$udid" \
		-collect-test-diagnostics never \
		test

build: harness compile

# CI runs the harness and this compilation as two jobs in parallel;
# publication waits for both.
compile: check
	@$(MAKE) --no-print-directory _build-ios

_build-ios:
	@echo "==> build $(BUILD_NUMBER)"
	XCBUILD_LABEL=build-ios $(XCODEBUILD) \
		$(if $(filter Release,$(CONFIGURATION)),-xcconfig "$(SIZE_CONFIG)") \
		-configuration "$(CONFIGURATION)" \
		-scheme "$(SCHEME)" \
		-destination "generic/platform=iOS" \
		build

# The simulator exercises the shell through the unprivileged backend: there
# is no daemon there and there cannot be.
sim: harness
	XCBUILD_LABEL=build-sim $(SIMULATOR_XCODEBUILD) \
		-configuration Debug \
		-scheme "$(SCHEME)" \
		-destination "generic/platform=iOS Simulator" \
		build
	xcrun simctl install "$(SIMULATOR)" "$(SIMULATOR_APP)"
	xcrun simctl launch "$(SIMULATOR)" "$(APP_BUNDLE_ID)"

deb: build
	@$(MAKE) --no-print-directory _package-deb

_package-deb:
	"$(DEB_PACKAGER)" \
		"$(APP_BUNDLE)" \
		"$(DAEMON_BINARY)" \
		"$(HELPER_BINARY)" \
		"$(CONTROL_TEMPLATE)" \
		"$(ENTITLEMENTS)" \
		"$(DAEMON_ENTITLEMENTS)" \
		"$(LAUNCH_DAEMON)" \
		"$(DEB_OUTPUT)" \
		"$(PACKAGE_ID)" \
		"$(APP_VERSION)" \
		"$(PACKAGE_ARCHITECTURE)" \
		"$(FLAVOR)" \
		"$(INSTALL_PREFIX)" \
		"$(MINIMUM_IOS_VERSION)" \
		"$(HELPER_ENTITLEMENTS)"
	"$(DEB_VERIFIER)" \
		"$(DEB_OUTPUT)" \
		"$(PACKAGE_ID)" \
		"$(APP_VERSION)" \
		"$(PACKAGE_ARCHITECTURE)" \
		"$(INSTALL_PREFIX)"

deb-roothide:
	@$(MAKE) --no-print-directory deb FLAVOR=roothide

deb-rootless:
	@$(MAKE) --no-print-directory deb FLAVOR=rootless

deb-all: build
	@$(MAKE) --no-print-directory _packages

# One compilation, packaged twice: the two flavours differ in layout only.
_packages:
	@$(MAKE) --no-print-directory _package-deb FLAVOR=roothide
	@$(MAKE) --no-print-directory _package-deb FLAVOR=rootless

# Build for FLAVOR and install it on the device behind `iproxy $(DEVICE_PORT) 22`.
# The package's own postinst boots the daemon and registers the app through
# the helper. What it cannot
# do is retire the app already running on the old binary, which is what the
# helper-driven self-update ends with (the app exits once the transcript
# ends): --launch closes it before dpkg and opens the new one after.
install: deb
	DEVICE_HOST="$(DEVICE_HOST)" DEVICE_PORT="$(DEVICE_PORT)" DEVICE_USER="$(DEVICE_USER)" \
	DEVICE_PASSWORD="$(DEVICE_PASSWORD)" "$(DEVICE_INSTALLER)" "$(DEB_OUTPUT)" --launch

clean:
	rm -rf "$(DERIVED_DATA)"
	rm -rf "$(ROOT_DIR)/build/Packages"
