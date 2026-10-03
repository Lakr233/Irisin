#!/usr/bin/env python3
"""Refuse a LaunchDaemon plist template whose launchd paths name no root.

Roothide's launchctl rewrites the paths launchd itself opens (its
`plistpatch.m`): each one gets the bootstrap root put in front, as the
program does, unless it starts with `/rootfs/`, which is stripped instead.
A system directory spelled bare is therefore watched, logged to or chdir'd
into inside the bootstrap, where it never exists. Nothing fails: launchd
watches a path that never changes and the job is never started (Xrash's
`WatchPaths` on the report directory, found 2026-10-03). Rootless leaves
every path alone, so a literal `/rootfs/` is wrong there.

So every such path is spelled from a placeholder the packager fills:
`@PREFIX@/` for a path inside the bootstrap (empty for roothide, `/var/jb`
for rootless) and `@ROOTFS@/` for the system's (`/rootfs` for roothide,
empty for rootless). The program is always `@PREFIX@/`: a job whose program
is under `/rootfs/` is a system job to roothide and nothing in it is moved.
A template that uses `@ROOTFS@` must name the scripts that substitute it.

The arguments after a program path are read by the program, inside the
bootstrap's view, and are not checked. A template with no launchd path
beyond its program passes as it is; nothing here asks for `@ROOTFS@`.
Copied verbatim from platformize-app-ios `scripts/`; a key roothide starts
moving is added there first.

usage: check-launchd-paths.py <daemon.plist>... [--substituted-by <script>]...
"""
import argparse
import plistlib
import sys

PREFIX = '@PREFIX@/'
ROOTFS = '@ROOTFS@/'

# The keys plistpatch.m moves, as Knife's ServiceRootHidePlist lists them.
PATH_KEYS = ('RootDirectory', 'WorkingDirectory', 'StandardInPath', 'StandardOutPath', 'StandardErrorPath')
PATH_LIST_KEYS = ('WatchPaths', 'QueueDirectories')
ENVIRONMENT_PATH_KEYS = ('CFFIXED_USER_HOME', 'HOME', 'TMPDIR')


def launchd_paths(job):
    """(where, path) for every path launchd opens, the program first."""
    program = job.get('Program')
    if program is None and isinstance(job.get('ProgramArguments'), list) and job['ProgramArguments']:
        program = job['ProgramArguments'][0]
        yield 'ProgramArguments[0]', program
    elif program is not None:
        yield 'Program', program
    for key in PATH_KEYS:
        if key in job:
            yield key, job[key]
    for key in PATH_LIST_KEYS:
        for index, value in enumerate(job.get(key) or []):
            yield f'{key}[{index}]', value
    environment = job.get('EnvironmentVariables')
    if isinstance(environment, dict):
        for key in ENVIRONMENT_PATH_KEYS:
            if key in environment:
                yield f'EnvironmentVariables.{key}', environment[key]
    keep_alive = job.get('KeepAlive')
    if isinstance(keep_alive, dict) and isinstance(keep_alive.get('PathState'), dict):
        for path in keep_alive['PathState']:
            yield 'KeepAlive.PathState', path
    sockets = job.get('Sockets')
    if isinstance(sockets, dict):
        for name, value in sockets.items():
            # a socket entry is one dictionary, or an array of them
            for socket in value if isinstance(value, list) else [value]:
                if isinstance(socket, dict) and 'SockPathName' in socket:
                    yield f'Sockets.{name}.SockPathName', socket['SockPathName']
    events = job.get('LaunchEvents')
    if isinstance(events, dict) and isinstance(events.get('com.apple.fsevents.matching'), dict):
        for name, event in events['com.apple.fsevents.matching'].items():
            if isinstance(event, dict) and 'Path' in event:
                yield f'LaunchEvents.com.apple.fsevents.matching.{name}.Path', event['Path']


def problems(path):
    with open(path, 'rb') as handle:
        job = plistlib.load(handle)
    if not isinstance(job, dict):
        return ['is not a launchd job dictionary'], False
    found = []
    uses_rootfs = False
    for where, value in launchd_paths(job):
        if not isinstance(value, str):
            found.append(f'{where} is not a string')
        elif where in ('Program', 'ProgramArguments[0]'):
            if not value.startswith(PREFIX):
                found.append(f"{where} '{value}' must start with {PREFIX}")
        elif value.startswith(ROOTFS):
            uses_rootfs = True
        elif not value.startswith(PREFIX):
            found.append(
                f"{where} '{value}' names no root: roothide's launchctl puts the bootstrap root in front of it; "
                f'spell a system path {ROOTFS}... and a bootstrap one {PREFIX}...'
            )
    return found, uses_rootfs


def main(arguments):
    parser = argparse.ArgumentParser(usage=__doc__.split('usage: ')[1].strip())
    parser.add_argument('plists', nargs='+')
    parser.add_argument('--substituted-by', action='append', default=[], dest='scripts')
    options = parser.parse_args(arguments)
    substituted = any('@ROOTFS@' in open(s, encoding='utf-8').read() for s in options.scripts)
    failed = False
    for plist in options.plists:
        found, uses_rootfs = problems(plist)
        if uses_rootfs and not substituted:
            found.append('uses @ROOTFS@ and no --substituted-by script fills it')
        for problem in found:
            print(f'error: {plist}: {problem}', file=sys.stderr)
            failed = True
    return 1 if failed else 0

if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
