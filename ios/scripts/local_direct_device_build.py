#!/usr/bin/env python3
"""One-tag, build-only device preparation. Private logs; no delivery side effects."""
import argparse
import base64
import datetime
import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TAG = 'local-terminal-device'
BUNDLE = 'dev.cmux.ios.' + TAG
TARGET = 'cmux-local-direct'
SYSTEM_ENTITLEMENTS = {'application-identifier', 'com.apple.developer.team-identifier', 'get-task-allow'}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def decode_json(data):
    try:
        return json.loads(data)
    except json.JSONDecodeError as error:
        raise ValueError('Invalid device/build metadata JSON') from error


def select_device(document, identifier):
    devices = document.get('result', {}).get('devices', [])
    candidates = [d for d in devices if d.get('hardwareProperties', {}).get('deviceType') == 'iPad'
                  and d.get('connectionProperties', {}).get('pairingState') == 'paired'
                  and d.get('visibilityClass') != 'simulators'
                  and d.get('connectionProperties', {}).get('transportType') != 'sameMachine'
                  and d.get('deviceProperties', {}).get('bootState') == 'booted']
    require(len(candidates) == 1, 'Expected exactly one paired iPad; refusing ambiguous target')
    device = candidates[0]
    require(identifier in (device.get('identifier'), device.get('hardwareProperties', {}).get('udid')),
            'Explicit device does not match the paired iPad')
    require(device.get('hardwareProperties', {}).get('productType') == 'iPad14,1', 'Unexpected iPad model')
    return device


def validate_settings(settings, team, signed):
    expected = {'PRODUCT_BUNDLE_IDENTIFIER': BUNDLE, 'CMUX_HOST_BUNDLE_IDENTIFIER': BUNDLE,
                'CMUX_DEV_TAG': TAG, 'PRODUCT_NAME': TARGET, 'DEVELOPMENT_TEAM': team,
                'CODE_SIGN_ENTITLEMENTS': 'Config/cmux-local-direct.entitlements',
                'INFOPLIST_FILE': 'Config/LocalDirectInfo.plist', 'CONFIGURATION': 'Debug',
                'SWIFT_ACTIVE_COMPILATION_CONDITIONS': 'DEBUG', 'CODE_SIGN_STYLE': 'Automatic',
                'CODE_SIGN_IDENTITY': 'Apple Development', 'CODE_SIGNING_ALLOWED': 'YES' if signed else 'NO'}
    for key, value in expected.items():
        require(settings.get(key, '').strip() == value, f'Unexpected effective build setting: {key}')
    for key in ['CMUX_NOTIFICATION_SERVICE_BUNDLE_IDENTIFIER', 'CMUX_CLOUD_VPN_BUNDLE_IDENTIFIER',
                'CMUX_NOTIFICATION_SERVICE_CODE_SIGN_ENTITLEMENTS', 'CMUX_CLOUD_VPN_CODE_SIGN_ENTITLEMENTS',
                'CMUX_IOS_URL_SCHEME', 'INFOPLIST_KEY_NSCameraUsageDescription']:
        require(not settings.get(key), f'Forbidden inherited selector: {key}')
    require('CMUX_LOCAL_TERMINAL_ACCEPTANCE' not in settings.get('OTHER_SWIFT_FLAGS', ''), 'Fixture flag present')


def validate_metadata(info):
    require(info.get('CFBundleIdentifier') == BUNDLE and info.get('CMUXDevTag') == TAG, 'Artifact identity mismatch')
    require({k for k in info if k.startswith('CMUX')} == {'CMUXDevTag', 'CMUXGitSHA'}, 'Unexpected app configuration keys')
    forbidden = ['CFBundleURLTypes', 'NSBonjourServices', 'NSCameraUsageDescription', 'NSPhotoLibraryUsageDescription',
                 'NSMicrophoneUsageDescription', 'NSSpeechRecognitionUsageDescription', 'UIBackgroundModes']
    require(not any(k in info for k in forbidden), 'Forbidden capability metadata in artifact')


