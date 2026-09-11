import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).parents[1] / 'scripts'))
from runtime_report import analyze, validate_execution


def sample():
    return dict(format='runtime-demo-v1', period_us=1000, planned_cycles=3,
                services=1, sent=2, received=2, rejected=0, stopped=True,
                carrier_threads=1, warmup_us=10000,
                runs=[dict(epoch_us=100, samples=[
                    dict(index=1, deadline_us=1100, start_us=1105, finish_us=1150),
                    dict(index=3, deadline_us=3100, start_us=3105, finish_us=3150)])])


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

    def test_rejects_loss_and_false_shutdown(self):
        for key, value in [('received', 1), ('stopped', False), ('services', 2), ('sent', True)]:
            data = sample()
            data[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                analyze(data)


if __name__ == '__main__':
    unittest.main()
