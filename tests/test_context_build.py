import importlib.util
import pathlib
import unittest

SPEC = importlib.util.spec_from_file_location('context_build', pathlib.Path(__file__).parents[1] / 'scripts/context_build.py')
builder = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(builder)


class ContextBuildTests(unittest.TestCase):
    def test_context_results_reconcile_completed_tasks_and_transfers(self):
        data = dict(format='context-demo-v1', backend='test', tasks=16, completed=16,
                    yields=16000, resume_calls=16016, elapsed_us=32032,
                    requested_stack_bytes_per_task=262144, carrier_threads=1)
        result = builder.validate_demo(data)
        self.assertEqual(result['context_transfers'], 32032)
        self.assertEqual(result['mean_us_per_resume_roundtrip'], 2)
        self.assertEqual(result['qualification'], 'descriptive')

    def test_incomplete_or_inconsistent_context_demo_fails(self):
        data = dict(format='context-demo-v1', backend='test', tasks=16, completed=16,
                    yields=16000, resume_calls=16016, elapsed_us=1,
                    requested_stack_bytes_per_task=262144, carrier_threads=1)
        for changed in [dict(completed=15), dict(resume_calls=16015),
                        dict(carrier_threads=16), dict(elapsed_us=-1), dict(tasks=True),
                        dict(format='wrong'), dict(backend='')]:
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                builder.validate_demo(dict(data, **changed))
        with self.assertRaises(ValueError):
            builder.validate_demo({})

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
