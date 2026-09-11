"""Validate integrated runtime samples before reporting descriptive distributions."""
import math


def integer(value, minimum=0):
    if type(value) is not int or value < minimum:
        raise ValueError('expected integer >= ' + str(minimum))
    return value


def distribution(values):
    if not values:
        return None
    ordered = sorted(values)
    result = {name: ordered[max(0, math.ceil(len(values) * p) - 1)]
              for name, p in [('p50', .5), ('p95', .95), ('p99', .99), ('p999', .999)]}
    return dict(result, min=ordered[0], max=ordered[-1], mean=sum(values) / len(values))


def validate_events(events, started):
    if events.get('enabled') is not True:
        raise ValueError('mixed workload must declare enabled events')
    result = {key: integer(events.get(key), 1 if key in ('capacity', 'payload_bytes', 'fanout') else 0)
              for key in ('capacity', 'payload_bytes', 'fanout', 'callback_us', 'attempted',
                          'accepted', 'delivered', 'disposed', 'rejected', 'handler_faults')}
    if (result['attempted'] != started or result['accepted'] + result['rejected'] != started
            or result['accepted'] * result['fanout'] != result['delivered'] + result['disposed']
            or result['handler_faults'] != 0):
        raise ValueError('event admission, fanout, completion or disposal accounting failed')
    return result


def trace_stages(row):
    wait, observed, ready, resumed = [row.get(k) for k in
        ('wait_deadline_us', 'timer_observed_us', 'ready_enqueued_us', 'resumed_us')]
    reason = row.get('ready_reason')
    if reason not in ('spawn', 'yield', 'wake', 'timer', 'cancel', 'resume', 'inline'):
        raise ValueError('missing or unknown ready reason')
    generation = integer(row.get('generation'))
    ready_generation = integer(row.get('ready_generation'))
    if ready_generation > generation:
        raise ValueError('ready generation exceeds callback generation')
    if reason == 'inline':
        if any(v is not None for v in (observed, ready, resumed)) or integer(wait) > row['start_us']:
            raise ValueError('inline timed wait has invented dispatch stages')
        return None
    resume_generation = integer(row.get('resume_generation'))
    if not ready_generation <= resume_generation <= generation:
        raise ValueError('invalid ready/resume/callback generation order')
    ready, resumed = integer(ready), integer(resumed)
    if not ready <= resumed <= row['start_us']:
        raise ValueError('invalid ready/resume/start order')
    if reason == 'timer':
        wait, observed = integer(wait), integer(observed)
        if not wait <= observed <= ready:
            raise ValueError('invalid timer observation order')
        return (observed - wait, ready - observed, resumed - ready, row['start_us'] - resumed)
    if observed is not None:
        raise ValueError('non-timer dispatch claims timer observation')
    if wait is not None:
        integer(wait)
    return None


