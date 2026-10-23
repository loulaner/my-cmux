#!/usr/bin/env python3
"""Portable contract checks; not a physical-device or signing acceptance."""
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import unittest
import xml.etree.ElementTree as ET

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
WRAPPER = ROOT / 'ios/scripts/build-local-direct-device.sh'


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class DirectDeviceTests(unittest.TestCase):
    def test_cli_rejects_missing_identity_and_wrong_tag_without_tools(self):
        self.assertTrue(WRAPPER.exists(), 'supported build-only entry is missing')
        for args in [[], ['--tag', 'wrong'], ['--tag', 'wrong', '--device-id', 'dummy', '--team', 'TESTTEAM00'], ['--tag', 'local-terminal-device'],
                     ['--tag', 'local-terminal-device', '--device-id', 'dummy']]:
            result = subprocess.run(['/bin/bash', str(WRAPPER), *args], capture_output=True,
                                    env={'PATH': '/usr/bin:/bin'}, text=True)
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)

    def test_empty_entitlements(self):
        path = ROOT / 'ios/Config/cmux-local-direct.entitlements'
        self.assertTrue(path.exists())
        self.assertEqual(plistlib.loads(path.read_bytes()), {})

    def test_metadata_is_direct_only(self):
        path = ROOT / 'ios/Config/LocalDirectInfo.plist'
        self.assertTrue(path.exists())
        info = plistlib.loads(path.read_bytes())
        self.assertEqual(info['CMUXDevTag'], '$(CMUX_DEV_TAG)')
        for key in ['CFBundleURLTypes', 'NSBonjourServices', 'NSCameraUsageDescription',
                    'NSPhotoLibraryUsageDescription', 'NSMicrophoneUsageDescription',
                    'NSSpeechRecognitionUsageDescription', 'CMUXKeychainAccessGroup', 'UIBackgroundModes']:
            self.assertNotIn(key, info)
        self.assertEqual({k for k in info if k.startswith('CMUX')}, {'CMUXDevTag', 'CMUXGitSHA'})
        self.assertIn('NSLocalNetworkUsageDescription', info)
        self.assertIn('UISupportedInterfaceOrientations~ipad', info)

    def test_target_reuses_real_entry_without_extension_or_fixture(self):
        parser = load('pbx_parser', ROOT / 'scripts/check-pbxproj-group-membership.py')
        project = parser.parse((ROOT / 'ios/cmux-ios.xcodeproj/project.pbxproj').read_text())
        objects = project['objects']
        targets = {v.get('name'): (k, v) for k, v in objects.items() if v.get('isa') == 'PBXNativeTarget'}
        self.assertIn('cmux-local-direct', targets)
        key, target = targets['cmux-local-direct']
        self.assertEqual(target['dependencies'], [])
        phases = [objects[p] for p in target['buildPhases']]
        self.assertEqual({p['isa'] for p in phases}, {'PBXSourcesBuildPhase', 'PBXFrameworksBuildPhase', 'PBXResourcesBuildPhase'})
        sources = [objects[objects[f]['fileRef']]['path'] for p in phases if p['isa'] == 'PBXSourcesBuildPhase' for f in p['files']]
        self.assertEqual(sources, ['cmuxApp.swift'])
        configs = objects[target['buildConfigurationList']]['buildConfigurations']
        self.assertEqual([objects[c]['name'] for c in configs], ['Debug'])
        scheme = ET.parse(ROOT / 'ios/cmux-ios.xcodeproj/xcshareddata/xcschemes/cmux-local-direct.xcscheme')
        self.assertTrue(all(ref.attrib['BlueprintIdentifier'] == key for ref in scheme.findall('.//BuildableReference')))
        self.assertFalse(parser.orphans(project))

    def test_info_localizations_cover_all_supported_languages(self):
        path = ROOT / 'ios/Config/LocalDirect/InfoPlist.xcstrings'
        self.assertTrue(path.exists())
        strings = json.loads(path.read_text())['strings']
        self.assertEqual(set(strings), {'CFBundleDisplayName', 'NSLocalNetworkUsageDescription'})
        for item in strings.values():
            self.assertEqual(set(item['localizations']), {'en','ja','de','fr','es','ar','zh-Hans','zh-Hant','ko'})
            self.assertTrue(all(v['stringUnit']['value'] for v in item['localizations'].values()))

    def test_builder_has_no_install_launch_or_queue_commands(self):
        path = ROOT / 'ios/scripts/local_direct_device_build.py'
        self.assertTrue(path.exists())
        code = path.read_text()
        for forbidden in ['device install', 'process launch', 'iphone-install-queue',
                          'CMUX_ALLOW_UNAUTHENTICATED_INSTALL', 'allowProvisioningDeviceRegistration',
                          'mobile-dev-launch.sh', 'cmuxterm-dev.env']:
            self.assertNotIn(forbidden, code)
        self.assertIn('BUILT_NOT_INSTALLED', code)


