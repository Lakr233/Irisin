#!/usr/bin/env python3
"""Refuse a command line whose entitlements have drifted from the app's.

`irisin-cli` (Documentation/CommandLine.md) reads what the app keeps: the vendor
sign-in in the Keychain, stored without an access group, so it lands in the
first of the app's `keychain-access-groups`. The command line finds it only
with the same groups in the same order. It is also a client of irisind,
which admits it by the same client keys the app carries. These keys are
compared; everything else is the command line's own, and none of the
helper's storage or LaunchServices keys may appear in it.

usage: check-cli-entitlements.py <irisin.entitlements> <irisin-cli.entitlements>
"""
import plistlib
import sys

SAME = (
    'application-identifier',
    'keychain-access-groups',
    'com.apple.private.system-keychain',
    'platform-application',
    'wiki.qaq.irisin.client',
    'com.apple.private.security.no-sandbox',
    'com.apple.security.network.client',
)

ALLOWED = set(SAME) | {'com.apple.private.security.no-container'}


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 64
    with open(sys.argv[1], 'rb') as file:
        app = plistlib.load(file)
    with open(sys.argv[2], 'rb') as file:
        command = plistlib.load(file)
    failures = []
    for key in SAME:
        if key not in app:
            failures.append(f'{key} is missing from the app')
        elif command.get(key) != app[key]:
            failures.append(f'{key} is {command.get(key)!r} for the command line, {app[key]!r} for the app')
    for key in sorted(set(command) - ALLOWED):
        failures.append(f'{key} is not the command line\'s to have')
    for failure in failures:
        print(f'error: {sys.argv[2]}: {failure}', file=sys.stderr)
    return 65 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
