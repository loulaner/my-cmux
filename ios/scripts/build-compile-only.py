#!/usr/bin/env python3
"""Compile an unsigned MyCMUX iOS target, without device or signing access."""
import argparse
import json
import os
import plistlib
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCHEMES = {
    'cmux-ios': ('Debug', 'com.loulaner.mycmux.ios.debug', 'MyCMUX DEV'),
    'cmux-personal': ('Release', 'com.loulaner.mycmux.ios', 'MyCMUX'),
    'cmux-local-direct': ('Debug', 'com.loulaner.mycmux.ios.debug.local-terminal-device', 'MyCMUX Direct DEV'),
}


def command(scheme, output):
    configuration, _, _ = SCHEMES[scheme]
    return ['xcodebuild', 'build', '-workspace', 'ios/cmux.xcworkspace',
            '-scheme', scheme, '-configuration', configuration,
            '-destination', 'generic/platform=iOS', '-derivedDataPath', str(output / 'DerivedData'),
            '-clonedSourcePackagesDirPath', str(ROOT / '.build/ios-personal/SourcePackages'),
            '-disableAutomaticPackageResolution', '-onlyUsePackageVersionsFromResolvedFile',
            '-jobs', '4', 'CODE_SIGNING_ALLOWED=NO', 'CODE_SIGNING_REQUIRED=NO',
            'CODE_SIGN_IDENTITY=', 'DEVELOPMENT_TEAM=', 'EXCLUDED_SOURCE_FILE_NAMES=Info.plist']


def execute(scheme, output, runner=subprocess.run):
    # A new exclusive output directory prevents adopting a signed/previous artifact.
    output.mkdir(mode=0o700, parents=False, exist_ok=False)
    configuration, bundle, product = SCHEMES[scheme]
    receipt = {'mode': 'compile-only', 'unsigned': True, 'signed': False,
               'installable': False, 'state': 'NOT_INSTALLABLE', 'scheme': scheme,
               'configuration': configuration, 'bundle_id': bundle, 'build_exit': None}
    (output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    environment = {k: os.environ[k] for k in ('HOME', 'PATH', 'TMPDIR', 'DEVELOPER_DIR', 'LANG') if k in os.environ}
    environment['CMUX_DEV_BACKEND_MODE'] = 'local'
    argv = command(scheme, output)
    (output / 'build.command.json').write_text(json.dumps(argv, indent=2) + '\n')
    with (output / 'build.log').open('wb') as log:
        result = runner(argv, cwd=ROOT, env=environment, stdout=log, stderr=subprocess.STDOUT)
    (output / 'build.exit').write_text(str(result.returncode) + '\n')
    receipt['build_exit'] = result.returncode
    if result.returncode == 0:
        app = output / 'DerivedData/Build/Products' / (configuration + '-iphoneos') / (product + '.app')
        info = plistlib.loads((app / 'Info.plist').read_bytes())
        if info.get('CFBundleIdentifier') != bundle or info.get('CFBundleExecutable') != product:
            raise ValueError('Compiled artifact identity mismatch')
        if (app / 'embedded.mobileprovision').exists() or (app / '_CodeSignature').exists():
            raise ValueError('Unexpected signed artifact in compile-only output')
        if scheme == 'cmux-local-direct':
            from local_direct_device_build import validate_metadata
            validate_metadata(info)
        if scheme != 'cmux-ios' and list(app.rglob('*.appex')):
            raise ValueError('Unexpected embedded extension')
        receipt['app_path'] = str(app)
        receipt['state'] = 'COMPILED_UNSIGNED_NOT_INSTALLABLE'
    (output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    return result.returncode


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument('--scheme', required=True, choices=SCHEMES)
    parser.add_argument('--output', required=True, type=Path, help='new private directory inside an existing task directory')
    args = parser.parse_args(argv)
    os.umask(0o077)
    try:
        return execute(args.scheme, args.output.resolve())
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
