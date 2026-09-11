"""Fetch immutable benchmark inputs; these are not runtime dependencies."""
import json
import pathlib
import subprocess
from runtime_report import analyze, distribution, integer, validate_events

REFERENCES = {
    'pool': ('https://github.com/ramonruanxc/delphi-concurrent-pool.git', 'efef9d6ac9337d9e597feaf454e28474c99658d3'),
    'host': ('https://github.com/ramonruanxc/delphi-service-host.git', 'ed3be34f3b93b5040c9035b38dbfdb84e2766228'),
}


def fetch(directory):
    paths = []
    for name, (url, commit) in REFERENCES.items():
        target = directory / name
        target.mkdir(parents=True, exist_ok=True)
        def git(*args):
            return subprocess.check_output(['git', *args], cwd=target, text=True, stderr=subprocess.STDOUT, timeout=120).strip()
        if not (target / '.git').exists():
            git('init')
            git('remote', 'add', 'origin', url)
            git('fetch', '--depth', '1', 'origin', commit)
            git('checkout', '--detach', 'FETCH_HEAD')
        if git('rev-parse', 'HEAD') != commit or git('status', '--porcelain'):
            raise ValueError('Reference checkout is not the exact clean pinned revision: ' + name)
        paths.append(target / 'src')
    return paths


def report(data):
    if data.get('format') != 'reference-bench-v1' or data.get('mode') not in ('fibers', 'workers', 'pool', 'host'):
        raise ValueError('invalid comparison format or mode')
    count = integer(data['services'], 1)
    cycles = integer(data['planned_cycles'], 1)
    integer(data['workers'], 1)
    if len(data['runs']) != count:
        raise ValueError('service count mismatch')
    started = sum(len(r['samples']) for r in data['runs'])
    if data['mode'] != 'host':
        result = analyze(dict({k: v for k, v in data.items() if k != 'allocation_api_calls'}, format='runtime-demo-v1', carrier_threads=1, stopped=True,
                              sent=started, received=started, rejected=0))
        for key in ('accepted_events', 'received_events', 'rejected_events', 'disposed_events'):
            del result[key]
        result['contract'] = 'fixed-epoch native-timer adapter; pool jobs retain a worker while awaiting timers'
    else:
        intervals, durations = [], []
        for run in data['runs']:
            integer(run['epoch_us'])
            previous = None
            if len(run['samples']) > cycles:
                raise ValueError('host sample capacity exceeded')
            for index, sample in enumerate(run['samples'], 1):
                start, finish = integer(sample['start_us']), integer(sample['finish_us'])
                if integer(sample['index'], 1) != index or integer(sample['deadline_us']) != 0 or finish < start:
                    raise ValueError('invalid unmodified-host sample')
                if not run['epoch_us'] + 1000 <= start < run['epoch_us'] + (cycles + 1) * 1000:
                    raise ValueError('host sample outside measurement horizon')
                if previous is not None:
                    if start < previous['finish_us']:
                        raise ValueError('host overlap')
                    intervals.append(start - previous['start_us'])
                durations.append(finish - start)
                previous = sample
        result = dict(qualification='descriptive', services=count, started_activations=started,
                      inter_start_us=distribution(intervals), callback_duration_us=distribution(durations),
                      contract='unmodified service host, Interval=1ms; no fixed-epoch deadline or skipped-count claim')
    if 'events' in data:
        result['events'] = validate_events(data['events'], started)
    result['workload'] = 'mixed periodic/events' if 'events' in data else ('periodic CPU' if data.get('work_us', 0) else 'minimal periodic')
    result['work_us'] = integer(data.get('work_us', 0))
    result['event_capacity_semantics'] = 'pending deliveries only, excluding at most one active handler; fanout one and one consumer' if 'events' in data else None
    result['delivery_executor'] = {'fibers': 'one cooperative hub subscriber task on shared carrier',
        'workers': 'one pinned reference bus background dispatcher',
        'pool': 'separate pinned reference pool with one delivery worker',
        'host': 'unmodified host bus background dispatcher'}[data['mode']] if 'events' in data else None
    if 'allocation_api_calls' in data:
        result['allocation_api_calls'] = integer(data['allocation_api_calls'])
        result['allocation_window'] = data['allocation_window']
    result.update(format='reference-report-v1', mode=data['mode'], workers=data['workers'],
                  references={key: {'url': url, 'commit': commit} for key, (url, commit) in REFERENCES.items()},
                  limitation='Short independent process observations, not a controlled performance ranking. Workload parameters match; host cadence and delivery execution resources differ. Preallocated immutable payloads; reference bus allocates delivery copies, pool uses preallocated jobs, fibers use bounded hub envelopes.')
    return result


def collect(build, benchmark, compiler, root, out, flags):
    sources = fetch(out / 'reference-inputs')
    binary = build(compiler, 'demo/ReferenceDemo.dpr', out / 'reference-demo',
                   extra_flags=[*flags, *['-Fu' + str(path) for path in sources]])
    results = {}
    for workload, work_us, event_args in (
            ('minimal', 0, []), ('cpu', 100, []),
            ('mixed', 100, ['--events', '1', '--event-capacity', '256', '--payload-bytes', '64', '--callback-us', '25'])):
        for mode in ('fibers', 'workers', 'pool', 'host'):
            for services in (1, 8):
                name = f'reference-{mode}-{services}-{workload}'
                path = out / (name + '.raw.json')
                resources = benchmark(binary, [mode, '--services', str(services), '--cycles', '200',
                                      '--workers', '4', '--work-us', str(work_us), *event_args], path)
                result = report(json.loads(path.read_text(encoding='utf-8')))
                if result['started_activations'] == 0:
                    raise ValueError('Reference benchmark exercised no activation: ' + name)
                if workload == 'mixed' and result['events']['accepted'] == 0:
                    raise ValueError('Reference mixed benchmark accepted no event: ' + name)
                result['resources'] = resources
                (out / (name + '.json')).write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
                results[name] = result
    negative = build(compiler, 'demo/ReferenceDemo.dpr', out / 'REFERENCE_PROVE_HOST_FAULT',
                     ['REFERENCE_PROVE_HOST_FAULT'], [*flags, *['-Fu' + str(path) for path in sources]])
    result = subprocess.run([str(negative), 'host', '--services', '1', '--cycles', '20'],
                            capture_output=True, text=True, timeout=15)
    output = result.stdout + result.stderr
    (out / 'REFERENCE_PROVE_HOST_FAULT/run.log').write_text(output, encoding='utf-8')
    if result.returncode != 1 or output.strip() != 'ASSERTION FAILED: REFERENCE_HOST_FAULT':
        raise RuntimeError('Reference host fault gate did not fail explicitly: ' + output)
    return results
