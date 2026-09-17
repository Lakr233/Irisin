#!/usr/bin/env python3
"""Convert externally cached Debian Packages metadata to a probe input.
Keeps provenance next to generated data, never vendors distribution metadata.
"""
import argparse
import hashlib
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('packages')
parser.add_argument('output')
parser.add_argument('--install', default='hello')
args = parser.parse_args()
source = Path(args.packages)
raw = source.read_bytes()
fields_to_keep = {'package', 'version', 'architecture', 'depends', 'pre-depends', 'provides', 'conflicts', 'breaks', 'replaces', 'essential', 'protected', 'multi-arch', 'filename', 'sha256'}
packages = []
for paragraph in raw.decode().split('\n\n'):
    fields = {}
    previous = None
    for line in paragraph.splitlines():
        if line.startswith((' ', '\t')):
            if previous in fields: fields[previous] += ' ' + line.strip()
        elif ':' in line:
            key, value = line.split(':', 1)
            previous = key.lower()
            if previous in fields_to_keep: fields[previous] = value.strip()
    if 'package' in fields and 'version' in fields: packages.append(fields)
Path(args.output).write_text(json.dumps(dict(available=packages, installed=[], install=[args.install], remove=[], updateAll=False, architecture='arm64')))
Path(args.output + '.provenance.json').write_text(json.dumps(dict(source=str(source), sourceSHA256=hashlib.sha256(raw).hexdigest(), records=len(packages)), indent=2))
print(len(packages), 'records')
