#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The launcher itself, as well as the app child, gets no caller credentials/context.
exec /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  /usr/bin/python3 -I "$SCRIPT_DIR/local_direct_mac.py" "$@"
