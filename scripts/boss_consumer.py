"""Install with real Boss in a fresh consumer, then compile and run its sources."""
import argparse
import hashlib
import io
import json
import os
import pathlib
import subprocess
import sys
import tarfile
import tempfile

from build_example import MARKER
from install_boss import install, VERSION

ROOT = pathlib.Path(__file__).resolve().parents[1]
PACKAGE = 'github.com/ramonruanxc/delphi-fiber-runtime'


def verify_installed(library, cache, expected_commit):
    # Boss exports files without .git. Searching upward from modules would read
    # the consumer's repository and could falsely certify the wrong dependency.
    if not (cache / 'HEAD').is_file():
        raise ValueError('Boss dependency cache is missing')
    git = ['git', '--git-dir=' + str(cache)]
    commit = subprocess.check_output([*git, 'rev-parse', 'HEAD'], text=True, timeout=30).strip()
    if commit != expected_commit:
        raise ValueError(f'Boss installed {commit}, expected {expected_commit}')
    exported = subprocess.check_output([*git, 'archive', '--format=tar', 'HEAD'], timeout=60)
    count = 0
    with tarfile.open(fileobj=io.BytesIO(exported)) as archive:
        for entry in archive:
            if entry.isdir():
                continue
            if not entry.isfile():
                raise ValueError('Unexpected non-file in package source: ' + entry.name)
            path = (library / entry.name).resolve()
            if not path.is_relative_to(library.resolve()):
                raise ValueError('Package archive path escaped library')
            actual, expected = path.read_bytes(), archive.extractfile(entry).read()
            if path.suffix.lower() in ('.pas', '.inc', '.dfm', '.dpk', '.dproj'):
                actual, expected = actual.replace(b'\r\n', b'\n'), expected.replace(b'\r\n', b'\n')
            if actual != expected:
                raise ValueError('Installed source differs from expected revision: ' + entry.name)
            count += 1
    if count == 0:
        raise ValueError('Boss dependency source is empty')
    return count


def run(command, cwd, env, log):
    try:
        result = subprocess.run([str(value) for value in command], cwd=cwd, env=env,
                                capture_output=True, text=True, encoding='utf-8',
                                errors='replace', timeout=240)
    except subprocess.TimeoutExpired as error:
        chunks = [value.decode('utf-8', errors='replace') if isinstance(value, bytes)
                  else value or '' for value in (error.stdout, error.stderr)]
        log.write_text(''.join(chunks) + '\nTIMEOUT\n', encoding='utf-8')
        raise
    output = result.stdout + result.stderr
    log.write_text(output, encoding='utf-8')
    if result.returncode:
        raise RuntimeError(f'Consumer command exited {result.returncode}; see {log}')
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--boss', type=pathlib.Path)
    parser.add_argument('--ref', help='Branch/tag constraint in consumer boss.json; omit to test plain install')
    parser.add_argument('--expected-commit', required=True, help='Reject silent Boss fallback to another revision')
    parser.add_argument('--repository', default=PACKAGE)
    parser.add_argument('--out', type=pathlib.Path, default=ROOT / 'build/boss-consumer')
    parser.add_argument('--fpc', default='fpc')
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    (out / 'summary.json').unlink(missing_ok=True)
    boss = args.boss.resolve() if args.boss else install(out / 'tools')
    repository = args.repository.removeprefix('https://')
    if not repository.startswith('github.com/'):
        repository = 'github.com/' + repository
    with tempfile.TemporaryDirectory(prefix='boss consumer with spaces ', dir=out) as temporary:
        consumer = pathlib.Path(temporary)
        env = os.environ.copy()
        env['BOSS_HOME'] = str(consumer / '.boss-home')
        version = run([boss, '--version'], consumer, env, out / 'version.log')
        if 'v' + VERSION not in version:
            raise ValueError('Consumer qualification requires Boss ' + VERSION)
        run([boss, 'init', '--quiet'], consumer, env, out / 'init.log')
        if args.ref:
            manifest_path = consumer / 'boss.json'
            manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
            manifest['dependencies'][repository] = args.ref
            manifest_path.write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
            command = [boss, 'install']
        else:
            command = [boss, 'install', repository]
        run(command, consumer, env, out / 'install.log')
        library = consumer / 'modules' / repository.replace('.', '_').replace('/', '_')
        metadata = json.loads((library / 'boss.json').read_text(encoding='utf-8'))
        if metadata['name'] != PACKAGE or metadata['mainsrc'] != 'src':
            raise ValueError('Installed package identity or source path differs')
        # MD5 is only Boss's cache directory naming convention, not validation.
        cache_name = hashlib.md5(repository.lower().encode('utf-8'), usedforsecurity=False).hexdigest()
        cache = pathlib.Path(env['BOSS_HOME']) / 'cache' / cache_name
        verified_files = verify_installed(library, cache, args.expected_commit)
        commit = args.expected_commit
        (out / 'commit.log').write_text(commit + '\n', encoding='utf-8')
        for path in ('src/FiberRuntime.Scheduler.pas', 'demo/QuickStart.dpr',
                     'native/context/boost/LICENSE_1_0.txt', 'scripts/context_build.py'):
            if not (library / path).is_file():
                raise ValueError('Installed package is incomplete: ' + path)
        output = run([sys.executable, library / 'scripts/build_example.py',
                      '--out', out / 'quickstart', '--fpc', args.fpc],
                     consumer, env, out / 'build-run.log')
        if MARKER not in output:
            raise ValueError('Installed QuickStart did not report successful cleanup')
        for name in ('boss.json', 'boss-lock.json'):
            (out / ('consumer-' + name)).write_bytes((consumer / name).read_bytes())
        binary = out / 'quickstart' / ('QuickStart.exe' if os.name == 'nt' else 'QuickStart')
        summary = dict(boss_version=VERSION, repository=repository, requested_ref=args.ref,
                       commit=commit, package_version=metadata['version'],
                       verified_source_files=verified_files,
                       binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                       result=MARKER)
        (out / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n', encoding='utf-8')
    print('PASS Boss installed and executed QuickStart from ' + commit)


if __name__ == '__main__':
    main()
