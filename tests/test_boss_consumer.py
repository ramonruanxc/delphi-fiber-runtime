import pathlib
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'scripts'))
import boss_consumer


class BossProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='boss provenance ')
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.repo = self.root / 'repository'
        self.repo.mkdir()
        self.library = self.repo / 'modules/library'
        self.library.mkdir(parents=True)
        subprocess.run(['git', 'init', str(self.repo)], check=True, capture_output=True)
        (self.repo / 'unit.pas').write_bytes(b'unit example;\n')
        subprocess.run(['git', '-C', str(self.repo), 'add', 'unit.pas'], check=True)
        subprocess.run(['git', '-C', str(self.repo), '-c', 'user.name=Test',
                        '-c', 'user.email=test@example.invalid', 'commit', '-m', 'fixture'],
                       check=True, capture_output=True)
        self.commit = subprocess.check_output(['git', '-C', str(self.repo),
                                              'rev-parse', 'HEAD'], text=True).strip()
        self.cache = self.root / 'boss-cache'
        subprocess.run(['git', 'clone', '--bare', str(self.repo), str(self.cache)],
                       check=True, capture_output=True)
        (self.library / 'unit.pas').write_bytes(b'unit example;\r\n')

    def test_cache_revision_and_installed_bytes_accept_boss_line_endings(self):
        count = boss_consumer.verify_installed(self.library, self.cache, self.commit)
        self.assertEqual(count, 1)

    def test_parent_checkout_cannot_substitute_for_missing_boss_cache(self):
        with self.assertRaises((ValueError, subprocess.CalledProcessError)):
            boss_consumer.verify_installed(self.library, self.root / 'missing-cache', self.commit)

    def test_stale_revision_and_modified_source_are_rejected(self):
        with self.assertRaises(ValueError):
            boss_consumer.verify_installed(self.library, self.cache, '0' * 40)
        (self.library / 'unit.pas').write_bytes(b'unit different;\n')
        with self.assertRaises(ValueError):
            boss_consumer.verify_installed(self.library, self.cache, self.commit)


if __name__ == '__main__':
    unittest.main()