def validate_signed_metadata(entitlements, profile, team, udid, certificate_hash):
    require(set(entitlements).issubset(SYSTEM_ENTITLEMENTS), 'Artifact claims non-system entitlements')
    require(entitlements.get('com.apple.developer.team-identifier') == team, 'Signed team mismatch')
    require(profile.get('TeamIdentifier') == [team], 'Profile team mismatch')
    require(udid in profile.get('ProvisionedDevices', []), 'Selected iPad not provisioned')
    require(profile.get('ExpirationDate', datetime.datetime.min) > datetime.datetime.now(datetime.UTC).replace(tzinfo=None),
            'Expired profile')
    pe = profile.get('Entitlements', {})
    prefix = profile.get('ApplicationIdentifierPrefix', [])
    require(len(prefix) == 1, 'Ambiguous application prefix')
    app_id = prefix[0] + '.' + BUNDLE
    require(entitlements.get('application-identifier') == app_id, 'Signed application identifier mismatch')
    require(pe.get('application-identifier') in (app_id, prefix[0] + '.*'), 'Profile does not authorize app')
    require(all(isinstance(value, bool) and value for value in
                [pe.get('get-task-allow'), entitlements.get('get-task-allow')]), 'Not a development artifact')
    require(certificate_hash in {hashlib.sha256(c).hexdigest().upper() for c in profile.get('DeveloperCertificates', [])},
            'Profile does not contain selected development certificate')


