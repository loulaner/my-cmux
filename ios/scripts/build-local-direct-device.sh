#!/bin/bash
# Build only: the separate installation/authentication decision remains outside this entry.
set -euo pipefail
TAG='' DEVICE_ID='' TEAM='' UNSIGNED=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag|--device-id|--team)
      [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || { echo 'Missing option value' >&2; exit 2; }
      case "$1" in --tag) TAG="$2";; --device-id) DEVICE_ID="$2";; --team) TEAM="$2";; esac
      shift 2 ;;
    --unsigned) UNSIGNED=1; shift ;;
    *) echo 'Expected --tag local-terminal-device --device-id <id> --team <team> [--unsigned]' >&2; exit 2 ;;
  esac
done
[[ "$TAG" == local-terminal-device && -n "$DEVICE_ID" && "$TEAM" =~ ^[A-Z0-9]{10}$ ]] || {
  echo 'Explicit dedicated tag, device identifier and signing team are required' >&2; exit 2;
}
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/lib/mobile-attach.sh"
cmux_attach_validate_dev_tag "$TAG"
[[ "$(cmux_attach__slug "$TAG")" == local-terminal-device ]] || exit 2
export CMUX_DEV_BACKEND_MODE=local
export PYTHONDONTWRITEBYTECODE=1
exec python3 "$ROOT/ios/scripts/local_direct_device_build.py" \
  --tag "$TAG" --device-id "$DEVICE_ID" --team "$TEAM" --unsigned "$UNSIGNED"
