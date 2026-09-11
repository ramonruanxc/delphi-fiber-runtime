"""Build and execute functional/negative checks; collect descriptive timing data."""
import argparse
import hashlib
import importlib.util
import json
import os
import pathlib
import platform
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from context_build import build_native, validate_demo
from runtime_report import validate_execution as analyze_runtime
from references import collect as collect_references
from compatibility import probe
from provenance import dirty as repository_dirty


def expected_failure(code, output, assertion):
    return code == 1 and output.strip() == 'ASSERTION FAILED: ' + assertion


def run(command, timeout=60, cwd=ROOT):
    result = subprocess.run([str(c) for c in command], cwd=cwd, capture_output=True,
                            text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f'Command failed ({result.returncode}): {command}\n{result.stdout}\n{result.stderr}')
    return result.stdout + result.stderr


def build(fpc, source, directory, defines=(), extra_flags=()):
    directory.mkdir(parents=True, exist_ok=True)
    binary = directory / (pathlib.Path(source).stem + ('.exe' if os.name == 'nt' else ''))
    binary.unlink(missing_ok=True)
    output = run([fpc, '-B', '-Mdelphi', '-Sa', '-Cr', '-Co', '-Fusrc',
                  '-FU' + str(directory), '-o' + str(binary),
                  *['-d' + d for d in defines], *extra_flags, source])
    (directory / 'compile.log').write_text(output, encoding='utf-8')
    if not binary.is_file():
        raise RuntimeError('Compiler returned success without creating executable: ' + str(binary))
    return binary