class Build:
    def __init__(self, args, environment=None, purpose="build"):
        self.args = args
        self.logs = Path(tempfile.mkdtemp(prefix=f'cmux-local-direct-{purpose}.', dir='/tmp'))
        self.environment = dict(os.environ if environment is None else environment)
        self.environment.pop('XCODE_XCCONFIG_FILE', None)
        print(f'Private {purpose} receipt: {self.logs}', flush=True)

    def run(self, name, command, check=True, separate_stderr=False):
        # Arguments and device/team identifiers remain private, never echoed to public output.
        (self.logs / (name + '.command.json')).write_text(json.dumps(command))
        with (self.logs / (name + '.log')).open('wb') as log, (self.logs / (name + '.stderr')).open('wb') as error_log:
            result = subprocess.run(command, cwd=ROOT, env=self.environment, stdout=log,
                                    stderr=error_log if separate_stderr else subprocess.STDOUT)
        (self.logs / (name + '.exit')).write_text(str(result.returncode) + '\n')
        if check and result.returncode:
            raise RuntimeError(f'{name} failed (exit {result.returncode}); see private log')
        return (self.logs / (name + '.log')).read_bytes()

    def identity(self):
        identities = self.run('identities', ['security', 'find-identity', '-v', '-p', 'codesigning']).decode()
        matches = re.findall(r'\b([A-F0-9]{40})\s+"Apple Development:[^\n]+"', identities)
        require(len(matches) == 1, 'Expected exactly one valid Apple Development identity')
        pem = self.run('certificates', ['security', 'find-certificate', '-a', '-c', 'Apple Development', '-p']).decode()
        matching_team = False
        selected_hash = None
        for index, certificate in enumerate(re.findall(r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----', pem, re.S)):
            path = self.logs / f'certificate-{index}.pem'
            path.write_text(certificate)
            metadata = self.run(f'certificate-{index}', ['openssl', 'x509', '-in', str(path), '-noout',
                '-fingerprint', '-sha1', '-subject', '-nameopt', 'RFC2253']).decode()
            fingerprint = re.search(r'Fingerprint=([A-Fa-f0-9:]+)', metadata)
            if fingerprint and fingerprint[1].replace(':', '').upper() == matches[0]:
                selected_hash = hashlib.sha256(base64.b64decode(''.join(certificate.splitlines()[1:-1]))).hexdigest().upper()
                matching_team = bool(re.search(r'(?:^|,)OU=' + re.escape(self.args.team) + r'(?:,|$)', metadata, re.M))
        require(matching_team, 'Signing certificate team does not match explicit team')
        return selected_hash

    def validate_artifact(self, app, device, certificate_hash, signed=True):
        info = plistlib.loads((app / 'Info.plist').read_bytes())
        validate_metadata(info)
        require(not list(app.rglob('*.appex')), 'Embedded extension found')
        require(not list(app.rglob('*.xctest')), 'Test bundle found')
        require(info.get('CFBundleExecutable') == TARGET, 'Unexpected app executable')
        binary = (app / TARGET).read_bytes()
        require(b'--local-terminal-ui-acceptance' not in binary and b'LocalTerminalUIAcceptance' not in binary,
                'Test-only injection found')
        if signed:
            self.run('signature-verification', ['codesign', '--verify', '--deep', '--strict', str(app)])
            raw = self.run('signed-entitlements', ['codesign', '-d', '--entitlements', ':-', str(app)])
            begin = raw.find(b'<?xml')
            require(begin >= 0, 'No effective signed entitlements')
            entitlements = plistlib.loads(raw[begin:raw.index(b'</plist>', begin) + len(b'</plist>')])
            profile_raw = self.run('profile', ['security', 'cms', '-D', '-i', str(app / 'embedded.mobileprovision')])
            profile = plistlib.loads(profile_raw)
            validate_signed_metadata(entitlements, profile, self.args.team, device['hardwareProperties']['udid'], certificate_hash)
            # Validate the certificate actually used by CodeSign, not only a profile's allowed certificates.
            prefix = self.logs / 'signed-certificate-'
            self.run('extract-certificate', ['codesign', '-d', '--extract-certificates=' + str(prefix), str(app)])
            require(hashlib.sha256(Path(str(prefix) + '0').read_bytes()).hexdigest().upper() == certificate_hash,
                    'Artifact signed by a different certificate')

    def execute(self):
        devices_file = self.logs / 'devices.json'
        self.run('devices', ['xcrun', 'devicectl', 'list', 'devices', '--json-output', str(devices_file)])
        device = select_device(decode_json(devices_file.read_text()), self.args.device_id)
        apps_file = self.logs / 'installed.json'
        self.run('device-query', ['xcrun', 'devicectl', 'device', 'info', 'apps', '--device', device['identifier'],
                                 '--json-output', str(apps_file)])
        certificate_hash = self.identity()
        self.run('ghosttykit', [str(ROOT / 'scripts/ensure-ghosttykit.sh')])
        signed = self.args.unsigned == '0'
        derived = Path.home() / 'Library/Developer/Xcode/DerivedData/cmux-ios-local-terminal-device-direct'
        sha = self.run('source-sha', ['git', 'rev-parse', '--short', 'HEAD']).decode().strip()
        if self.run('source-dirty', ['git', 'status', '--porcelain']).strip():
            sha += '+'
        command = ['xcodebuild', '-workspace', 'ios/cmux.xcworkspace', '-scheme', TARGET, '-configuration', 'Debug',
                   '-destination', 'generic/platform=iOS', '-derivedDataPath', str(derived),
                   '-clonedSourcePackagesDirPath', str(ROOT / '.build/ios-personal/SourcePackages'),
                   '-disableAutomaticPackageResolution', '-onlyUsePackageVersionsFromResolvedFile',
                   '-jobs', '4', 'DEVELOPMENT_TEAM=' + self.args.team, 'CMUX_GIT_SHA=' + sha,
                   'CODE_SIGNING_ALLOWED=' + ('YES' if signed else 'NO'),
                   'EXCLUDED_SOURCE_FILE_NAMES=Info.plist', 'SWIFT_OPTIMIZATION_LEVEL=-Onone',
                   'SWIFT_COMPILATION_MODE=singlefile']
        settings_raw = self.run('settings', command + ['-showBuildSettings', '-json'], separate_stderr=True)
        settings_json = decode_json(settings_raw)
        selected = [item['buildSettings'] for item in settings_json if item.get('target') == TARGET]
        require(len(selected) == 1, 'Missing dedicated target settings')
        validate_settings(selected[0], self.args.team, signed)
        if signed:
            command.append('-allowProvisioningUpdates')
        self.run('build', command + ['build'])
        app = derived / 'Build/Products/Debug-iphoneos/cmux-local-direct.app'
        self.validate_artifact(app, device, certificate_hash, signed)
        receipt = {'state': 'BUILT_NOT_INSTALLED' if signed else 'BUILT_UNSIGNED_NOT_INSTALLED', 'tag': TAG,
                   'bundle_id': BUNDLE, 'app_path': str(app), 'signed': signed, 'sha': sha}
        (self.logs / 'receipt.json').write_text(json.dumps(receipt, indent=2))
        print(receipt['state'], flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tag', required=True, choices=[TAG])
    parser.add_argument('--device-id', required=True)
    parser.add_argument('--team', required=True)
    parser.add_argument('--unsigned', choices=['0', '1'], default='0')
    args = parser.parse_args()
    require(bool(args.device_id) and bool(re.fullmatch('[A-Z0-9]{10}', args.team)), 'Explicit device and team required')
    os.umask(0o077)
    build = Build(args)
    try:
        build.execute()
    except (ValueError, RuntimeError, OSError, subprocess.SubprocessError) as error:
        (build.logs / 'failure.txt').write_text(str(error) + '\n')
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