def analyze(data):
    if data.get('format') not in ('runtime-demo-v1', 'runtime-demo-v2') or data.get('stopped') is not True:
        raise ValueError('missing runtime format or successful shutdown')
    traced = data['format'] == 'runtime-demo-v2'
    count = integer(data['services'], 1)
    cycles = integer(data['planned_cycles'], 1)
    period = integer(data['period_us'], 1)
    if integer(data['carrier_threads'], 1) != 1 or len(data['runs']) != count:
        raise ValueError('inconsistent carrier/service count')
    sent, received = integer(data['sent']), integer(data['received'])
    rejected = integer(data['rejected'])
    disposed = integer(data.get('disposed', 0))
    if sent != received + disposed:
        raise ValueError('accepted deliveries were lost or duplicated')
    integer(data['warmup_us'])
    lateness, duration, interval = [], [], []
    stages = [[], [], [], []]
    started, excluded, discontinuities = 0, 0, []
    for service in data['runs']:
        epoch = integer(service['epoch_us'])
        previous_index, previous_start, previous_finish, previous_generation = 0, None, epoch, None
        previous_clean = False
        for row in service['samples']:
            index = integer(row['index'], 1)
            due, start, finish = [integer(row[key]) for key in ('deadline_us', 'start_us', 'finish_us')]
            generation = integer(row.get('generation', 0))
            end_generation = integer(row.get('finish_generation', generation))
            if end_generation < generation:
                raise ValueError('generation moved backward')
            current_epoch = integer(row.get('epoch_us', epoch))
            if previous_generation is not None and generation < previous_generation:
                raise ValueError('generation moved backward')
            if previous_generation is not None and generation != previous_generation:
                discontinuities.append(dict(old_generation=previous_generation, new_generation=generation,
                                            old_epoch_us=epoch, new_epoch_us=current_epoch))
                previous_index, previous_start = 0, None
            elif current_epoch != epoch:
                raise ValueError('epoch changed without generation transition')
            epoch = current_epoch
            if not previous_index < index <= cycles or due != epoch + index * period:
                raise ValueError('invalid index or fixed-rate phase')
            if not due <= start <= finish or start < previous_finish:
                raise ValueError('early start, negative duration or overlap')
            if index != (start - epoch) // period or (previous_index and due <= previous_finish):
                raise ValueError('backlog replay or activation while previous invocation active')
            clean = generation == end_generation
            if traced:
                clean = clean and row.get('ready_generation') == generation
                if row.get('resume_generation') is not None:
                    clean = clean and row['resume_generation'] == generation
            measured = trace_stages(row) if traced else None
            started += 1
            if clean:
                lateness.append(start - due)
                duration.append(finish - start)
                if previous_start is not None and previous_clean:
                    interval.append(start - previous_start)
                if measured is not None:
                    for target, value in zip(stages, measured):
                        target.append(value)
            else:
                excluded += 1
            previous_index, previous_start, previous_finish = index, start, finish
            previous_generation, previous_clean = generation, clean
    if sent + rejected != started:
        raise ValueError('each recorded activation must account for one event')
    service_segments = []
    for service in data['runs']:
        if 'segments' not in service:
            continue
        metadata = service['segments']
        total, crossings = integer(metadata['discontinuity_count']), integer(metadata['crossing_count'])
        current = metadata['current']
        for key in ('generation', 'epoch_us', 'ended_us', 'started', 'skipped'):
            integer(current[key])
        if current['generation'] != total or crossings > total:
            raise ValueError('invalid service segment counters')
        last = metadata['last']
        if total:
            for key in ('generation', 'epoch_us', 'ended_us', 'started', 'skipped'):
                integer(last[key])
            if last['generation'] != total - 1 or not last['epoch_us'] <= last['ended_us'] == current['epoch_us']:
                raise ValueError('invalid last/current segment boundary')
        elif last is not None:
            raise ValueError('unexpected previous segment')
        service_segments.append(metadata)
    segmented = bool(discontinuities or excluded or any(s['discontinuity_count'] for s in service_segments))
    result = dict(format='runtime-report-v2' if traced else 'runtime-report-v1', qualification='descriptive',
                services=count, planned_activations=None if segmented else count * cycles,
                started_activations=started, skipped_activations=None if segmented else count * cycles - started,
                accepted_events=sent, received_events=received, rejected_events=rejected, disposed_events=disposed,
                start_lateness_us=distribution(lateness), callback_duration_us=distribution(duration),
                inter_start_us=distribution(interval), warmup_us=data['warmup_us'],
                excluded_discontinuous_activations=excluded, discontinuities=discontinuities,
                service_segments=service_segments, segment_history='bounded last and current snapshots; counts include earlier transitions')
    for key, values in zip(('timer_observation_delay_us', 'observation_to_ready_us', 'ready_to_resume_us', 'resume_to_callback_us'), stages):
        result[key] = distribution(values)
    result['measurement_stages'] = 'scheduler eligibility observation and dispatch trace; not OS interrupt arrival' if traced else 'unavailable in reference adapter'
    if 'events' in data:
        result['events'] = validate_events(data['events'], started)
    if 'allocation_api_calls' in data:
        result['pascal_memory'] = {key: integer(data[key]) for key in
                                  ('allocation_api_calls', 'pascal_heap_used_before',
                                   'pascal_heap_used_after', 'pascal_heap_peak_used')}
        result['pascal_memory']['limitation'] = 'FPC allocation entry-point calls during declared observation window; heap peak is process lifetime, not OS committed memory. Observer adds overhead.'
    return result


def validate_execution(data):
    result = analyze(data)
    if result['started_activations'] == 0:
        raise ValueError('No runtime activation exercised; cannot certify demo execution')
    return result
