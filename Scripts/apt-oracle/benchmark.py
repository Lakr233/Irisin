#!/usr/bin/env python3
"""Reproducible synthetic catalogue sizes; all generated data stays in build/."""
import argparse
import json
from pathlib import Path
import platform
import re
import statistics
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--probe', required=True)
parser.add_argument('--output', default='build/resolver-benchmarks')
parser.add_argument('--baseline')
args = parser.parse_args()
output = Path(args.output)
output.mkdir(parents=True, exist_ok=True)
report = {'machine': platform.platform(), 'sizes': {}}
CHAIN = 31  # packages 0..CHAIN-1 each depend on the next, so resolving package-000000 pulls CHAIN + 1 packages
TIME_TOLERANCE = 1.5
MEMORY_TOLERANCE = 1.25
for size in (10000, 70000, 200000):
    available = []
    for i in range(size):
        package = {'package': f'package-{i:06}', 'version': '1', 'architecture': 'arm64', 'filename': f'{i}.deb'}
        if i < CHAIN: package['depends'] = f'package-{i+1:06}'
        available.append(package)
    fixture = output / f'{size}.json'
    fixture.write_text(json.dumps(dict(available=available, installed=[], install=['package-000000'], remove=[], updateAll=False, architecture='arm64')))
    runs = []
    for _ in range(3):
        measured = subprocess.run(['/usr/bin/time', '-l', args.probe, str(fixture)], text=True, capture_output=True, check=True)
        result = json.loads(measured.stdout)
        assert len(result['install']) == CHAIN + 1
        peak = re.search(r'(\d+)\s+maximum resident set size', measured.stderr)
        runs.append(dict(seconds=result['seconds'], peakBytes=int(peak[1])))
    report['sizes'][str(size)] = {'medianSeconds': statistics.median(r['seconds'] for r in runs), 'peakBytes': max(r['peakBytes'] for r in runs), 'runs': runs}
    print(size, report['sizes'][str(size)], flush=True)
if args.baseline:
    baseline = json.loads(Path(args.baseline).read_text())
    assert baseline['machine'] == report['machine'], 'Compare baselines on the same machine/toolchain'
    for size, result in report['sizes'].items():
        assert result['medianSeconds'] <= baseline['sizes'][size]['medianSeconds'] * TIME_TOLERANCE, f'{size}: time regression > {TIME_TOLERANCE - 1:.0%}'
        assert result['peakBytes'] <= baseline['sizes'][size]['peakBytes'] * MEMORY_TOLERANCE, f'{size}: memory regression > {MEMORY_TOLERANCE - 1:.0%}'
(output / 'report.json').write_text(json.dumps(report, indent=2))
