#!/bin/bash
# Builds the browser frontend in WebUI/ with webpack and, when run as an Xcode
# build phase, copies dist/ into the app bundle as irisin.app/WebUI, where the
# web server (Packages/IrisinWeb) reads index.html, app.js and app.css at
# runtime. Fila's Scripts/build-webui.sh, with pnpm: the version is the
# packageManager field of WebUI/package.json, run through corepack when no
# pnpm is on PATH.
#
# Standalone: `make webui` or `Scripts/build-webui.sh` just refreshes WebUI/dist.
set -euo pipefail

root="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
if command -v pnpm >/dev/null; then
    pnpm=(pnpm)
elif command -v corepack >/dev/null; then
    pnpm=(corepack pnpm)
else
    echo "error: pnpm is required to build the web UI (install Node.js, which brings corepack)" >&2
    exit 69
fi

cd "$root/WebUI"
if [[ ! -f node_modules/.modules.yaml || pnpm-lock.yaml -nt node_modules/.modules.yaml ]]; then
    "${pnpm[@]}" install --frozen-lockfile
fi
"${pnpm[@]}" run build
for file in index.html app.js app.css; do
    [[ -f "dist/$file" ]] || { echo "error: WebUI build did not produce dist/$file" >&2; exit 65; }
done

if [[ -n "${BUILT_PRODUCTS_DIR:-}" && -n "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ]]; then
    target="$BUILT_PRODUCTS_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/WebUI"
    rm -rf "$target"
    mkdir -p "$target"
    cp -R dist/. "$target/"
fi
