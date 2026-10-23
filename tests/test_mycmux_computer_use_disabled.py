"""MyCMUX's disabled helper never attaches, builds, or edits global skill links."""
import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load(filename):
    spec = importlib.util.spec_from_file_location(filename[:-3], ROOT / 'tests' / filename)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class UnavailableComputerUseTests(unittest.TestCase):
    def test_builder_is_unsupported_without_tools_or_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / 'helper'
            result = subprocess.run(['/bin/bash', str(ROOT / 'scripts/build-cmux-cua.sh'),
                                     '--output', str(output)], capture_output=True,
                                    env={'PATH': temporary, 'HOME': temporary})
            self.assertEqual(result.returncode, 64)
            self.assertFalse(output.exists())
            self.assertEqual(list(Path(temporary).iterdir()), [])

    def test_codex_does_not_attach_even_with_client_and_credentials(self):
        module = load('test_codex_wrapper_computer_use_mcp.py')
        code, args, stderr, skill = module.run_wrapper(['hello'], override_driver=True,
                                                       install_global_skill=True)
        self.assertEqual(code, 0, stderr)
        self.assertIsNone(module.command_config(args))
        self.assertFalse(skill['exists'])

    def test_claude_does_not_attach_even_with_client_and_credentials(self):
        module = load('test_claude_wrapper_hooks.py')
        result = module.run_wrapper(socket_state='live', argv=['hello'],
                                    setup_sandbox=module.computer_use_sandbox())
        self.assertEqual(result[0], 0, result[3])
        self.assertIsNone(module.extract_injected_mcp_config(result[1]))


if __name__ == '__main__':
    unittest.main()
