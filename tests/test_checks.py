import importlib.util
import pathlib
import subprocess
import unittest

SPEC = importlib.util.spec_from_file_location('checks', pathlib.Path(__file__).parents[1] / 'scripts/check.py')
checks = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(checks)


class NegativeGateTests(unittest.TestCase):
    def test_exact_failure_is_required(self):
        self.assertTrue(checks.expected_failure(1, 'ASSERTION FAILED: NO_OVERLAP\n', 'NO_OVERLAP'))

    def test_missing_output_wrong_code_and_wrong_assertion_fail(self):
        for code, output in [(0, 'ASSERTION FAILED: NO_OVERLAP'), (1, ''),
                             (2, 'ASSERTION FAILED: NO_OVERLAP'),
                             (-11, 'ASSERTION FAILED: NO_OVERLAP'),
                             (1, 'ASSERTION FAILED: FIXED_RATE_NO_DRIFT'),
                             (1, 'ASSERTION FAILED: NO_OVERLAP_EXTRA')]:
            with self.subTest(code=code, output=output):
                self.assertFalse(checks.expected_failure(code, output, 'NO_OVERLAP'))


if __name__ == '__main__':
    unittest.main()
