import pathlib
import sys
import unittest
sys.path.insert(0, str(pathlib.Path(__file__).parents[1] / 'scripts'))
from compatibility import classify


class CompatibilityTests(unittest.TestCase):
    def test_zero_exit_does_not_validate_unavailable_delphi(self):
        self.assertEqual(classify(0, 'This version of the product does not support command line compiling.', False), 'unavailable')
        self.assertEqual(classify(0, '', False), 'failed')
        self.assertEqual(classify(1, '', True), 'failed')
        self.assertEqual(classify(0, '', True), 'built')
