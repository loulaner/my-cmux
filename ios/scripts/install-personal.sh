#!/usr/bin/env bash
# Personal Release only. No DEV credentials, Mac reload, terminal input or auth bypass.
# Exit 75 after delivery means live connection acceptance is still pending.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ "${1:-}" == --help && $# -eq 1 ]]; then
  echo 'Usage: bash ios/scripts/install-personal.sh --install --team <TEAM> --device <UDID> [--no-launch --min-valid-days <days>]'
  echo 'Verifies the explicit team and device before installation. Exit 75 means acceptance is pending.'
  exit 0
fi
INSTALL=0
TEAM=
DEVICE=
MODE=launch
DAYS=
fail() { echo "$1" >&2; exit 2; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --install) [[ "$INSTALL" == 0 ]] || fail 'Duplicate --install'; INSTALL=1; shift ;;
    --team) [[ -z "$TEAM" && $# -ge 2 ]] || fail 'Missing or duplicate --team'; TEAM="$2"; [[ "$TEAM" =~ ^[A-Z0-9]{10}$ ]] || fail 'Invalid team'; shift 2 ;;
    --device) [[ -z "$DEVICE" && $# -ge 2 ]] || fail 'Missing or duplicate --device'; DEVICE="$2"; [[ "$DEVICE" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || fail 'Invalid device'; shift 2 ;;
    --no-launch) [[ "$MODE" == launch ]] || fail 'Duplicate --no-launch'; MODE=no-launch; shift ;;
    --min-valid-days) [[ -z "$DAYS" && $# -ge 2 ]] || fail 'Missing or duplicate --min-valid-days'; DAYS="$2"; [[ "$DAYS" =~ ^[0-9]+$ ]] || fail 'Invalid days'; shift 2 ;;
    *) fail 'Unknown argument' ;;
  esac
done
[[ "$INSTALL" == 1 && -n "$TEAM" && -n "$DEVICE" ]] || fail 'Required: --install --team <TEAM> --device <UDID>'
if [[ "$MODE" == no-launch ]]; then
  [[ -n "$DAYS" ]] || fail '--no-launch requires --min-valid-days'
else
  [[ -z "$DAYS" ]] || fail '--min-valid-days requires --no-launch'
  DAYS=0
fi
python3 - "$ROOT" "$DEVICE" "$MODE" "$DAYS" "$TEAM" <<'PY'
import datetime
import os
from pathlib import Path
import plistlib
import subprocess
import sys

root, device = Path(sys.argv[1]), sys.argv[2]
app = root / '.build/ios-personal/Build/Products/Release-iphoneos/cmux-personal.app'
bundle_id = 'com.loulaner.cmuxpersonal'
team = sys.argv[5]
def output(args):
    return subprocess.check_output(args, stderr=subprocess.PIPE)

subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
info = plistlib.loads((app / 'Info.plist').read_bytes())
entitlements = plistlib.loads(output(['codesign', '-d', '--entitlements', ':-', str(app)]))
profile = plistlib.loads(output(['security', 'cms', '-D', '-i', str(app / 'embedded.mobileprovision')]))
def require(condition, message):
    if not condition:
        raise SystemExit(message)

require(info.get('CFBundleIdentifier') == bundle_id and info.get('CMUXPersonalBuild') is True, 'Not the personal artifact')
require(info.get('CMUXAuthEnvironment') == 'production' and info.get('CMUX_IROH_V2_ENVIRONMENT') == 'production', 'Wrong service environment')
require(not info.get('CMUXDevTag'), 'DEV artifacts are not accepted')
require(not list(app.glob('PlugIns/*.appex')), 'Unexpected embedded extension')
require(entitlements.get('application-identifier') == team + '.' + bundle_id, 'Wrong signed identity')
require(entitlements.get('keychain-access-groups') == [team + '.' + bundle_id], 'Wrong Keychain scope')
for key in ['aps-environment', 'com.apple.developer.applesignin', 'com.apple.security.application-groups', 'com.apple.developer.networking.networkextension']:
    require(key not in entitlements, 'Unexpected entitlement: ' + key)
require(profile['Entitlements'].get('application-identifier') == team + '.' + bundle_id, 'Wrong provisioning identity')
require(profile.get('TeamIdentifier') == [team], 'Wrong provisioning team')
require(device in profile.get('ProvisionedDevices', []), 'Device is not provisioned')
expiry = profile['ExpirationDate']
now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
require(expiry > now + datetime.timedelta(days=int(sys.argv[4])),
        'Provisioning lifetime is insufficient; Xcode may have reused an old profile. No install performed.')
print('Provisioning expires (UTC):', expiry.isoformat(), flush=True)
# No inherited DEV auto-login, attach URL or credential injection on launch.
environment = {k: v for k, v in os.environ.items() if not k.startswith('DEVICECTL_CHILD_')}
subprocess.run(['xcrun', 'devicectl', 'device', 'install', 'app', '--device', device, str(app)], env=environment, check=True)
if sys.argv[3] == 'launch':
    subprocess.run(['xcrun', 'devicectl', 'device', 'process', 'launch', '--device', device, bundle_id], env=environment, check=True)
print('PENDING: open the app, sign in if needed, and verify the existing Mac connection; installation is not acceptance.')
sys.exit(75)
PY
