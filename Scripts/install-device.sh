#!/bin/bash
# Install a built .deb onto a jailbroken device over SSH; optionally relaunch.
#
# The device is reached through usbmuxd, not the network: `iproxy 2333 22`
# forwards a local port to the device's sshd.
#
#   Scripts/install-device.sh build/Packages/wiki.qaq.irisin_4.0.0_iphoneos-arm64.deb [--launch]
#
# Overridable: DEVICE_HOST, DEVICE_PORT, DEVICE_USER, DEVICE_PASSWORD.
# Without DEVICE_PASSWORD the usual ssh key path is used.

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 || ($# -eq 2 && "$2" != --launch) ]]; then
    echo "usage: install-device.sh <package.deb> [--launch]" >&2
    exit 64
fi
package="$1"
host="${DEVICE_HOST:-127.0.0.1}"
port="${DEVICE_PORT:-2333}"
user="${DEVICE_USER:-mobile}"
password="${DEVICE_PASSWORD:-}"

test -f "$package" || { echo "error: $package does not exist" >&2; exit 66; }

ssh_options=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ConnectTimeout=10
)

if [ -n "$password" ]; then
    command -v sshpass >/dev/null || { echo "error: DEVICE_PASSWORD is set but sshpass is not installed (brew install sshpass)" >&2; exit 69; }
    run_ssh() { sshpass -p "$password" ssh "${ssh_options[@]}" -p "$port" "$user@$host" "$@"; }
    run_scp() { sshpass -p "$password" scp "${ssh_options[@]}" -P "$port" "$@"; }
else
    run_ssh() { ssh "${ssh_options[@]}" -p "$port" "$user@$host" "$@"; }
    run_scp() { scp "${ssh_options[@]}" -P "$port" "$@"; }
fi

if ! nc -z "$host" "$port" 2>/dev/null; then
    echo "error: nothing is listening on $host:$port." >&2
    echo "       Start the usbmuxd forward first:  iproxy $port 22" >&2
    exit 69
fi

shell_quote() {
    local quote="'" escaped="'\\''"
    printf "'%s'" "${1//$quote/$escaped}"
}

# Keep the password on sudo's stdin, never in the remote command string.
run_sudo() {
    local command="sh -c $(shell_quote "$1")"
    if [ -n "$password" ]; then
        printf '%s\n' "$password" | run_ssh "sudo -S -p '' $command"
    else
        run_ssh "sudo $command"
    fi
}

remote_directory=
cleanup_upload() {
    if [ -n "$remote_directory" ]; then
        run_sudo "rm -f $(shell_quote "$remote_directory/package.deb") && rmdir $(shell_quote "$remote_directory")" || {
            echo "error: could not remove installation temporary: $remote_directory" >&2
            return 1
        }
    fi
}
trap cleanup_upload EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# This installer updates an existing installation. Derive its actual
# bootstrap from dpkg instead of guessing a rootless or roothide prefix.
remote_directory="$(run_sudo '
    set -eu
    if ! daemon="$(dpkg -L wiki.qaq.irisin | grep "/usr/libexec/irisind$")" || [ ! -f "$daemon" ]; then
        echo "error: cannot locate the installed irisind; install the package once by hand before using this updater" >&2
        exit 1
    fi
    case "$daemon" in /*) ;; *) echo "error: installed daemon path is not absolute" >&2; exit 1 ;; esac
    install_root="${daemon%/usr/libexec/irisind}"
    install_root="$(cd -P "${install_root:-/}" && pwd -P)"
    directory="$(mktemp -d "${install_root%/}/.irisin-install.XXXXXXXX")"
    cleanup() { rmdir "$directory"; }
    trap cleanup EXIT
    chown "${SUDO_UID:?}:${SUDO_GID:?}" "$directory"
    chmod 0700 "$directory"
    printf "%s\n" "$directory"
    trap - EXIT
')"
remote_package="$remote_directory/package.deb"
echo "==> copying $(basename "$package") to $user@$host:$port"
run_scp "$package" "$user@$host:$remote_package"

if [[ "${2:-}" == --launch ]]; then
    run_ssh 'if killall -0 irisin 2>/dev/null; then
        killall -TERM irisin || exit
        attempts=0
        while killall -0 irisin 2>/dev/null; do
            attempts=$((attempts + 1))
            if [ "$attempts" -ge 20 ]; then echo "error: irisin did not exit" >&2; exit 1; fi
            sleep 0.25
        done
    fi'
fi

# `dpkg -i` runs the package's own postinst, which boots the daemon and
# registers the app with SpringBoard. Nothing here duplicates that.
echo "==> installing"
run_sudo "dpkg -i $(shell_quote "$remote_package")"

echo "==> installed; removing the copy"
cleanup_upload
remote_directory=

if [[ "${2:-}" == --launch ]]; then
    echo "==> opening Irisin"
    run_ssh "uiopen --bundleid wiki.qaq.irisin"
fi
