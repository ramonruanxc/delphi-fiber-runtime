import importlib.util
import pathlib
import tempfile
import unittest
import zipfile

SPEC = importlib.util.spec_from_file_location('package', pathlib.Path(__file__).parents[1] / 'scripts/package.py')
package = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(package)


class PackageTests(unittest.TestCase):
    def test_archive_preserves_source_paths_and_excludes_local_files(self):
        with tempfile.TemporaryDirectory(prefix='consumer with spaces ') as temp:
            root = pathlib.Path(temp)
            (root / 'src').mkdir()
            (root / 'src/core.pas').write_text('unit core;', encoding='utf-8')
            (root / '.env').write_text('LOCAL_ONLY', encoding='utf-8')
            archive = root / 'source.zip'
            package.create_source(root, archive, ['src/core.pas'])
            with zipfile.ZipFile(archive) as zipped:
                self.assertEqual(zipped.namelist(), ['src/core.pas'])
                self.assertEqual(zipped.read('src/core.pas'), b'unit core;')

    def test_rejects_paths_outside_root(self):
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            for bad in ('../secret', '/absolute', 'C:/absolute', 'src/../../secret', 'src\\..\\..\\secret'):
                with self.subTest(path=bad), self.assertRaises(ValueError):
                    package.create_source(root, root / 'source.zip', [bad])


if __name__ == '__main__':
    unittest.main()
