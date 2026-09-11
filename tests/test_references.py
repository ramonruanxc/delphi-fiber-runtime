import pathlib
import sys
import unittest
sys.path.insert(0, str(pathlib.Path(__file__).parents[1] / 'scripts'))
from references import report


class ReferenceTests(unittest.TestCase):
    def data(self):
        return dict(format='reference-bench-v1', mode='host', services=1, workers=4,
                    planned_cycles=3, period_us=1000, warmup_us=50000,
                    runs=[dict(epoch_us=100, samples=[dict(index=1, deadline_us=0,
                                                          start_us=1105, finish_us=1150)])])

    def test_host_has_no_invented_skipped_deadlines(self):
        result = report(self.data())
        self.assertEqual(result['started_activations'], 1)
        self.assertNotIn('skipped_activations', result)
        self.assertIn('Interval=1ms', result['contract'])

    def test_rejects_bool_index_as_numeric_identity(self):
        data = self.data()
        data['runs'][0]['samples'][0]['index'] = True
        with self.assertRaises(ValueError):
            report(data)

    def test_rejects_outside_horizon_and_mismatched_count(self):
        data = self.data()
        data['runs'][0]['samples'][0]['start_us'] = 99
        with self.assertRaises(ValueError):
            report(data)
        data = self.data()
        data['services'] = 2
        with self.assertRaises(ValueError):
            report(data)


if __name__ == '__main__':
    unittest.main()
