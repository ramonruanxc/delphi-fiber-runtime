import pathlib
import subprocess
import sys
import tempfile
import unittest
sys.path.insert(0, str(pathlib.Path(__file__).parents[1] / 'scripts'))
from provenance import dirty


class ProvenanceTests(unittest.TestCase):
    def test_untracked_compiler_input_invalidates_clean_tree(self):
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            self.assertFalse(dirty(root))
            (root / 'ShadowUnit.pas').write_text('unit ShadowUnit;', encoding='utf-8')
            self.assertTrue(dirty(root))
