import importlib.util
import pathlib
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'scripts' / 'report.py'


class ReportTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('report', SCRIPT)
        self.report = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.report)

    def fixture(self):
        return '''# format=periodic-v1
# backend=test
# compiler=test
# epoch_us=0
# period_us=1000
# planned_cycles=5
# started_cycles=3
# skipped_cycles=2
# cpu_us=40
index,deadline_us,start_us,finish_us
1,1000,1010,1020
3,3000,3020,3050
5,5000,5000,5040
'''

    def test_includes_skipped_cycles_and_real_intervals(self):
        r = self.report.analyze(self.fixture())
        self.assertEqual(r['skipped_cycles'], 2)
        self.assertEqual(r['planned_cycles'], 5)
        self.assertEqual(r['start_lateness_us']['max'], 20)
        self.assertEqual(r['inter_start_us']['min'], 1980)
        self.assertEqual(r['qualification'], 'descriptive')

    def test_missing_required_metadata_rejected(self):
        with self.assertRaises(ValueError):
            self.report.analyze(self.fixture().replace('# planned_cycles=5\n', ''))

    def test_missing_samples_rejected(self):
        with self.assertRaises(ValueError):
            self.report.analyze(self.fixture().replace('5,5000,5000,5040\n', ''))

    def test_early_and_overlapping_execution_rejected(self):
        for replacement in ['3,3000,2999,3050', '3,3000,3020,5100']:
            with self.subTest(replacement=replacement), self.assertRaises(ValueError):
                self.report.analyze(self.fixture().replace('3,3000,3020,3050', replacement))

    def test_wrong_deadline_and_duplicate_cycle_rejected(self):
        for replacement in ['3,2999,3020,3050', '1,1000,3020,3050']:
            with self.subTest(replacement=replacement), self.assertRaises(ValueError):
                self.report.analyze(self.fixture().replace('3,3000,3020,3050', replacement))

    def test_qualification_counts_skipped_cycles_as_violations(self):
        r = self.report.analyze(self.fixture(), max_lateness_us=15, max_violation_fraction=0.5)
        self.assertEqual(r['violations'], 3)
        self.assertAlmostEqual(r['violation_fraction'], 0.6)
        self.assertEqual(r['threshold_assessment'], 'failed')
        self.assertEqual(r['qualification'], 'descriptive')

    def test_partial_or_invalid_profile_rejected(self):
        for kwargs in [dict(max_lateness_us=10), dict(max_violation_fraction=0.1),
                       dict(max_lateness_us=-1, max_violation_fraction=0),
                       dict(max_lateness_us=10, max_violation_fraction=float('nan'))]:
            with self.subTest(kwargs=kwargs), self.assertRaises(ValueError):
                self.report.analyze(self.fixture(), **kwargs)

    def test_zero_started_cycles_is_a_valid_measurement_not_a_pass(self):
        data = self.fixture().split('index,')[0].replace('started_cycles=3', 'started_cycles=0').replace('skipped_cycles=2', 'skipped_cycles=5')
        data += 'index,deadline_us,start_us,finish_us\n'
        r = self.report.analyze(data, max_lateness_us=100, max_violation_fraction=0)
        self.assertEqual(r['threshold_assessment'], 'failed')
        self.assertIsNone(r['start_lateness_us']['p99'])

    def test_replayed_expired_and_out_of_horizon_cycles_rejected(self):
        for old, new in [('1,1000,1010,1020', '1,1000,2500,2600'),
                         ('1,1000,1010,1020', '1,1000,1010,3000'),
                         ('5,5000,5000,5040', '5,5000,9000,9040')]:
            with self.subTest(new=new), self.assertRaises(ValueError):
                self.report.analyze(self.fixture().replace(old, new))

    def test_threshold_pass_does_not_certify_environment(self):
        r = self.report.analyze(self.fixture(), 100, 1)
        self.assertEqual(r['threshold_assessment'], 'passed')
        self.assertEqual(r['qualification'], 'descriptive')


if __name__ == '__main__':
    unittest.main()
