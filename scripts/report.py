"""Validate periodic-v1 CSV before computing timing statistics. Stdlib only."""
import argparse
import csv
import io
import json
import math
import pathlib
import sys


def distribution(values):
    values = sorted(values)
    if not values:
        return dict.fromkeys(('min', 'p50', 'p95', 'p99', 'p999', 'max', 'mean'))
    def percentile(p):
        return values[max(0, math.ceil(len(values) * p) - 1)]
    return dict(min=values[0], p50=percentile(.5), p95=percentile(.95),
                p99=percentile(.99), p999=percentile(.999), max=values[-1],
                mean=sum(values) / len(values))


def analyze(text, max_lateness_us=None, max_violation_fraction=None):
    if (max_lateness_us is None) != (max_violation_fraction is None):
        raise ValueError('qualification requires both lateness and violation limits')
    if max_lateness_us is not None:
        if not math.isfinite(max_lateness_us) or max_lateness_us < 0:
            raise ValueError('lateness limit must be nonnegative and finite')
        if not math.isfinite(max_violation_fraction) or not 0 <= max_violation_fraction <= 1:
            raise ValueError('violation fraction must be between 0 and 1')
    metadata, body = {}, []
    for line in text.splitlines():
        if line.startswith('# '):
            key, sep, value = line[2:].partition('=')
            if not sep or key in metadata:
                raise ValueError('malformed or duplicate metadata')
            metadata[key] = value
        elif line.strip():
            body.append(line)
    required = ('format', 'backend', 'compiler', 'epoch_us', 'period_us',
                'planned_cycles', 'started_cycles', 'skipped_cycles')
    if any(k not in metadata for k in required) or metadata['format'] != 'periodic-v1':
        raise ValueError('incomplete or unsupported benchmark metadata')
    epoch, period, planned, started, skipped = (
        int(metadata[k]) for k in required[3:])
    if epoch < 0 or period <= 0 or planned <= 0 or min(started, skipped) < 0:
        raise ValueError('invalid schedule metadata')
    if started + skipped != planned:
        raise ValueError('started and skipped do not reconcile with planned cycles')
    reader = csv.DictReader(io.StringIO('\n'.join(body)))
    fields = ['index', 'deadline_us', 'start_us', 'finish_us']
    if reader.fieldnames != fields:
        raise ValueError('unexpected sample columns')
    lateness, duration, intervals = [], [], []
    previous_index, previous_start, previous_finish = 0, None, epoch
    for row in reader:
        if None in row or any(row[k] is None for k in fields):
            raise ValueError('malformed sample')
        index, deadline, start, finish = (int(row[k]) for k in fields)
        if not previous_index < index <= planned:
            raise ValueError('cycle indices must increase within the planned horizon')
        if deadline != epoch + index * period:
            raise ValueError('sample deadline does not match the fixed-rate schedule')
        if index != (start - epoch) // period or (previous_index and deadline <= previous_finish):
            raise ValueError('replayed, expired or out-of-horizon cycle')
        if start < deadline or finish < start or start < previous_finish:
            raise ValueError('early, backward or overlapping execution')
        lateness.append(start - deadline)
        duration.append(finish - start)
        if previous_start is not None:
            intervals.append(start - previous_start)
        previous_index, previous_start, previous_finish = index, start, finish
    if len(lateness) != started:
        raise ValueError('sample count does not match started cycles')
    result = dict(format='periodic-report-v1', metadata=metadata,
                  planned_cycles=planned, started_cycles=started, skipped_cycles=skipped,
                  start_lateness_us=distribution(lateness),
                  callback_duration_us=distribution(duration),
                  inter_start_us=distribution(intervals), qualification='descriptive')
    if max_lateness_us is not None:
        violations = skipped + sum(v > max_lateness_us for v in lateness)
        fraction = violations / planned
        result.update(violations=violations, violation_fraction=fraction,
                      profile=dict(max_lateness_us=max_lateness_us,
                                   max_violation_fraction=max_violation_fraction),
                      threshold_assessment='passed' if fraction <= max_violation_fraction else 'failed')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('csv', type=pathlib.Path)
    parser.add_argument('--output', type=pathlib.Path)
    parser.add_argument('--max-lateness-us', type=int)
    parser.add_argument('--max-violation-fraction', type=float)
    args = parser.parse_args()
    try:
        result = analyze(args.csv.read_text(encoding='utf-8-sig'), args.max_lateness_us,
                         args.max_violation_fraction)
        rendered = json.dumps(result, indent=2, allow_nan=False) + '\n'
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(rendered, encoding='utf-8')
        else:
            print(rendered, end='')
        return 1 if result.get('threshold_assessment') == 'failed' else 0
    except (ValueError, OSError) as error:
        print(f'Invalid benchmark: {error}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
