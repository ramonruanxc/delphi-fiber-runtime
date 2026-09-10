"""Build the pinned Unix context helper. Windows uses its native fiber API."""
import argparse
import pathlib
import platform
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]


def validate_demo(data):
    required = ('tasks', 'completed', 'yields', 'resume_calls', 'elapsed_us',
                'requested_stack_bytes_per_task', 'carrier_threads', 'cancelled', 'cancel_cleanup_count')
    if (data.get('format') != 'context-demo-v1' or not isinstance(data.get('backend'), str)
            or not data['backend'] or any(type(data.get(k)) is not int for k in required)):
        raise ValueError('Incomplete context demo metadata')
    if (data['tasks'] <= 0 or data['completed'] != data['tasks'] or data['yields'] < 0
            or data['resume_calls'] != data['yields'] + data['tasks']
            or data['elapsed_us'] < 0 or data['carrier_threads'] != 1
            or not 65536 <= data['requested_stack_bytes_per_task'] <= 67108864
            or data['cancelled'] != 1 or data['cancel_cleanup_count'] != 1):
        raise ValueError('Inconsistent context demo counts')
    return dict(data, context_transfers=2 * data['resume_calls'], qualification='descriptive',
                mean_us_per_resume_roundtrip=data['elapsed_us'] / data['resume_calls'])


def assembly_suffix(system, machine):
    if system == 'Windows' and machine.lower() in ('amd64', 'x86_64', 'x86', 'i386'):
        return None
    targets = {('Linux', 'x86_64'): 'x86_64_sysv_elf_gas.S',
               ('Darwin', 'x86_64'): 'x86_64_sysv_macho_gas.S',
               ('Darwin', 'arm64'): 'arm64_aapcs_macho_gas.S',
               ('Darwin', 'aarch64'): 'arm64_aapcs_macho_gas.S'}
    if (system, machine) not in targets:
        raise ValueError(f'Context backend unvalidated for {system}/{machine}')
    return targets[system, machine]


def build_native(directory, root=ROOT, run_tests=True):
    suffix = assembly_suffix(platform.system(), platform.machine())
    directory = pathlib.Path(directory).resolve()
    directory.mkdir(parents=True, exist_ok=True)
    if suffix is None:
        return directory
    source = pathlib.Path(root).resolve() / 'native/context'
    logs = []
    def invoke(command):
        result = subprocess.run([str(v) for v in command], capture_output=True, text=True, timeout=60)
        logs.append(' '.join(str(v) for v in command) + '\n' + result.stdout + result.stderr)
        (directory / 'native.log').write_text('\n'.join(logs), encoding='utf-8')
        if result.returncode:
            raise RuntimeError(f'Native context command failed ({result.returncode}): {logs[-1]}')
        return result.stdout
    inputs = [source / 'fr_context.c', source / 'boost' / ('make_' + suffix),
              source / 'boost' / ('jump_' + suffix)]
    objects = []
    for path in inputs:
        obj = directory / (path.stem + '.o')
        obj.unlink(missing_ok=True)
        flags = ['-std=c11', '-Wall', '-Wextra', '-Werror', '-O2', '-pthread'] if path.suffix == '.c' else []
        invoke(['cc', *flags, '-c', path, '-o', obj])
        if not obj.is_file():
            raise RuntimeError('Native compiler returned success without a new object')
        objects.append(obj)
    library = directory / 'libfr_context.a'
    library.unlink(missing_ok=True)
    invoke(['ar', 'rcs', library, *objects])
    if not library.is_file():
        raise RuntimeError('Archiver returned success without a new library')
    if run_tests:
        test = directory / 'ContextNativeTests'
        test.unlink(missing_ok=True)
        invoke(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-O2', '-pthread',
                source / 'context_tests.c', library, '-lm', '-o', test])
        if not test.is_file():
            raise RuntimeError('Native compiler returned success without a new test executable')
        result = invoke([test])
        if not result.startswith('PASS: native context lifecycle, nested yields, alternation, ownership, churn ('):
            raise RuntimeError('Native test missing positive marker')
        print(result.strip())
    return directory


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=pathlib.Path, default=ROOT / 'build/native')
    parser.add_argument('--skip-tests', action='store_true')
    args = parser.parse_args()
    build_native(args.out, run_tests=not args.skip_tests)