class BuildValidationTests(unittest.TestCase):
    def setUp(self):
        self.builder = load('direct_builder', ROOT / 'ios/scripts/local_direct_device_build.py')

    def test_device_selection_excludes_simulators_and_rejects_wrong_target(self):
        physical = {'identifier': 'physical', 'visibilityClass': 'default',
                    'hardwareProperties': {'deviceType': 'iPad', 'productType': 'iPad14,1', 'udid': 'udid'},
                    'deviceProperties': {'bootState': 'booted'},
                    'connectionProperties': {'pairingState': 'paired', 'transportType': 'wired'}}
        simulator = dict(physical, identifier='sim', visibilityClass='simulators')
        document = {'result': {'devices': [physical, simulator]}}
        self.assertIs(self.builder.select_device(document, 'physical'), physical)
        with self.assertRaises(ValueError): self.builder.select_device(document, 'sim')
        document['result']['devices'].append(dict(physical, identifier='other'))
        with self.assertRaises(ValueError): self.builder.select_device(document, 'physical')

    def test_signed_entitlements_reject_shared_groups_and_wrong_device(self):
        import datetime
        import hashlib
        team = 'TESTTEAM00'
        certificate = b'test certificate, not real signing material'
        app_id = team + '.' + self.builder.BUNDLE
        ent = {'application-identifier': app_id, 'com.apple.developer.team-identifier': team, 'get-task-allow': True}
        profile = {'TeamIdentifier': [team], 'ApplicationIdentifierPrefix': [team], 'ProvisionedDevices': ['ipad'],
                   'ExpirationDate': datetime.datetime.now() + datetime.timedelta(days=1),
                   'Entitlements': {'application-identifier': app_id, 'get-task-allow': True},
                   'DeveloperCertificates': [certificate]}
        digest = hashlib.sha256(certificate).hexdigest().upper()
        self.builder.validate_signed_metadata(ent, profile, team, 'ipad', digest)
        for extra in ['keychain-access-groups', 'aps-environment', 'com.apple.security.application-groups',
                      'com.apple.developer.networking.networkextension', 'com.apple.developer.applesignin']:
            with self.subTest(extra=extra), self.assertRaises(ValueError):
                self.builder.validate_signed_metadata(dict(ent, **{extra: []}), profile, team, 'ipad', digest)
        with self.assertRaises(ValueError):
            self.builder.validate_signed_metadata(ent, profile, team, 'other-ipad', digest)
        with self.assertRaises(ValueError):
            self.builder.validate_signed_metadata(ent, profile, 'OTHERTEAM0', 'ipad', digest)
        with self.assertRaises(ValueError):
            self.builder.validate_signed_metadata(ent, dict(profile, ExpirationDate=datetime.datetime(2000,1,1)), team, 'ipad', digest)

    def test_artifact_metadata_rejects_old_cloud_or_wrong_identity(self):
        valid = {'CFBundleIdentifier': self.builder.BUNDLE, 'CMUXDevTag': self.builder.TAG, 'CMUXGitSHA': 'test'}
        self.builder.validate_metadata(valid)
        for addition in [{'CFBundleIdentifier': 'com.loulaner.mycmux.ios'}, {'CMUXApiBaseURL': 'https://example.invalid'},
                         {'NSCameraUsageDescription': ''}, {'CFBundleURLTypes': []}]:
            with self.assertRaises(ValueError): self.builder.validate_metadata(dict(valid, **addition))


if __name__ == '__main__':
    unittest.main()
