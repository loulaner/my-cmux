#!/usr/bin/env bash
# Build-only entrypoint. Never installs, launches, logs in, pairs or builds Mac cmux.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
usage() {
  echo 'Usage: bash ios/scripts/build-personal.sh --build --team <YOUR_TEAM_ID>'
  echo 'Requires separate authorization, prepared GhosttyKit/SwiftPM dependencies and Apple signing.'
  echo 'Optional: --provision-device <UDID> --allow-provisioning (contacts Apple for signing).'
  echo 'Builds cmux-personal in Release for iOS; does not install or launch it.'
}
if [[ "${1:-}" == --help ]]; then usage; exit 0; fi
if [[ ( $# -ne 3 && $# -ne 6 ) || "$1" != --build || "$2" != --team || ! "$3" =~ ^[A-Z0-9]{10}$ ]]; then
  usage >&2; exit 2
fi
TEAM="$3"
DESTINATION='generic/platform=iOS'
PROVISION=()
if [[ $# -eq 6 ]]; then
  if [[ "$4" != --provision-device || ! "$5" =~ ^[A-Za-z0-9-]+$ || "$6" != --allow-provisioning ]]; then
    usage >&2; exit 2
  fi
  DESTINATION="platform=iOS,id=$5"
  PROVISION=(-allowProvisioningUpdates -allowProvisioningDeviceRegistration)
fi
if [[ "$TEAM" == 7WLXT3NR37 ]]; then
  echo 'Refusing the upstream publisher team; supply your own Personal Team.' >&2; exit 2
fi
if [[ ! -d "$ROOT/GhosttyKit.xcframework" ]]; then
  echo 'GhosttyKit is missing. Dependency preparation requires separate approval.' >&2; exit 1
fi
# Disallow automatic dependency resolution: this entrypoint is not a setup script.
# The workspace supplies cmuxFeature and its local Swift packages.
exec xcodebuild \
  -workspace "$ROOT/ios/cmux.xcworkspace" \
  -scheme cmux-personal \
  -configuration Release \
  -destination "$DESTINATION" \
  -derivedDataPath "$ROOT/.build/ios-personal" \
  -disableAutomaticPackageResolution \
  DEVELOPMENT_TEAM="$TEAM" \
  CODE_SIGN_IDENTITY='Apple Development' \
  ${PROVISION[@]+"${PROVISION[@]}"} \
  build
