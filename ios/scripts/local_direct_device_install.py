#!/usr/bin/env python3
"""Explicit manual-pairing device lane. Default cloud reload never calls this module."""
import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys
from pathlib import Path

from local_direct_device_build import BUNDLE, ROOT, TAG, Build, decode_json, require, select_device

sys.dont_write_bytecode = True


def load_mac_verifier():
    spec = importlib.util.spec_from_file_location('local_direct_mac', ROOT / 'scripts/local_direct_mac.py')
    if spec is None or spec.loader is None:
        raise RuntimeError('Missing Mac verifier')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


mac_verifier = load_mac_verifier()
MAC_BUNDLE = mac_verifier.MAC_BUNDLE
MAC_SOCKET = mac_verifier.MAC_SOCKET
validate_mac_identity = mac_verifier.validate_mac_identity
private_path = mac_verifier.private_path
verify_mac = mac_verifier.verify_mac

PENDING_EXIT = 75
PENDING_STATE = 'INSTALLED_PENDING_PAIRING'


class Pending(Exception):
    pass


def require_unlocked(document):
    state = document.get('result', {})
    required = state.get('passcodeRequired')
    unlocked = state.get('unlockedSinceBoot')
    if not isinstance(required, bool) or required or not isinstance(unlocked, bool) or not unlocked:
        raise Pending('IPAD_LOCKED_OR_UNKNOWN: unlock the selected iPad; NOT_QUEUED')


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument('--connection-mode', required=True, choices=['local-direct'])
    parser.add_argument('--tag', required=True, choices=[TAG])
    parser.add_argument('--device-only', action='store_true', required=True)
    parser.add_argument('--device-id', required=True)
    parser.add_argument('--team', required=True)
    parser.add_argument('--build-receipt', type=Path, required=True)
    parser.add_argument('--mac-receipt', type=Path, required=True)
    args = parser.parse_args(argv)
    if not args.device_id or not re.fullmatch('[A-Z0-9]{10}', args.team):
        parser.error('Explicit device and signing team required')
    return args


class Install(Build):
    def __init__(self, args):
        environment = {key: value for key, value in os.environ.items()
                       if key in ['PATH', 'HOME', 'USER', 'LOGNAME', 'TMPDIR', 'LANG', 'DEVELOPER_DIR'] or key.startswith('LC_')}
        super().__init__(args, environment=environment, purpose="install")

    def device_json(self, name, command):
        path = self.logs / (name + '.json')
        try:
            self.run(name, ['xcrun', 'devicectl', *command, '--json-output', str(path)])
        except RuntimeError as error:
            raise Pending('IPAD_UNREACHABLE: reconnect/unlock the selected iPad; NOT_QUEUED') from error
        return decode_json(path.read_text())

    def selected_apps(self, identifier):
        document = self.device_json('apps', ['device', 'info', 'apps', '--device', identifier, '--include-all-apps'])
        return [app for app in document['result']['apps'] if app.get('bundleIdentifier') == BUNDLE]

    def mutation(self, name, command):
        try:
            self.run(name, command)
        except RuntimeError as error:
            diagnostic = (self.logs / (name + '.log')).read_text().lower()
            if any(word in diagnostic for word in ['locked', 'not connected', 'offline', 'not available', 'timed out']):
                raise Pending('DEVICE_DELIVERY_PENDING: reconnect/unlock; NOT_QUEUED') from error
            raise

    def deliver(self):
        # Both receipts are locators, never auth or signature evidence.
        mac = verify_mac(self.args.mac_receipt)
        located = decode_json(private_path(self.args.build_receipt).read_text())
        app = Path(located['app_path']).resolve(strict=True)
        devices = self.device_json('devices', ['list', 'devices'])
        entries = devices.get('result', {}).get('devices', [])
        if not entries:
            raise Pending('IPAD_OFFLINE: NOT_QUEUED')
        exact = [d for d in entries if self.args.device_id in
                 (d.get('identifier'), d.get('hardwareProperties', {}).get('udid'))]
        require(len(exact) == 1, 'Wrong or ambiguous explicit device')
        if exact[0].get('deviceProperties', {}).get('bootState') != 'booted':
            raise Pending('IPAD_OFFLINE: NOT_QUEUED')
        device = select_device(devices, self.args.device_id)
        identifier = device['identifier']
        current = self.selected_apps(identifier)
        require_unlocked(self.device_json('lock', ['device', 'info', 'lockState', '--device', identifier]))
        certificate = self.identity()
        # Shared real artifact checks: no signed:true receipt trust and no rebuild.
        try:
            self.validate_artifact(app, device, certificate, signed=True)
        except ValueError as error:
            raise RuntimeError('SIGNATURE_OR_ARTIFACT_REJECTED: ' + str(error)) from error
        owner_file = Path(mac['state_directory']) / 'ipad-install-owned.json'
        if current:
            require(owner_file.exists(), 'Existing same-ID app has no task ownership proof; refusing overwrite')
            owned = decode_json(private_path(owner_file).read_text())
            require(owned.get('device') == device['hardwareProperties']['udid'] and owned.get('apps') == current,
                    'Existing same-ID app does not match task ownership proof')
        # Revalidate live Mac and device immediately before any device mutation.
        verify_mac(self.args.mac_receipt)
        require_unlocked(self.device_json('lock-final', ['device', 'info', 'lockState', '--device', identifier]))
        require(self.selected_apps(identifier) == current, 'Device app inventory changed during preflight')
        if current:
            self.run('terminate-owned', [str(ROOT / 'scripts/ios-device-process.sh'), 'terminate-installed',
                                        '--device-id', identifier, '--bundle-id', BUNDLE])
        self.environment['CMUX_SANCTIONED_IPHONE_INSTALL'] = '1'
        try:
            self.mutation('install', ['xcrun', 'devicectl', 'device', 'install', 'app', '--device', identifier, str(app)])
        finally:
            self.environment.pop('CMUX_SANCTIONED_IPHONE_INSTALL', None)
        installed = self.selected_apps(identifier)
        require(len(installed) == 1, 'Installed app inventory was not confirmed')
        owner_file.write_text(json.dumps({'device': device['hardwareProperties']['udid'], 'apps': installed}, indent=2))
        self.mutation('launch', ['xcrun', 'devicectl', 'device', 'process', 'launch', '--device', identifier, BUNDLE])
        (self.logs / 'receipt.json').write_text(json.dumps({'state': PENDING_STATE, 'queued': False,
                                                          'delivered': False, 'tag': TAG, 'bundle_id': BUNDLE}, indent=2))
        print(PENDING_STATE + ': NOT_QUEUED; NOT_DELIVERED')
        print('Keep iPad unlocked with Tailscale enabled. Enter the Mac address in Direct DEV; manually open pairing and approve on the tagged Mac.')
        return PENDING_EXIT


def main(argv=None):
    args = parse_args(argv)
    os.umask(0o077)
    operation = Install(args)
    try:
        return operation.deliver()
    except Pending as error:
        print(str(error), file=sys.stderr)
        return PENDING_EXIT
    except (ValueError, KeyError, OSError) as error:
        (operation.logs / 'failure.txt').write_text(str(error))
        print('DIRECT_PREFLIGHT_REJECTED: see private log; NOT_QUEUED', file=sys.stderr)
        return 2
    except (RuntimeError, subprocess.SubprocessError) as error:
        (operation.logs / 'failure.txt').write_text(str(error))
        print('DIRECT_OPERATION_FAILED: see private log; NOT_QUEUED', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
