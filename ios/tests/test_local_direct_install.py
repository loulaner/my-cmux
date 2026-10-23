import argparse
import importlib.util
import json
import os
import tempfile
import pathlib
import subprocess
import sys
import unittest
from unittest import mock

sys.dont_write_bytecode = True
ROOT = pathlib.Path(__file__).resolve().parents[2]


def load():
    sys.path.insert(0, str(ROOT / 'ios/scripts'))
    spec = importlib.util.spec_from_file_location('direct_install', ROOT / 'ios/scripts/local_direct_device_install.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class DirectInstallTests(unittest.TestCase):
    def test_old_options_rejected_before_side_effects(self):
        for option in ['--no-launch', '--no-setup', '--prod-auth', '--queue', '--auth-profile', '--no-attach']:
            result = subprocess.run(['bash', str(ROOT / 'ios/scripts/reload.sh'), '--connection-mode', 'local-direct',
                                     option], capture_output=True)
            self.assertEqual(result.returncode, 2, result.stderr)

    def test_locked_is_pending_and_never_delivery(self):
        module = load()
        for payload in [{}, {'passcodeRequired': True}, {'passcodeRequired': False, 'unlockedSinceBoot': False}]:
            with self.assertRaises(module.Pending): module.require_unlocked({'result': payload})
        module.require_unlocked({'result': {'passcodeRequired': False, 'unlockedSinceBoot': True}})

    def test_pending_is_nonzero(self):
        module = load()
        self.assertEqual(module.PENDING_EXIT, 75)
        self.assertEqual(module.PENDING_STATE, 'INSTALLED_PENDING_PAIRING')

    def test_old_product_receipts_are_rejected_without_device_or_socket_access(self):
        module = load()
        old = {'bundle_identifier': 'com.cmuxterm.app.debug.local.terminal.device',
               'socket_path': '/tmp/cmux-debug-local-terminal-device.sock',
               'app_executable_path': '/synthetic/mac', 'app_bundle_path': '/synthetic'}
        with self.assertRaises(ValueError):
            module.validate_mac_identity(old, '/synthetic/mac', '/synthetic')
        with self.assertRaises(ValueError):
            sys.modules['local_direct_device_build'].validate_metadata({'CFBundleIdentifier': 'dev.cmux.ios.local-terminal-device',
                                      'CMUXDevTag': 'local-terminal-device', 'CMUXGitSHA': 'synthetic'})

    def test_mac_identity_mismatch_rejected(self):
        module = load()
        valid = {'bundle_identifier': module.MAC_BUNDLE, 'socket_path': module.MAC_SOCKET,
                 'app_executable_path': '/task/mac', 'app_bundle_path': '/task'}
        module.validate_mac_identity(valid, '/task/mac', '/task')
        for key in valid:
            with self.assertRaises(ValueError):
                module.validate_mac_identity(dict(valid, **{key: 'wrong'}), '/task/mac', '/task')


class DeliveryFlowTests(unittest.TestCase):
    def setUp(self):
        self.module = load()
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = pathlib.Path(self.directory.name).resolve()
        self.app = self.root / 'artifact'
        self.app.mkdir()
        self.receipt = self.root / 'build.json'
        self.receipt.write_text(json.dumps({'app_path': str(self.app), 'signed': True}))
        self.receipt.chmod(0o600)
        self.device = {'identifier': 'ipad', 'visibilityClass': 'default',
                       'hardwareProperties': {'deviceType': 'iPad', 'productType': 'iPad14,1', 'udid': 'udid'},
                       'deviceProperties': {'bootState': 'booted'},
                       'connectionProperties': {'pairingState': 'paired', 'transportType': 'wired'}}
        self.operation = object.__new__(self.module.Install)
        self.operation.args = argparse.Namespace(device_id='ipad', team='TESTTEAM00',
                                                 build_receipt=self.receipt, mac_receipt=self.root / 'mac.json')
        self.operation.logs = self.root
        self.operation.environment = {}
        self.operation.identity = mock.Mock(return_value='certificate')
        self.operation.validate_artifact = mock.Mock()
        self.operation.run = mock.Mock()
        self.operation.selected_apps = mock.Mock(side_effect=[[], [], [{'bundleIdentifier': self.module.BUNDLE}]])
        self.operation.device_json = mock.Mock(side_effect=lambda name, command:
            {'result': {'devices': [self.device]}} if name == 'devices' else
            {'result': {'passcodeRequired': False, 'unlockedSinceBoot': True}})
        patch = mock.patch.object(self.module, 'verify_mac', return_value={'state_directory': str(self.root)})
        self.mac = patch.start()
        self.addCleanup(patch.stop)

    def test_successful_install_is_pending_not_success(self):
        self.assertEqual(self.operation.deliver(), 75)
        self.operation.validate_artifact.assert_called_once_with(self.app, self.device, 'certificate', signed=True)
        self.assertEqual([call.args[0] for call in self.operation.run.call_args_list], ['install', 'launch'])
        receipt = json.loads((self.root / 'receipt.json').read_text())
        self.assertEqual(receipt['state'], 'INSTALLED_PENDING_PAIRING')
        self.assertFalse(receipt['delivered'])
        self.assertFalse(receipt['queued'])

    def test_signed_receipt_does_not_bypass_artifact_checks(self):
        self.operation.validate_artifact.side_effect = ValueError('profile wrong device')
        with self.assertRaises(RuntimeError): self.operation.deliver()
        self.operation.run.assert_not_called()

    def test_locked_before_install_does_not_mutate(self):
        self.operation.device_json.side_effect = lambda name, command: (
            {'result': {'devices': [self.device]}} if name == 'devices' else
            {'result': {'passcodeRequired': True, 'unlockedSinceBoot': True}})
        with self.assertRaises(self.module.Pending): self.operation.deliver()
        self.operation.run.assert_not_called()

    def test_wrong_device_does_not_mutate(self):
        self.operation.args.device_id = 'other'
        with self.assertRaises(ValueError): self.operation.deliver()
        self.operation.run.assert_not_called()

    def test_wrong_mac_does_not_even_query_device(self):
        self.mac.side_effect = ValueError('wrong Mac')
        with self.assertRaises(ValueError): self.operation.deliver()
        self.operation.device_json.assert_not_called()
        self.operation.run.assert_not_called()

    def test_unknown_same_id_is_not_killed_or_overwritten(self):
        self.operation.selected_apps.side_effect = None
        self.operation.selected_apps.return_value = [{'bundleIdentifier': self.module.BUNDLE}]
        with self.assertRaises(ValueError): self.operation.deliver()
        self.operation.run.assert_not_called()

    def test_mac_changes_between_checks_never_installs(self):
        self.mac.side_effect = [{'state_directory': str(self.root)}, ValueError('reused PID')]
        with self.assertRaises(ValueError): self.operation.deliver()
        self.operation.run.assert_not_called()

    def test_offline_does_not_queue_or_mutate(self):
        self.operation.device_json.side_effect = None
        self.operation.device_json.return_value = {'result': {'devices': []}}
        with self.assertRaises(self.module.Pending): self.operation.deliver()
        self.operation.run.assert_not_called()

    def test_task_owned_existing_app_uses_precise_termination(self):
        apps = [{'bundleIdentifier': self.module.BUNDLE, 'url': 'task-owned-container'}]
        owner = self.root / 'ipad-install-owned.json'
        owner.write_text(json.dumps({'device': 'udid', 'apps': apps}))
        owner.chmod(0o600)
        self.operation.selected_apps.side_effect = None
        self.operation.selected_apps.return_value = apps
        self.assertEqual(self.operation.deliver(), 75)
        calls = self.operation.run.call_args_list
        self.assertEqual([call.args[0] for call in calls], ['terminate-owned', 'install', 'launch'])
        self.assertEqual(calls[0].args[1][-4:], ['--device-id', 'ipad', '--bundle-id', self.module.BUNDLE])

    def test_all_old_options_rejected_with_otherwise_valid_arguments(self):
        arguments = ['--connection-mode', 'local-direct', '--tag', self.module.TAG, '--device-only',
                     '--device-id', 'ipad', '--team', 'TESTTEAM00', '--build-receipt', str(self.receipt),
                     '--mac-receipt', str(self.root / 'mac.json')]
        for flag in ['--no-launch', '--no-setup', '--prod-auth', '--no-sign-in', '--no-attach', '--queue']:
            with self.subTest(flag=flag), self.assertRaises(SystemExit) as raised:
                self.module.parse_args(arguments + [flag])
            self.assertEqual(raised.exception.code, 2)
        for index, wrong in [(3, 'another-tag'), (8, 'bad-team')]:
            changed = arguments.copy()
            changed[index] = wrong
            with self.assertRaises(SystemExit): self.module.parse_args(changed)

    def test_install_child_environment_excludes_cloud_credentials(self):
        with mock.patch.dict(os.environ, {'CMUX_UITEST_STACK_PASSWORD': 'test-only', 'CMUX_ATTACH_TOKEN': 'test-only'}), \
             mock.patch.object(self.module.Build, '__init__', return_value=None) as constructor:
            self.module.Install(self.operation.args)
        environment = constructor.call_args.kwargs['environment']
        self.assertNotIn('CMUX_UITEST_STACK_PASSWORD', environment)
        self.assertNotIn('CMUX_ATTACH_TOKEN', environment)


class PrivateSocketPasswordTests(unittest.TestCase):
    def setUp(self):
        self.mac = load().mac_verifier
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = pathlib.Path(self.directory.name).resolve()
        current = self.root
        for part in ['home', '.local', 'state', 'my-cmux', 'dev-local-terminal-device']:
            current /= part
            current.mkdir(mode=0o700)
        self.path = current / 'socket-control-password'

    def test_generation_is_private_independent_and_exclusive(self):
        import base64
        resume = base64.b64encode(os.urandom(32))
        self.mac.create_isolated_socket_password(self.root)
        self.mac.require_isolated_socket_password(self.root)
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.path.stat().st_uid, os.getuid())
        self.assertEqual(len(base64.b64decode(self.path.read_bytes())), 32)
        self.assertNotEqual(self.path.read_bytes(), resume)
        with self.assertRaises(FileExistsError): self.mac.create_isolated_socket_password(self.root)

    def test_missing_empty_permissions_and_symlink_fail_closed(self):
        with self.assertRaises(OSError): self.mac.require_isolated_socket_password(self.root)
        self.mac.create_isolated_socket_password(self.root)
        self.path.write_bytes(b'')
        with self.assertRaises(ValueError): self.mac.require_isolated_socket_password(self.root)
        self.path.write_bytes(b'A' * 44)
        self.path.chmod(0o644)
        with self.assertRaises(ValueError): self.mac.require_isolated_socket_password(self.root)
        self.path.unlink()
        other = self.root / 'other'
        other.write_bytes(b'A' * 44)
        self.path.symlink_to(other)
        with self.assertRaises(OSError): self.mac.require_isolated_socket_password(self.root)

    def test_symlink_directory_is_rejected(self):
        self.path.parent.rmdir()
        replacement = self.root / 'replacement'
        replacement.mkdir(mode=0o700)
        self.path.parent.symlink_to(replacement, target_is_directory=True)
        with self.assertRaises(ValueError): self.mac.create_isolated_socket_password(self.root)

    def test_bad_private_password_never_enters_cli(self):
        receipt = self.root / 'launch-receipt.json'
        receipt.write_text(json.dumps({'app_path': str(self.root / 'app'), 'pid': 42}))
        receipt.chmod(0o600)
        for kind in ['missing', 'empty', 'permissions', 'symlink']:
            if self.path.exists() or self.path.is_symlink(): self.path.unlink()
            if kind == 'empty':
                self.path.write_bytes(b'')
                self.path.chmod(0o600)
            elif kind == 'permissions':
                self.path.write_bytes(b'A' * 44)
                self.path.chmod(0o644)
            elif kind == 'symlink':
                self.path.symlink_to(self.root / 'absent')
            with mock.patch.object(self.mac, 'validate_bundle', return_value=(self.root / 'app', self.root / 'app/cmux')), \
                 mock.patch.object(self.mac, 'process_path', return_value=str(self.root / 'app/cmux')), \
                 mock.patch.object(self.mac.subprocess, 'check_output') as command:
                with self.assertRaises((ValueError, OSError)): self.mac.terminal_identify(self.root)
                command.assert_not_called()

    def test_process_start_is_locale_independent(self):
        with mock.patch.object(self.mac.subprocess, 'check_output', return_value=b'fixed start\n') as command:
            self.assertEqual(self.mac.process_start(42), 'fixed start')
            self.assertEqual(command.call_args.kwargs['env']['LC_ALL'], 'C')

    def test_cli_file_resolution_has_no_legacy_keychain_fallback(self):
        source = (ROOT / 'CLI/cmux.swift').read_text()
        body = source.split('enum SocketPasswordResolver {', 1)[1].split('private static func normalized', 1)[0]
        self.assertIn('if let filePassword = loadFromFile(socketPath: socketPath) {\n            return filePassword\n        }', body)
        self.assertNotIn('return loadFromKeychain', body)


if __name__ == '__main__':
    unittest.main()
