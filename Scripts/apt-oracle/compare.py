#!/usr/bin/env python3
"""Synthetic, independently authored APT/dpkg black-box fixtures. No upstream tests.
Run against a disposable Ubuntu 24.04 container with apt 2.8.3 / dpkg 1.22.6.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess


def run(*args, ok=True):
    p = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if ok and p.returncode:
        raise RuntimeError(f'{args}:\n{p.stdout}')
    return p


def package(name, version='1', **fields):
    return dict(package=name, version=version, architecture='arm64', description='Irisin synthetic fixture', maintainer='Fixture <fixture@example.invalid>', **{k.replace('_', '-'): v for k, v in fields.items()})


def control(fields):
    return ''.join(f'{k.title()}: {v}\n' for k, v in fields.items()) + '\n'


QUERY_FORMAT = '-f=${Package} ${Version} ${db:Status-Status}\n'


def installed_versions(query_output):
    """The installed name -> version map from a dpkg-query run with QUERY_FORMAT."""
    return {parts[0]: parts[1] for line in query_output.splitlines() if len(parts := line.split()) == 3 and parts[2] == 'installed'}


def cases():
    yield 'predepends', [package('app', pre_depends='library (>= 2)'), package('library'), package('library', '2')], [], ['app'], [], False
    yield 'or-backtrack', [package('app', depends='bad | good, required'), package('bad', conflicts='required'), package('good'), package('required')], [], ['app'], [], False
    yield 'versioned-provides', [package('app', depends='virtual (>= 2)'), package('wrong', '99', provides='virtual'), package('right', provides='virtual (= 2)')], [], ['app'], [], False
    yield 'revision-zero', [package('app', depends='library (= 1-0)'), package('library')], [], ['app'], [], False
    yield 'dependency-cycle', [package('aa', depends='bb'), package('bb', depends='aa')], [], ['aa'], [], False
    yield 'reverse-removal', [], [package('app', depends='library'), package('library')], [], ['library'], False
    yield 'replace-provider', [package('new', provides='virtual')], [package('app', depends='virtual'), package('old', provides='virtual')], ['new'], ['old'], False
    yield 'reverse-conflict', [package('app')], [package('existing', conflicts='app')], ['app'], [], False
    yield 'replaces-only', [package('app', replaces='other')], [package('other')], ['app'], [], False
    yield 'conservative-update', [package('aa', '2', depends='new'), package('new'), package('bb', '2', conflicts='keep')], [package('aa'), package('bb'), package('keep')], [], [], True
    yield 'old-predepends', [package('aa', '2', pre_depends='bb (>= 1)'), package('bb', '2', pre_depends='aa (>= 1)')], [package('aa'), package('bb')], ['aa', 'bb'], [], False
    yield 'breaks-upgrade', [package('aa', '2', breaks='bb (<< 2)'), package('bb', '2', breaks='aa (<< 2)')], [package('aa'), package('bb')], ['aa', 'bb'], [], False


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--container', default='irisin-resolver-oracle')
    parser.add_argument('--probe', required=True)
    parser.add_argument('--native-probe')
    parser.add_argument('--output', default='build/resolver-oracle')
    args = parser.parse_args()
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    def docker(*command, ok=True):
        return run('docker', 'exec', args.container, *command, ok=ok)
    versions = docker('sh', '-c', 'apt-get --version | head -1; dpkg --version | head -1').stdout
    assert 'apt 2.8.3 ' in versions and '1.22.6' in versions, versions
    image = run('docker', 'inspect', args.container, '--format', '{{.Image}}').stdout.strip()
    docker('mkdir', '-p', '/oracle')
    report = {'versions': versions, 'image': image, 'native': bool(args.native_probe), 'cases': []}
    for name, available, installed, install, remove, update in cases():
        directory = output / name
        directory.mkdir(exist_ok=True)
        indexed = [dict(p, filename=p['package'] + '_' + p['version'] + '.deb', size='1') for p in available]
        status = [dict(p, status='install ok installed') for p in installed]
        fixture = dict(available=indexed, installed=status, install=install, remove=remove, updateAll=update, architecture='arm64')
        fixture_path = directory / 'input.json'
        fixture_path.write_text(json.dumps(fixture))
        (directory / 'Packages').write_text(''.join(map(control, indexed)))
        (directory / 'status').write_text(''.join(map(control, status)))
        root = f'/oracle/{name}'
        (directory / 'sources.list').write_text(f'deb [trusted=yes] file:{root} ./\n')
        (directory / 'lists' / 'partial').mkdir(parents=True, exist_ok=True)
        (directory / 'archives' / 'partial').mkdir(parents=True, exist_ok=True)
        run('docker', 'cp', str(directory), f'{args.container}:/oracle/')
        options = ['-o', f'Dir::Etc::sourcelist={root}/sources.list', '-o', 'Dir::Etc::sourceparts=-', '-o', f'Dir::State::status={root}/status', '-o', f'Dir::State::lists={root}/lists', '-o', f'Dir::Cache::archives={root}/archives', '-o', 'APT::Architecture=arm64', '-o', 'APT::Install-Recommends=false', '-o', 'APT::Install-Suggests=false', '-o', 'Debug::NoLocking=true']
        docker('apt-get', *options, 'update')
        command = ['--with-new-pkgs', 'upgrade'] if update else ['install'] + install + [p + '-' for p in remove]
        apt = docker('apt-get', '-s', *options, *command, ok=False)
        (directory / 'apt.log').write_text(apt.stdout)
        expected = {p['package']: p['version'] for p in installed}
        for line in apt.stdout.splitlines():
            if match := re.match(r'Remv (\S+)', line): expected.pop(match[1], None)
            if match := re.match(r'Inst (\S+)(?: \[[^\]]+\])? \((\S+)', line): expected[match[1]] = match[2]
        probe = run(args.probe, str(fixture_path))
        (directory / 'resolver.json').write_text(probe.stdout)
        result = json.loads(probe.stdout)
        if apt.returncode:
            # APT 2.8's greedy resolver does not backtrack this OR choice.
            # Keep the difference explicit; validate the SAT result with real dpkg.
            assert name == 'or-backtrack', (name, apt.stdout)
            expected = {'app': '1', 'good': '1', 'required': '1'}
        assert result['final'] == expected, (name, result['final'], expected, apt.stdout)
        # Build minimal real archives and execute the resolver's exact stages.
        archives = {}
        for label, packages in [('installed', installed), ('available', available)]:
            for p in packages:
                source = directory / f"{label}-{p['package']}-{p['version']}"
                (source / 'DEBIAN').mkdir(parents=True, exist_ok=True)
                (source / 'DEBIAN' / 'control').write_text(control(p))
                marker = source / 'usr' / 'share' / 'irisin-fixture' / p['package']
                marker.parent.mkdir(parents=True, exist_ok=True)
                marker.write_text(p['version'])
                run('docker', 'cp', str(source), f'{args.container}:{root}/')
                archive = f'{root}/{source.name}.deb'
                docker('dpkg-deb', '--build', '--root-owner-group', f'{root}/{source.name}', archive)
                archives[(label, p['package'], p['version'])] = archive
        execution_root = root + '/execution'
        admindir = execution_root + '/var/lib/dpkg'
        docker('rm', '-rf', execution_root)
        docker('mkdir', '-p', admindir)
        docker('touch', admindir + '/status')
        dpkg = ['dpkg', '--root=' + execution_root]
        log = ''
        if installed:
            log += docker(*dpkg, '--unpack', *[archives[('installed', p['package'], p['version'])] for p in installed]).stdout
            log += docker(*dpkg, '--configure', '--pending').stdout
        install_archives = {p: archives[('available', p, v)] for p, v in result['install'].items()}
        if args.native_probe:
            native_root = directory / 'native-root'
            native_admindir = native_root / 'var/lib/dpkg'
            if native_root.exists(): shutil.rmtree(native_root)
            run('docker', 'cp', f'{args.container}:{execution_root}', str(native_root))
            native_archives = {}
            for identity, archive in install_archives.items():
                local_archive = directory / Path(archive).name
                run('docker', 'cp', f'{args.container}:{archive}', str(local_archive))
                native_archives[identity] = str(local_archive)
            native_input = directory / 'native-input.json'
            native_input.write_text(json.dumps(dict(root=str(native_root), database=str(native_admindir), archives=native_archives, remove=result['remove'], stages=result['stages'])))
            native = run(args.native_probe, str(native_input), ok=False)
            (directory / 'native.log').write_text(native.stdout)
            assert native.returncode == 0, (name, native.stdout)
            # Ask dpkg itself to parse the database written by the native engine.
            native_database = root + '/native-database'
            docker('rm', '-rf', native_database)
            run('docker', 'cp', str(native_admindir), f'{args.container}:{native_database}')
            query = docker('dpkg-query', '--admindir=' + native_database, '-W', QUERY_FORMAT)
            native_final = installed_versions(query.stdout)
            assert native_final == result['final'], (name, native_final, result['final'], query.stdout)
        for stage in result['stages']:
            operation, body = next(iter(stage.items()))
            identities = body['_0']
            arguments = ['--' + operation]
            if operation == 'unpack':
                arguments += ['--auto-deconfigure']
                identities = [install_archives[p] for p in identities]
            if operation == 'configure': arguments += ['--force-confdef', '--force-confold']
            log += docker(*dpkg, *arguments, *identities).stdout
        (directory / 'dpkg.log').write_text(log)
        actual = docker('dpkg-query', '--admindir=' + admindir, '-W', QUERY_FORMAT, ok=False).stdout
        final = installed_versions(actual)
        assert final == expected, (name, final, expected, actual)
        report['cases'].append(dict(name=name, seconds=result['seconds'], fixtureSHA256=hashlib.sha256(fixture_path.read_bytes()).hexdigest(), aptExit=apt.returncode))
        print(f'{name}: APT exit={apt.returncode}; final set and real dpkg stages passed', flush=True)
    (output / 'report.json').write_text(json.dumps(report, indent=2))


if __name__ == '__main__': main()
