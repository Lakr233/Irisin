#!/usr/bin/env python3
"""Fetch the Packages index of every repository in a source list, the way
Irisin's refresh asks a roothide device's repositories for them, for
`ResolverProbe catalogue` to write into a database of its own.

    Scripts/fetch-repository-indexes.py <list.irisinrepos> build/resolver-catalogue
    cd Packages/AptRepository
    swift run -c release ResolverProbe catalogue ../../build/resolver-catalogue
    swift run -c release ResolverProbe bench ../../build/resolver-catalogue 9
    swift run -c release ResolverProbe golden ../../build/resolver-catalogue plans.json [--pool]

A flat repository is asked for <url>/Packages, a suite for
<url>/dists/<suite>/<component>/binary-<arch>/Packages: iphoneos-arm64e and
iphoneos-arm64 read together (the rootless adapter makes the second
installable), then each alone, then iphoneos-arm, less what the Release says
the suite does not have. Each entry is tried under every compression the app
knows, first that answers wins. The output directory gets indexes/<n>.txt,
decompressed and joined by a blank line as the refresh joins a suite's, and
manifest.json naming each repository's address and file. Keep it under
build/: the indexes are the repositories', not ours to commit.
"""
import bz2
import concurrent.futures
import gzip
import json
import lzma
import os
import plistlib
import subprocess
import sys
import urllib.request

PROBE = ["iphoneos-arm64e", "iphoneos-arm64", "iphoneos-arm"]
INSTALLABLE = {"iphoneos-arm64e", "iphoneos-arm64"}
SUFFIXES = ["bz2", "", "xz", "gz", "zst", "lzma"]
# what the app sends (DeviceIdentity); some repositories answer nothing without
HEADERS = {
    "User-Agent": "Irisin",
    "X-Machine": "iPhone14,2",
    "X-Unique-ID": "0" * 40,
    "X-Firmware": "16.5",
}


def get(url):
    try:
        request = urllib.request.Request(url, headers=HEADERS)
        with urllib.request.urlopen(request, timeout=25) as response:
            return response.read() if response.status == 200 else None
    except Exception:
        return None


def decompress(data, suffix):
    try:
        if suffix == "bz2":
            return bz2.decompress(data)
        if suffix in ("xz", "lzma"):
            return lzma.decompress(data)
        if suffix == "gz":
            return gzip.decompress(data)
        if suffix == "zst":
            return subprocess.run(["zstd", "-dc"], input=data, capture_output=True, check=True).stdout
        return data
    except Exception:
        return None


def read_entry(bases):
    """Every index of one entry under one suffix, or nothing."""
    for suffix in SUFFIXES:
        parts = []
        for base in bases:
            url = base + ("." + suffix if suffix else "")
            data = get(url)
            raw = decompress(data, suffix) if data is not None else None
            text = raw.decode("utf-8", errors="replace") if raw is not None else None
            # an error page answered with 200 is not an index
            if text is None or "<html" in text[:512].lower():
                break
            parts.append((url, text.strip()))
        else:
            body = "\n\n".join(text for _, text in parts if text)
            if "package:" in body.lower():
                return body, [url for url, _ in parts]
    return None


def architectures_listed(release):
    for line in release.splitlines():
        if line.lower().startswith("architectures:"):
            return line.split(":", 1)[1].split()
    return []


def fetch(index, source):
    url = source["url"]["relative"] if isinstance(source["url"], dict) else source["url"]
    suite = source.get("distribution")
    components = source.get("components", [])
    base = url.rstrip("/")
    if not suite or suite.endswith("/"):
        entries = [[(base + "/" + suite.rstrip("/") if suite else base) + "/Packages"]]
    else:
        directory = base + "/dists/" + suite
        release = get(directory + "/Release")
        offered = architectures_listed(release.decode("utf-8", "replace")) if release else []
        chain = [a for a in PROBE if a in offered] or PROBE
        together = [a for a in chain if a in INSTALLABLE]
        groups = ([together] if len(together) > 1 else []) + [[a] for a in together]
        groups += [[a] for a in chain if a not in INSTALLABLE]
        entries = [[f"{directory}/{c}/binary-{a}/Packages" for a in group for c in components] for group in groups]
    for bases in entries:
        read = read_entry(bases)
        if read:
            return index, url, read
    return index, url, None


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    sources = plistlib.load(open(sys.argv[1], "rb"))["sources"]
    output = sys.argv[2]
    os.makedirs(os.path.join(output, "indexes"), exist_ok=True)
    manifest = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=24) as pool:
        for index, url, read in pool.map(lambda pair: fetch(*pair), enumerate(sources)):
            if read is None:
                print("no index:", url, file=sys.stderr)
                manifest.append({"url": url, "file": None, "read": []})
                continue
            name = "indexes/%03d.txt" % index
            with open(os.path.join(output, name), "w") as file:
                file.write(read[0])
            manifest.append({"url": url, "file": name, "read": read[1]})
    with open(os.path.join(output, "manifest.json"), "w") as file:
        json.dump(manifest, file, indent=1)


main()
