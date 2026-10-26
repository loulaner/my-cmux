import argparse
import importlib.util
import json
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'ios/scripts'))


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'ios/scripts' / filename)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class CompileOnlyTests(unittest.TestCase):
    def test_all_schemes_isolate_environment_and_disable_updates(self):
        module = load('compile_only', 'build-compile-only.py')
        parent = {
            'PATH': '/synthetic/bin', 'DEVELOPER_DIR': '/synthetic/Xcode', 'LANG': 'en_US.UTF-8',
            'HOME': '/synthetic/user', 'CFFIXED_USER_HOME': '/synthetic/user', 'TMPDIR': '/synthetic/tmp',
            'XDG_CONFIG_HOME': '/synthetic/config', 'XDG_CACHE_HOME': '/synthetic/cache',
            'XDG_DATA_HOME': '/synthetic/data', 'XDG_STATE_HOME': '/synthetic/state',
            'SWIFTPM_MODULECACHE_OVERRIDE': '/synthetic/modulecache',
            'CLANG_MODULE_CACHE_PATH': '/synthetic/modulecache', 'SWIFT_MODULE_CACHE_PATH': '/synthetic/modulecache',
            'GIT_ALLOW_PROTOCOL': 'all', 'GIT_NO_LAZY_FETCH': '0', 'GIT_TERMINAL_PROMPT': '1',
            'GIT_CONFIG_COUNT': '1', 'GIT_CONFIG_KEY_0': 'url.fake.insteadOf', 'GIT_CONFIG_VALUE_0': 'fake',
            'GIT_CONFIG_GLOBAL': '/synthetic/gitconfig', 'GIT_CONFIG_SYSTEM': '/synthetic/system',
            'CMUX_SECRET': 'fake-secret', 'CMUX_DEV_BACKEND_MODE': 'remote',
            'SSH_AUTH_SOCK': '/synthetic/ssh', 'SSH_ASKPASS': '/synthetic/askpass',
            'XCODE_XCCONFIG_FILE': '/synthetic/override', 'DEVELOPMENT_TEAM': 'FAKE', 'UNKNOWN': 'fake',
        }
        for scheme in module.SCHEMES:
            with self.subTest(scheme=scheme), tempfile.TemporaryDirectory() as temporary:
                output = Path(temporary) / 'run'
                calls = []

                def run(argv, **kwargs):
                    calls.append((argv, kwargs['env']))
                    return subprocess.CompletedProcess(argv, 65)

                with mock.patch.dict(module.os.environ, parent, clear=True):
                    self.assertEqual(module.execute(scheme, output, runner=run), 65)
                self.assertEqual(len(calls), 1)
                argv, child = calls[0]
                private = output / 'Environment'
                expected = {key: parent[key] for key in ['PATH', 'DEVELOPER_DIR', 'LANG']}
                directories = {
                    'HOME': 'home', 'CFFIXED_USER_HOME': 'home', 'TMPDIR': 'tmp',
                    'XDG_CONFIG_HOME': 'config', 'XDG_CACHE_HOME': 'cache',
                    'XDG_DATA_HOME': 'data', 'XDG_STATE_HOME': 'state',
                    'SWIFTPM_MODULECACHE_OVERRIDE': 'modulecache',
                    'CLANG_MODULE_CACHE_PATH': 'modulecache', 'SWIFT_MODULE_CACHE_PATH': 'modulecache',
                }
                for key, name in directories.items():
                    expected[key] = str(private / name) + ('/' if key == 'TMPDIR' else '')
                expected.update(CMUX_DEV_BACKEND_MODE='local', GIT_ALLOW_PROTOCOL='',
                                GIT_TERMINAL_PROMPT='0', GIT_NO_LAZY_FETCH='1',
                                GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null')
                self.assertEqual(child, expected)
                for name in set(directories.values()):
                    self.assertTrue((private / name).is_dir())
                    self.assertEqual((private / name).stat().st_mode & 0o777, 0o700)
                self.assertIn('-skipPackageUpdates', argv)
                self.assertEqual(argv[argv.index('-onlyUsePackageVersionsFromResolvedFile') + 1], '-skipPackageUpdates')
                for key in ['CLANG_MODULE_CACHE_PATH', 'SWIFT_MODULE_CACHE_PATH']:
                    self.assertIn(key + '=' + str(private / 'modulecache'), argv)
                self.assertEqual((output / 'build.exit').read_text(), '65\n')
                self.assertEqual(json.loads((output / 'receipt.json').read_text())['state'], 'NOT_INSTALLABLE')
                with self.assertRaises(FileExistsError):
                    module.execute(scheme, output, runner=run)
                self.assertEqual(len(calls), 1)

    def test_all_schemes_are_unsigned_and_identity_checked(self):
        module = load('compile_only', 'build-compile-only.py')
        for scheme, (configuration, bundle, product) in module.SCHEMES.items():
            with self.subTest(scheme=scheme), tempfile.TemporaryDirectory() as temporary:
                output = Path(temporary) / 'run'
                calls = []

                def run(argv, calls=calls, output=output, configuration=configuration,
                        product=product, bundle=bundle, scheme=scheme, **kwargs):
                    calls.append(argv)
                    self.assertEqual(argv[:2], ['xcodebuild', 'build'])
                    self.assertIn('generic/platform=iOS', argv)
                    for value in ['CODE_SIGNING_ALLOWED=NO', 'CODE_SIGNING_REQUIRED=NO',
                                  'CODE_SIGN_IDENTITY=', 'DEVELOPMENT_TEAM=']:
                        self.assertIn(value, argv)
                    self.assertNotIn('-allowProvisioningUpdates', argv)
                    self.assertNotIn('XCODE_XCCONFIG_FILE', kwargs['env'])
                    app = output / 'DerivedData/Build/Products' / (configuration + '-iphoneos') / (product + '.app')
                    app.mkdir(parents=True)
                    info = {'CFBundleIdentifier': bundle, 'CFBundleExecutable': product}
                    if scheme == 'cmux-local-direct':
                        info.update(CMUXDevTag='local-terminal-device', CMUXGitSHA='fixture')
                    (app / 'Info.plist').write_bytes(plistlib.dumps(info))
                    return subprocess.CompletedProcess(argv, 0)

                self.assertEqual(module.execute(scheme, output, runner=run), 0)
                self.assertEqual(len(calls), 1)
                receipt = json.loads((output / 'receipt.json').read_text())
                self.assertEqual(receipt['mode'], 'compile-only')
                self.assertFalse(receipt['signed'])
                self.assertFalse(receipt['installable'])
                self.assertEqual(receipt['bundle_id'], bundle)
                with self.assertRaises(FileExistsError):
                    module.execute(scheme, output, runner=run)

    def test_all_schemes_reject_extensions_and_removed_metadata(self):
        module = load('compile_only', 'build-compile-only.py')
        for scheme, (configuration, bundle, product) in module.SCHEMES.items():
            for forbidden in ['extension', 'provider', 'push']:
                with self.subTest(scheme=scheme, forbidden=forbidden), tempfile.TemporaryDirectory() as temporary:
                    output = Path(temporary) / 'run'

                    def run(argv, **kwargs):
                        app = output / 'DerivedData/Build/Products' / (configuration + '-iphoneos') / (product + '.app')
                        app.mkdir(parents=True)
                        info = {'CFBundleIdentifier': bundle, 'CFBundleExecutable': product}
                        if scheme == 'cmux-local-direct':
                            info.update(CMUXDevTag='local-terminal-device', CMUXGitSHA='fixture')
                        if forbidden == 'extension':
                            (app / 'PlugIns/Unexpected.appex').mkdir(parents=True)
                        elif forbidden == 'provider':
                            info['CMUXCloudVPNProviderBundleIdentifier'] = 'unexpected'
                        else:
                            info['UIBackgroundModes'] = ['remote-notification']
                        (app / 'Info.plist').write_bytes(plistlib.dumps(info))
                        return subprocess.CompletedProcess(argv, 0)

                    with self.assertRaises(ValueError):
                        module.execute(scheme, output, runner=run)
                    receipt = json.loads((output / 'receipt.json').read_text())
                    self.assertFalse(receipt['installable'])
                    self.assertNotEqual(receipt['state'], 'COMPILED_UNSIGNED_NOT_INSTALLABLE')

    def test_unknown_options_and_schemes_never_execute(self):
        module = load('compile_only', 'build-compile-only.py')
        for extra in [['--team', 'AAAAAAAAAA'], ['--device-id', 'fixture'], ['--', 'test'],
                      ['--configuration', 'Release'], ['--scheme', 'other'], ['--sch', 'cmux-ios']]:
            with mock.patch.object(module, 'execute') as execute, self.assertRaises(SystemExit) as error:
                module.main(['--scheme', 'cmux-ios', '--output', '/unused', *extra])
            self.assertEqual(error.exception.code, 2)
            execute.assert_not_called()

    def test_failure_exit_is_retained_without_install_receipt(self):
        module = load('compile_only', 'build-compile-only.py')
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / 'run'
            self.assertEqual(module.execute('cmux-ios', output,
                runner=lambda argv, **_: subprocess.CompletedProcess(argv, 65)), 65)
            self.assertEqual((output / 'build.exit').read_text(), '65\n')
            self.assertFalse(json.loads((output / 'receipt.json').read_text())['installable'])

    def test_direct_install_rejects_receipt_before_any_access(self):
        module = load('direct_install', 'local_direct_device_install.py')
        with tempfile.TemporaryDirectory() as temporary:
            receipt = Path(temporary) / 'receipt.json'
            receipt.write_text(json.dumps({'mode': 'compile-only'}))
            install = object.__new__(module.Install)
            install.args = argparse.Namespace(build_receipt=receipt, mac_receipt=Path('/never'))
            with mock.patch.object(module, 'private_path', return_value=receipt), \
                 mock.patch.object(module, 'verify_mac', side_effect=AssertionError('no Mac access')):
                with self.assertRaisesRegex(ValueError, 'Compile-only'):
                    install.deliver()

    def test_personal_install_and_renew_reject_receipt_arguments(self):
        for command in [['bash', str(ROOT / 'ios/scripts/install-personal.sh')],
                        [sys.executable, str(ROOT / 'ios/scripts/renew-personal.py')]]:
            result = subprocess.run(command + ['--build-receipt', '/never/compile-only.json'], capture_output=True)
            self.assertEqual(result.returncode, 2, result.stderr)


if __name__ == '__main__':
    unittest.main()
