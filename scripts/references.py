"""Fetch immutable benchmark inputs; these are not runtime dependencies."""
import json
import pathlib
import subprocess
from runtime_report import analyze, distribution, integer

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
        if git('rev-parse', 'HEAD') != commit or git('status', '--porcelain', '--untracked-files=no'):
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
        result = analyze(dict(data, format='runtime-demo-v1', carrier_threads=1, stopped=True,
                              sent=started, received=started, rejected=0))
        for key in ('accepted_events', 'received_events', 'rejected_events'):
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
    result.update(format='reference-report-v1', mode=data['mode'], workers=data['workers'],
                  references={key: {'url': url, 'commit': commit} for key, (url, commit) in REFERENCES.items()},
                  limitation='Short independent process observations, not a controlled performance ranking. Minimal CPU callbacks; mixed events measured separately.')
    return result


def collect(build, benchmark, compiler, root, out, flags):
    sources = fetch(out / 'reference-inputs')
    binary = build(compiler, 'demo/ReferenceDemo.dpr', out / 'reference-demo',
                   extra_flags=[*flags, *['-Fu' + str(path) for path in sources]])
    results = {}
    for mode in ('fibers', 'workers', 'pool', 'host'):
        for services in (1, 8):
            name = f'reference-{mode}-{services}'
            path = out / (name + '.raw.json')
            resources = benchmark(binary, [mode, '--services', str(services), '--cycles', '200', '--workers', '4', '--work-us', '100'], path)
            result = report(json.loads(path.read_text(encoding='utf-8')))
            result['resources'] = resources
            (out / (name + '.json')).write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
            results[name] = result
    return results
