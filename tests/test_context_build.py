import importlib.util
import pathlib
import subprocess
import tempfile
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location('context_build', pathlib.Path(__file__).parents[1] / 'scripts/context_build.py')
builder = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(builder)


class ContextBuildTests(unittest.TestCase):
    def test_context_results_reconcile_completed_tasks_and_transfers(self):
        data = dict(format='context-demo-v1', backend='test', tasks=16, completed=16,
                    yields=16000, resume_calls=16016, elapsed_us=32032,
                    requested_stack_bytes_per_task=262144, carrier_threads=1,
                    cancelled=1, cancel_cleanup_count=1)
        result = builder.validate_demo(data)
        self.assertEqual(result['context_transfers'], 32032)
        self.assertEqual(result['mean_us_per_resume_roundtrip'], 2)
        self.assertEqual(result['qualification'], 'descriptive')

    def test_incomplete_or_inconsistent_context_demo_fails(self):
        data = dict(format='context-demo-v1', backend='test', tasks=16, completed=16,
                    yields=16000, resume_calls=16016, elapsed_us=1,
                    requested_stack_bytes_per_task=262144, carrier_threads=1,
                    cancelled=1, cancel_cleanup_count=1)
        for changed in [dict(completed=15), dict(resume_calls=16015),
                        dict(carrier_threads=16), dict(elapsed_us=-1), dict(tasks=True),
                        dict(format='wrong'), dict(backend=''), dict(cancel_cleanup_count=0)]:
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                builder.validate_demo(dict(data, **changed))
        with self.assertRaises(ValueError):
            builder.validate_demo({})

    def test_native_success_without_new_outputs_cannot_reuse_old_test(self):
        for emit_intermediates in (False, True):
            with self.subTest(emit_intermediates=emit_intermediates), tempfile.TemporaryDirectory() as temporary:
                output = pathlib.Path(temporary)
                (output / 'ContextNativeTests').write_text('stale binary')
                def fake_run(command, **kwargs):
                    command = [str(v) for v in command]
                    if emit_intermediates:
                        if command[0] == 'ar':
                            pathlib.Path(command[2]).write_bytes(b'archive')
                        elif '-o' in command and command[-1].endswith('.o'):
                            pathlib.Path(command[-1]).write_bytes(b'object')
                    return subprocess.CompletedProcess(command, 0, 'PASS: native context lifecycle, nested yields, alternation, ownership, churn (fake)\n', '')
                with mock.patch.object(builder.platform, 'system', return_value='Linux'), \
                     mock.patch.object(builder.platform, 'machine', return_value='x86_64'), \
                     mock.patch.object(builder.subprocess, 'run', side_effect=fake_run), \
                     self.assertRaises(RuntimeError):
                    builder.build_native(output)

    def test_native_backend_selection_is_explicit(self):
        self.assertIsNone(builder.assembly_suffix('Windows', 'AMD64'))
        self.assertEqual(builder.assembly_suffix('Linux', 'x86_64'), 'x86_64_sysv_elf_gas.S')
        self.assertEqual(builder.assembly_suffix('Darwin', 'arm64'), 'arm64_aapcs_macho_gas.S')
        self.assertEqual(builder.assembly_suffix('Darwin', 'x86_64'), 'x86_64_sysv_macho_gas.S')

    def test_unknown_target_is_not_silently_substituted(self):
        for system, machine in [('Linux', 'arm64'), ('Windows', 'ARM64'), ('Unknown', 'x86_64')]:
            with self.subTest(system=system, machine=machine), self.assertRaises(ValueError):
                builder.assembly_suffix(system, machine)


if __name__ == '__main__':
    unittest.main()
