#!/usr/bin/env python3
"""Refuse an app entitlements file that does not name the GPU.

A bootstrap withholds the GPU's IOKit user clients from an ad-hoc signed
binary until `com.apple.security.iokit-user-client-class` names them, and
system frameworks reach for them in an app that never draws with Metal:
IconServices composites an app icon through Core Image (Inspector 0.6.2
crashed at launch in `CI::GLContext::GLContext`, Inspector #15), Bold Text
and the share sheet do the same through UIKit (Irisin, Irisin #65). Nothing
in the build notices the miss; the app dies on the user's device.

Both spellings of the key must carry every class below: the kernel's denial
names the plain one, and Irisin's Bold Text fix was the `exception.` one.
Extra classes are allowed. Copied verbatim from platformize-app-ios
`scripts/`; a class found in a new crash report is added there first.

usage: check-gpu-entitlements.py <app.entitlements>...
"""
import plistlib
import sys

KEYS = (
    'com.apple.security.iokit-user-client-class',
    'com.apple.security.exception.iokit-user-client-class',
)

REQUIRED = (
    'AGXCommandQueue',
    'AGXDevice',
    'AGXDeviceUserClient',
    'AGXSharedUserClient',
    'AGXGLContext',
    'AppleParavirtDeviceUserClient',
    'IOAccelerator',
    'IOAccelContext',
    'IOAccelContext2',
    'IOAccelDevice',
    'IOAccelDevice2',
    'IOAccelSharedUserClient',
    'IOAccelSharedUserClient2',
    'IOAccelSubmitter2',
    'IOGPUDeviceUserClient',
    'IOSurfaceRootUserClient',
    'IOSurfaceAcceleratorClient',
    'IOSurfaceAcceleratorParavirtClient',
    'IOMobileFramebufferUserClient',
    'AppleJPEGDriverUserClient',
    'H11ANEInDirectPathClient',
    'AppleVirtIONeuralEngineDeviceUserClient',
    'IOHIDLibUserClient',
    'IOHIDEventServiceFastPathUserClient',
)


def problems(path):
    with open(path, 'rb') as handle:
        entitlements = plistlib.load(handle)
    for key in KEYS:
        value = entitlements.get(key)
        if not isinstance(value, list):
            yield f'{key} is missing'
            continue
        missing = [name for name in REQUIRED if name not in value]
        if missing:
            yield f'{key} is missing {", ".join(missing)}'


def main(paths):
    if not paths:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 64
    failed = False
    for path in paths:
        for problem in problems(path):
            print(f'error: {path}: {problem} — the app crashes wherever a '
                  'system framework reaches for the GPU (app icons, Bold '
                  'Text, the share sheet)', file=sys.stderr)
            failed = True
    if failed:
        return 65
    print(f'ok: the GPU list is whole in {len(paths)} entitlements file(s)')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
