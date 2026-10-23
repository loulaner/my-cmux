#!/bin/bash
# Isolated, app-hosted XCTest only; no cloud enrollment or physical-device installation.
set -euo pipefail
if [[ $# -lt 3 || $# -gt 4 ]]; then
  echo "usage: $0 <isolated-iPad-UDID> <new-result-directory> <derived-data-directory> [cmuxLocalTerminalTests|cmuxLocalTerminalTests/MobileLocalDirectStorageAcceptanceTests|cmuxUITests/LocalTerminalRotationUITests]" >&2
  exit 2
fi
TEST_OPTIONS=(-parallel-testing-enabled NO)
if [[ $# -eq 4 ]]; then
  case "$4" in
    cmuxLocalTerminalTests|cmuxLocalTerminalTests/MobileLocalDirectStorageAcceptanceTests|cmuxUITests/LocalTerminalRotationUITests) TEST_OPTIONS+=("-only-testing:$4") ;;
    *) echo "Unsupported acceptance test selection" >&2; exit 2 ;;
  esac
fi
UDID="$1"
OUT="$2"
DERIVED="$3"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
python3 - "$UDID" <<'PY'
import json, subprocess, sys
all_devices = [d for group in json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', '-j']))['devices'].values() for d in group]
d = next((d for d in all_devices if d['udid'] == sys.argv[1]), None)
if not d or d['name'] != 'cmux-dev-local-terminal-acceptance' or 'iPad' not in d.get('deviceTypeIdentifier', '') or not d.get('isAvailable'):
    raise SystemExit('Refusing anything except the task-owned, available iPad Simulator.')
if d['state'] != 'Booted' and sum(x['state'] == 'Booted' for x in all_devices) >= 3:
    raise SystemExit('Simulator concurrency limit reached; no other device will be stopped.')
PY
umask 077
mkdir -p "$OUT"
cd "$ROOT"
export CMUX_DEV_BACKEND_MODE=local
exec xcodebuild test "${TEST_OPTIONS[@]}" -workspace ios/cmux.xcworkspace -scheme cmux-ios -testPlan local-terminal-acceptance \
  -configuration Debug -destination "platform=iOS Simulator,id=$UDID" \
  -collect-test-diagnostics never \
  -maximum-concurrent-test-simulator-destinations 1 \
  -derivedDataPath "$DERIVED" -clonedSourcePackagesDirPath "$ROOT/.build/ios-personal/SourcePackages" \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -resultBundlePath "$OUT/runtime.xcresult" \
  CMUX_APP_BUNDLE_IDENTIFIER=dev.cmux.ios.local-terminal-acceptance \
  CMUX_HOST_BUNDLE_IDENTIFIER=dev.cmux.ios.local-terminal-acceptance \
  PRODUCT_DISPLAY_NAME='cmux DEV local-terminal-acceptance' CMUX_DEV_TAG=local-terminal-acceptance \
  EXCLUDED_SOURCE_FILE_NAMES=Info.plist CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) CMUX_LOCAL_TERMINAL_ACCEPTANCE' \
  SWIFT_OPTIMIZATION_LEVEL=-Onone SWIFT_COMPILATION_MODE=singlefile
