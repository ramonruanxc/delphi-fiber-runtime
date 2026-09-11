import importlib.util
import pathlib
import tempfile
import unittest
import zipfile

SPEC = importlib.util.spec_from_file_location('package', pathlib.Path(__file__).parents[1] / 'scripts/package.py')
package = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(package)


class PackageTests(unittest.TestCase):
    def test_runtime_binary_requires_its_own_verified_hash(self):
        package.validate_runtime_provenance(dict(runtime_binary_sha256='abc'), 'abc')
        for summary in ({}, dict(runtime_binary_sha256='other')):
            with self.subTest(summary=summary), self.assertRaises(ValueError):
                package.validate_runtime_provenance(summary, 'abc')

    def test_context_binary_requires_its_own_verified_hash(self):
        package.validate_context_provenance(dict(context_binary_sha256='abc'), 'abc')
        for summary in ({}, dict(context_binary_sha256='other')):
            with self.subTest(summary=summary), self.assertRaises(ValueError):
                package.validate_context_provenance(summary, 'abc')

    def test_provenance_rejects_stale_dirty_or_changed_binary(self):
        good = dict(commit='abc', dirty=False, binary_sha256='123', target_cpu='x', target_os='y')
        package.validate_provenance(good, 'abc', False, '123', 'x', 'y')
        for args in [('other', False, '123', 'x', 'y'), ('abc', True, '123', 'x', 'y'),
                     ('abc', False, 'changed', 'x', 'y'), ('abc', False, '123', 'other', 'y')]:
            with self.subTest(args=args), self.assertRaises(ValueError):
                package.validate_provenance(good, *args)
        with self.assertRaises(ValueError):
            package.validate_provenance(dict(good, dirty=True), 'abc', False, '123', 'x', 'y')

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