def benchmark(binary, args, csv_path):
    # Polling is only in this optional observer process, never in the scheduler.
    try:
        import psutil
    except ImportError:
        psutil = None
    stderr_path = csv_path.with_suffix('.stderr.log')
    started_at = time.monotonic()
    peaks = dict(rss_bytes=0, vms_bytes=0, native_threads=0, cpu_seconds=0)
    private_commit_peak = None
    observations = 0
    with csv_path.open('w', encoding='utf-8') as stdout, stderr_path.open('w', encoding='utf-8') as stderr:
        child = subprocess.Popen([str(binary), *args], stdout=stdout, stderr=stderr)
        try:
            process = psutil.Process(child.pid) if psutil else None
            while child.poll() is None:
                if time.monotonic() - started_at > 60:
                    raise TimeoutError('benchmark exceeded 60 seconds')
                if process:
                    try:
                        memory, cpu = process.memory_info(), process.cpu_times()
                        peaks['rss_bytes'] = max(peaks['rss_bytes'], memory.rss)
                        peaks['vms_bytes'] = max(peaks['vms_bytes'], memory.vms)
                        private = getattr(memory, 'private', None) if os.name == 'nt' else None
                        if private is not None:
                            private_commit_peak = max(private_commit_peak or 0, private)
                        peaks['native_threads'] = max(peaks['native_threads'], process.num_threads())
                        peaks['cpu_seconds'] = max(peaks['cpu_seconds'], cpu.user + cpu.system)
                        observations += 1
                    except (psutil.NoSuchProcess, psutil.AccessDenied):
                        pass
                time.sleep(.02)
            if child.returncode != 0:
                raise RuntimeError(f'benchmark failed: {child.returncode}; see {stderr_path}')
        finally:
            if child.poll() is None:
                child.kill()
            child.wait()
    return dict(observer='psutil sampled every 20ms' if psutil else 'unavailable',
                observations=observations, sampled_peaks=peaks if observations else None,
                memory_accounting=dict(private_committed_bytes=private_commit_peak,
                    private_committed_status=('sampled Windows PrivateUsage peak; excludes shared mappings'
                        if private_commit_peak is not None else 'unavailable for this observer/target'),
                    reserved_bytes=None, reserved_status='not measured; RSS/VMS and stack requests are not reservations'),
                elapsed_seconds=time.monotonic() - started_at,
                limitation='Sampling can miss peaks and perturb timing. CPU is last observed cumulative usage; VMS is not committed memory.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fpc', default='fpc')
    parser.add_argument('--out', type=pathlib.Path, default=ROOT / 'build/check')
    parser.add_argument('--core-only', action='store_true', help='Validate independent schedule/timer units without a context compiler requirement')
    parser.add_argument('--references', action='store_true', help='Fetch pinned reference libraries and run descriptive comparisons')
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    (out / 'summary.json').unlink(missing_ok=True)
    summary = dict(platform=platform.platform(), machine=platform.machine(),
                   python=sys.version, compiler=run([args.fpc, '-iV']).strip(),
                   target_cpu=run([args.fpc, '-iTP']).strip(),
                   target_os=run([args.fpc, '-iTO']).strip(),
                   commit=run(['git', 'rev-parse', 'HEAD']).strip(),
                   dirty=repository_dirty(ROOT),
                   build_flags=['-B', '-Mdelphi', '-Sa', '-Cr', '-Co'],
                   power_mode='not recorded; shared-runner timings are descriptive', checks={}, benchmarks={})
    print(run([sys.executable, '-m', 'unittest', 'discover', '-s', 'tests', '-p', 'test_*.py']))
    summary['core_probe'] = probe(args.fpc, 'fpc', ROOT)
    if summary['core_probe']['status'] != 'passed':
        raise RuntimeError('Independent core consumer failed')
    if args.core_only:
        for name in ('ScheduleTests', 'PlatformTests', 'NotificationTests'):
            binary = build(args.fpc, 'tests/' + name + '.dpr', out / name)
            output = run([binary], timeout=45)
            if 'PASS ' + name not in output:
                raise RuntimeError('Missing positive core marker')
            summary['checks'][name] = output.strip()
        summary['qualification'] = 'core only; contexts not tested'
        (out / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n', encoding='utf-8')
        print('PASS independent core checks; no context qualification')
        return
    if summary['compiler'] != '3.2.2':
        raise RuntimeError('Integrated context checks require FPC 3.2.2; use --core-only for other compilers')
    native = build_native(out / 'native')
    context_flags = ['-Fl' + str(native), '-Ct', '-O2']
    summary['context_build_flags'] = [*summary['build_flags'], '-Ct', '-O2']
    for name in ('ScheduleTests', 'PlatformTests', 'NotificationTests', 'ContextTests', 'SchedulerTests', 'ChannelTests', 'ServiceTests', 'ServiceResumeTests', 'EventHubTests'):
        binary = build(args.fpc, 'tests/' + name + '.dpr', out / name,
                       extra_flags=context_flags if name not in ('ScheduleTests', 'PlatformTests', 'NotificationTests') else ())
        result = run([binary], timeout=30)
        (out / name / 'run.log').write_text(result, encoding='utf-8')
        marker = {'ChannelTests': 'PASS: channel FIFO, backpressure, close/drain, cancellation, ownership',
                  'ServiceTests': 'PASS: service fixed epoch, persistent task, skips, stop, timeout, ownership',
                  'ServiceResumeTests': 'PASS: periodic resume rebase, no replay, active preservation, segments, cancellation',
                  'EventHubTests': 'PASS: managed event lifetime, bounded fanout, stop, active timeout, native post'}.get(name, 'PASS ' + name)
        if marker not in result:
            raise RuntimeError('Missing positive test marker: ' + name)
        summary['checks'][name] = result.strip()
        print(result.strip())
    for define, assertion in [('PROVE_DRIFT', 'FIXED_RATE_NO_DRIFT'), ('PROVE_OVERLAP', 'NO_OVERLAP')]:
        binary = build(args.fpc, 'tests/ScheduleTests.dpr', out / define, [define])
        result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
        output = result.stdout + result.stderr
        (out / define / 'run.log').write_text(output, encoding='utf-8')
        if not expected_failure(result.returncode, output, assertion):
            raise RuntimeError(f'Unexpected negative result for {define}: {result.returncode}: {output}')
        summary['checks'][define] = dict(exit_code=result.returncode, assertion=output.strip())
        print('PASS negative ' + define)
    mutations = [('CONTEXT_PROVE_IDENTITY', 'CONTEXT_TASK_IDENTITY')]
    if os.name != 'nt':
        mutations.append(('CONTEXT_PROVE_RTL', 'CONTEXT_RTL_ISOLATION'))
    else:
        summary['checks']['CONTEXT_PROVE_RTL'] = 'not applicable: Windows uses native SEH, not the Unix SJLJ adapter'
    for define, assertion in mutations:
        binary = build(args.fpc, 'tests/ContextTests.dpr', out / define, [define], context_flags)
        result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
        output = result.stdout + result.stderr
        (out / define / 'run.log').write_text(output, encoding='utf-8')
        if not expected_failure(result.returncode, output, assertion):
            raise RuntimeError(f'Unexpected context negative result {define}: {result.returncode}: {output}')
        summary['checks'][define] = dict(exit_code=result.returncode, assertion=output.strip())
        print('PASS negative ' + define)
    if os.name != 'nt':
        name = 'CONTEXT_TEST_NO_CTHREADS'
        binary = build(args.fpc, 'tests/ContextTests.dpr', out / name, [name], context_flags)
        result = run([binary], timeout=10)
        (out / name / 'run.log').write_text(result, encoding='utf-8')
        if result.strip() != 'PASS ContextTests no-cthreads rejection':
            raise RuntimeError('Missing explicit no-thread-manager rejection evidence')
        summary['checks'][name] = result.strip()
    spec = importlib.util.spec_from_file_location('report', ROOT / 'scripts/report.py')
    report = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(report)
    binary = build(args.fpc, 'demo/PeriodicDemo.dpr', out / 'demo')
    summary['binary_sha256'] = hashlib.sha256(binary.read_bytes()).hexdigest()
    for name, options in [('idle', ['--cycles', '2000']),
                          ('short-work', ['--cycles', '1000', '--work-us', '100']),
                          ('overloaded', ['--cycles', '200', '--work-us', '2500'])]:
        csv_path = out / (name + '.csv')
        resources = benchmark(binary, options, csv_path)
        result = report.analyze(csv_path.read_text(encoding='utf-8'))
        if name == 'overloaded' and result['skipped_cycles'] == 0:
            raise RuntimeError('Overloaded workload did not record skipped cycles')
        result['resources'] = resources
        (out / (name + '.json')).write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
        summary['benchmarks'][name] = result
        print(f"{name}: started={result['started_cycles']} skipped={result['skipped_cycles']}; descriptive")
    context_binary = build(args.fpc, 'demo/ContextDemo.dpr', out / 'context-demo', extra_flags=context_flags)
    summary['context_binary_sha256'] = hashlib.sha256(context_binary.read_bytes()).hexdigest()
    raw = run([context_binary], timeout=30)
    context_result = validate_demo(json.loads(raw))
    (out / 'context-demo.json').write_text(json.dumps(context_result, indent=2) + '\n', encoding='utf-8')
    summary['context_experiment'] = context_result
    print(f"context: {context_result['completed']} completed, {context_result['yields']} yields; descriptive")
    for source, define, assertion in [('SchedulerTests', 'CONTEXT_PROVE_READY', 'SCHEDULER_READY_ONCE'),
                                       ('ServiceTests', 'CONTEXT_PROVE_SERVICE_STOP', 'SERVICE_STOP_NO_CALLBACK')]:
        binary = build(args.fpc, 'tests/' + source + '.dpr', out / define, [define], context_flags)
        result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=15)
        output = result.stdout + result.stderr
        (out / define / 'run.log').write_text(output, encoding='utf-8')
        if not expected_failure(result.returncode, output, assertion):
            raise RuntimeError('Unexpected integration negative result: ' + define + ': ' + output)
        summary['checks'][define] = dict(exit_code=result.returncode, assertion=output.strip())
    runtime_binary = build(args.fpc, 'demo/RuntimeDemo.dpr', out / 'runtime-demo', extra_flags=context_flags)
    summary['runtime_binary_sha256'] = hashlib.sha256(runtime_binary.read_bytes()).hexdigest()
    summary['runtime_benchmarks'] = {}
    for name, options in [('one-service', ['--services', '1']), ('eight-services', ['--services', '8']),
                          ('32-services', ['--services', '32']), ('short-work', ['--services', '8', '--work-us', '100']),
                          ('suspended-work', ['--services', '8', '--await-us', '2500'])]:
        raw_path = out / ('runtime-' + name + '.raw.json')
        resources = benchmark(runtime_binary, ['--cycles', '200', *options], raw_path)
        report = analyze_runtime(json.loads(raw_path.read_text(encoding='utf-8')))
        report['resources'] = resources
        summary['runtime_benchmarks'][name] = report
        (out / ('runtime-' + name + '.json')).write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    if args.references:
        summary['comparisons'] = collect_references(build, benchmark, args.fpc, ROOT, out, context_flags)
    (out / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n', encoding='utf-8')
    print('PASS all functional checks; timing is descriptive')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired, TimeoutError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
