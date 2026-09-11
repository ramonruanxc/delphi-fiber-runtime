import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).parents[1] / 'scripts'))
from runtime_report import analyze, validate_execution


def sample():
    return dict(format='runtime-demo-v2', period_us=1000, planned_cycles=3,
                services=1, sent=2, received=2, rejected=0, stopped=True,
                carrier_threads=1, warmup_us=10000,
                runs=[dict(epoch_us=100, samples=[
                    dict(index=1, deadline_us=1100, start_us=1105, finish_us=1150, generation=0, finish_generation=0, epoch_us=100, wait_deadline_us=1100, timer_observed_us=1101, ready_enqueued_us=1102, resumed_us=1103, ready_reason="timer", ready_generation=0, resume_generation=0),
                    dict(index=3, deadline_us=3100, start_us=3105, finish_us=3150, generation=0, finish_generation=0, epoch_us=100, wait_deadline_us=3100, timer_observed_us=3101, ready_enqueued_us=3102, resumed_us=3103, ready_reason="timer", ready_generation=0, resume_generation=0)])])


class RuntimeReportTests(unittest.TestCase):
    def test_empty_trace_is_descriptive_but_cannot_certify_execution(self):
        data = sample()
        data['runs'][0]['samples'] = []
        data['sent'] = data['received'] = 0
        self.assertEqual(analyze(data)['skipped_activations'], 3)
        with self.assertRaises(ValueError):
            validate_execution(data)

    def test_counts_trailing_and_internal_skips(self):
        result = analyze(sample())
        self.assertEqual(result['planned_activations'], 3)
        self.assertEqual(result['started_activations'], 2)
        self.assertEqual(result['skipped_activations'], 1)
        self.assertEqual(result['qualification'], 'descriptive')

    def test_rejects_wrong_phase_overlap_and_early_start(self):
        for field, value in [('deadline_us', 1200), ('start_us', 1099), ('finish_us', 3200)]:
            data = sample()
            data['runs'][0]['samples'][0][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                analyze(data)

    def test_measures_actual_timer_and_dispatch_stages(self):
        data = sample()
        row = data['runs'][0]['samples'][1]
        row.update(wait_deadline_us=2100, timer_observed_us=2101, ready_enqueued_us=2102)
        result = analyze(data)
        self.assertEqual(result['timer_observation_delay_us']['max'], 1)
        self.assertEqual(result['ready_to_resume_us']['max'], 1001)

    def test_rejects_missing_or_impossible_stages(self):
        for key, value in [('timer_observed_us', None), ('ready_enqueued_us', 1100),
                           ('resumed_us', 1106), ('ready_generation', 1)]:
            data = sample()
            data['runs'][0]['samples'][0][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                analyze(data)

    def test_discontinuous_invocation_excluded_from_normal_distributions(self):
        data = sample()
        data['runs'][0]['samples'][0]['finish_generation'] = 1
        result = analyze(data)
        self.assertEqual(result['started_activations'], 2)
        self.assertEqual(result['excluded_discontinuous_activations'], 1)
        self.assertEqual(result['callback_duration_us']['mean'], 45)
        self.assertIsNone(result['inter_start_us'])

    def test_rebase_records_segments_without_cross_segment_intervals(self):
        data = sample()
        data['runs'][0]['samples'][1].update(index=1, epoch_us=2100, generation=1,
            finish_generation=1, ready_generation=1, resume_generation=1)
        result = analyze(data)
        self.assertEqual(result['discontinuities'][0]['old_epoch_us'], 100)
        self.assertEqual(result['discontinuities'][0]['new_epoch_us'], 2100)
        self.assertIsNone(result['inter_start_us'])
        self.assertIsNone(result['planned_activations'])

    def test_inline_elapsed_wait_has_no_invented_observation(self):
        data = sample()
        data['runs'][0]['samples'][0].update(ready_reason='inline', timer_observed_us=None,
            ready_enqueued_us=None, resumed_us=None, resume_generation=None)
        self.assertEqual(analyze(data)['started_activations'], 2)

    def test_stop_disposal_is_not_reported_as_lost_delivery(self):
        data = sample()
        data.update(received=1, disposed=1)
        self.assertEqual(analyze(data)['disposed_events'], 1)

    def test_final_resume_without_callback_still_reported(self):
        data = sample()
        data['runs'][0]['segments'] = dict(discontinuity_count=1, crossing_count=0,
            last=dict(generation=0, epoch_us=100, ended_us=4000, started=2, skipped=1),
            current=dict(generation=1, epoch_us=4000, ended_us=0, started=0, skipped=0))
        result = analyze(data)
        self.assertEqual(result['service_segments'][0]['discontinuity_count'], 1)
        self.assertIsNone(result['planned_activations'])

    def test_rejects_loss_and_false_shutdown(self):
        for key, value in [('received', 1), ('stopped', False), ('services', 2), ('sent', True)]:
            data = sample()
            data[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                analyze(data)


if __name__ == '__main__':
    unittest.main()
