#!/usr/bin/env bash
# Build the reference half of the adapter's conformance test: roothide's own
# RootHidePatcher (patch.sh, Compat Layer mode) run over sample rootless
# packages on a jailbroken device, the way its app runs it.
#
#   Scripts/adapter-reference.sh <RootHidePatcher checkout> <dir>
#
# <dir>/in/*.deb are the samples; the patched packages land in <dir>/ref under
# the same names (a package the patcher refuses leaves none). Then:
#
#   cd Packages/AptRepository
#   ADAPTER_CONFORMANCE_DIR=<dir> swift test --filter AdapterConformanceTests
#
# The device needs Procursus ldid, dpkg-deb and what patch.sh calls:
#   apt install file gawk plutil odcctools
# DEVICE_HOST, DEVICE_PORT and DEVICE_USER pick the device (a user that can
# sudo, since the patcher refuses anyone but root).

set -Eeuo pipefail

if [[ "$#" -ne 2 ]]; then
    echo "usage: $0 <RootHidePatcher checkout> <dir>" >&2
    exit 64
fi

patcher="$1"
dir="$2"
host="${DEVICE_HOST:-127.0.0.1}"
port="${DEVICE_PORT:-2222}"
user="${DEVICE_USER:-mobile}"
remote=/var/mobile/RootHidePatcher

[[ -f "$patcher/patch.sh" ]] || { echo "error: no patch.sh in $patcher" >&2; exit 66; }
compgen -G "$dir/in/*.deb" >/dev/null || { echo "error: no samples in $dir/in" >&2; exit 66; }

ssh_opts=(-p "$port" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
device() { ssh "${ssh_opts[@]}" "$user@$host" "$@"; }

device "rm -rf $remote/in $remote/out $remote/tool && mkdir -p $remote/in $remote/out $remote/tool"
scp -P "$port" "${ssh_opts[@]:2}" "$patcher/patch.sh" "$patcher/roothide.entitlements" "$user@$host:$remote/tool/"
scp -P "$port" "${ssh_opts[@]:2}" "$dir"/in/*.deb "$user@$host:$remote/in/"

# patch.sh deletes its input on a device, so each sample is patched from a
# copy; sudo resets PATH, which the bootstrap's tools need
device -t "sudo env PATH=/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/sbin:\$PATH bash -c '
    cd $remote
    for deb in in/*.deb; do
        name=\$(basename \"\$deb\" .deb)
        echo \"== \$name\"
        cp \"\$deb\" \"$remote/\$name.work.deb\"
        bash tool/patch.sh \"$remote/\$name.work.deb\" \"$remote/out/\$name.deb\" AutoPatches || echo \"refused: \$name\"
        rm -f \"$remote/\$name.work.deb\"
    done
'"

rm -rf "$dir/ref"
mkdir -p "$dir/ref"
if device "ls $remote/out/*.deb" >/dev/null 2>&1; then
    scp -P "$port" "${ssh_opts[@]:2}" "$user@$host:$remote/out/*.deb" "$dir/ref/"
fi
ls -l "$dir/ref"
