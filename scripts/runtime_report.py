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


def analyze(data):
    if data.get('format') != 'runtime-demo-v1' or data.get('stopped') is not True:
        raise ValueError('missing runtime format or successful shutdown')
    count = integer(data['services'], 1)
    cycles = integer(data['planned_cycles'], 1)
    period = integer(data['period_us'], 1)
    if integer(data['carrier_threads'], 1) != 1 or len(data['runs']) != count:
        raise ValueError('inconsistent carrier/service count')
    sent, received = integer(data['sent']), integer(data['received'])
    rejected = integer(data['rejected'])
    if sent != received:
        raise ValueError('accepted channel deliveries were lost or duplicated')
    integer(data['warmup_us'])
    lateness, duration, interval = [], [], []
    for service in data['runs']:
        epoch = integer(service['epoch_us'])
        previous_index, previous_start, previous_finish = 0, None, epoch
        for row in service['samples']:
            index = integer(row['index'], 1)
            due, start, finish = [integer(row[key]) for key in ('deadline_us', 'start_us', 'finish_us')]
            if not previous_index < index <= cycles or due != epoch + index * period:
                raise ValueError('invalid index or fixed-rate phase')
            if not due <= start <= finish or start < previous_finish:
                raise ValueError('early start, negative duration or overlap')
            if index != (start - epoch) // period or (previous_index and due <= previous_finish):
                raise ValueError('backlog replay or activation while previous invocation active')
            lateness.append(start - due)
            duration.append(finish - start)
            if previous_start is not None:
                interval.append(start - previous_start)
            previous_index, previous_start, previous_finish = index, start, finish
    started = len(lateness)
    if sent + rejected != started:
        raise ValueError('each completed recorded activation must account for one event')
    result = dict(format='runtime-report-v1', qualification='descriptive',
                services=count, planned_activations=count * cycles,
                started_activations=started, skipped_activations=count * cycles - started,
                accepted_events=sent, received_events=received, rejected_events=rejected,
                start_lateness_us=distribution(lateness), callback_duration_us=distribution(duration),
                inter_start_us=distribution(interval), warmup_us=data['warmup_us'])
    if 'allocation_api_calls' in data:
        result['pascal_memory'] = {key: integer(data[key]) for key in
                                  ('allocation_api_calls', 'pascal_heap_used_before',
                                   'pascal_heap_used_after', 'pascal_heap_peak_used')}
        result['pascal_memory']['limitation'] = 'FPC allocation entry-point calls during RunUntil; heap peak is process lifetime, not OS committed memory. Observer adds overhead.'
    return result
