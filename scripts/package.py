"""Package tracked sources and test a clean extracted Pascal consumer."""
import argparse
import hashlib
import json
import os
import pathlib
import platform
import subprocess
import sys
import tempfile
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from context_build import build_native, validate_demo


def validate_provenance(summary, commit, dirty, binary_hash, target_cpu, target_os):
    if dirty or summary.get('dirty') is not False or summary.get('commit') != commit:
        raise ValueError('packaging requires checks from this exact clean commit')
    if (summary.get('binary_sha256'), summary.get('target_cpu'), summary.get('target_os')) != (
            binary_hash, target_cpu, target_os):
        raise ValueError('native binary or compiler target differs from verified evidence')


def validate_context_provenance(summary, binary_hash):
    if summary.get('context_binary_sha256') != binary_hash:
        raise ValueError('context binary differs from verified evidence')


def create_source(root, destination, files):
    root = root.resolve()
    entries = []
    for name in files:
        path = pathlib.PurePosixPath(name.replace('\\', '/'))
        if path.is_absolute() or '..' in path.parts or ':' in name:
            raise ValueError('archive path must be relative and contained')
        source = (root / path).resolve()
        if not source.is_relative_to(root) or source.is_symlink():
            raise ValueError('archive path escaped source root')
        entries.append((source, path.as_posix()))
    with zipfile.ZipFile(destination, 'w', zipfile.ZIP_DEFLATED) as archive:
        for source, name in sorted(entries, key=lambda entry: entry[1]):
            archive.write(source, name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fpc', default='fpc')
    parser.add_argument('--out', type=pathlib.Path, default=ROOT / 'dist')
    parser.add_argument('--checks', type=pathlib.Path, default=ROOT / 'build/check')
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    checks = args.checks.resolve()
    summary = json.loads((checks / 'summary.json').read_text(encoding='utf-8'))
    binary = checks / 'demo' / ('PeriodicDemo.exe' if os.name == 'nt' else 'PeriodicDemo')
    context_binary = checks / 'context-demo' / ('ContextDemo.exe' if os.name == 'nt' else 'ContextDemo')
    target_cpu = subprocess.check_output([args.fpc, '-iTP'], text=True).strip()
    target_os = subprocess.check_output([args.fpc, '-iTO'], text=True).strip()
    commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    dirty = bool(subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=no'], cwd=ROOT, text=True).strip())
    validate_provenance(summary, commit, dirty, hashlib.sha256(binary.read_bytes()).hexdigest(), target_cpu, target_os)
    validate_context_provenance(summary, hashlib.sha256(context_binary.read_bytes()).hexdigest())
    files = subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT).decode().split('\0')
    source_zip = out / 'delphi-fiber-runtime-source.zip'
    create_source(ROOT, source_zip, [name for name in files if name])
    with tempfile.TemporaryDirectory(prefix='fiber consumer with spaces ') as temporary:
        consumer = pathlib.Path(temporary)
        with zipfile.ZipFile(source_zip) as archive:
            archive.extractall(consumer)
        binary = consumer / ('consumer.exe' if os.name == 'nt' else 'consumer')
        subprocess.run([args.fpc, '-B', '-Mdelphi', '-Fusrc', '-FU' + str(consumer),
                        '-o' + str(binary), 'demo/PeriodicDemo.dpr'], cwd=consumer,
                       check=True, timeout=60, stdout=subprocess.DEVNULL)
        result = subprocess.run([str(binary), '--cycles', '10'], cwd=consumer,
                                check=True, timeout=10, capture_output=True, text=True)
        if '# format=periodic-v1' not in result.stdout:
            raise RuntimeError('clean consumer produced no benchmark data')
        native = build_native(consumer / 'native-build', root=consumer, run_tests=False)
        context_consumer = consumer / ('context-consumer.exe' if os.name == 'nt' else 'context-consumer')
        subprocess.run([args.fpc, '-B', '-Mdelphi', '-Fusrc', '-Fl' + str(native),
                        '-FU' + str(consumer), '-o' + str(context_consumer), 'demo/ContextDemo.dpr'],
                       cwd=consumer, check=True, timeout=60, stdout=subprocess.DEVNULL)
        result = subprocess.run([str(context_consumer)], cwd=consumer, check=True,
                                timeout=30, capture_output=True, text=True)
        validate_demo(json.loads(result.stdout))
    # Machine reported by Python can differ from compiler target (e.g. Win32 on x64).
    native_zip = out / f'delphi-fiber-runtime-{target_os}-{target_cpu}.zip'
    with zipfile.ZipFile(native_zip, 'w', zipfile.ZIP_DEFLATED) as archive:
        archive.write(ROOT / 'LICENSE', 'LICENSE')
        archive.write(ROOT / 'native/context/boost/LICENSE_1_0.txt', 'THIRD_PARTY_LICENSES/Boost-1.0.txt')
        binary = checks / 'demo' / ('PeriodicDemo.exe' if os.name == 'nt' else 'PeriodicDemo')
        archive.write(binary, binary.name)
        archive.write(context_binary, context_binary.name)
        for path in checks.glob('*.json'):
            archive.write(path, 'evidence/' + path.name)
        for path in checks.glob('*.csv'):
            archive.write(path, 'evidence/' + path.name)
        archive.writestr('BUILD.json', json.dumps(dict(commit=summary['commit'],
                          compiler=summary['compiler'], target_os=target_os, target_cpu=target_cpu,
                          context_backend=summary['context_experiment']['backend']), indent=2))
    with zipfile.ZipFile(native_zip) as archive:
        if archive.read('LICENSE') != (ROOT / 'LICENSE').read_bytes():
            raise RuntimeError('native archive copyright notice differs from project license')
        if archive.read('THIRD_PARTY_LICENSES/Boost-1.0.txt') != (ROOT / 'native/context/boost/LICENSE_1_0.txt').read_bytes():
            raise RuntimeError('native archive third-party license missing or changed')
    hashes = [hashlib.sha256(path.read_bytes()).hexdigest() + '  ' + path.name
              for path in (source_zip, native_zip)]
    (out / 'SHA256SUMS.txt').write_text('\n'.join(hashes) + '\n', encoding='utf-8')
    print('PASS clean consumer and packaging: ' + native_zip.name)


if __name__ == '__main__':
    main()
