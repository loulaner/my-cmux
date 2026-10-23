# Unsigned compilation

`python3 ios/scripts/build-compile-only.py --scheme cmux-local-direct --output /path/to/task/new-run`

The output directory must not exist. Supported schemes are `cmux-ios` (Debug),
`cmux-personal` (Release), and `cmux-local-direct` (Debug). Each keeps its configured
MyCMUX identity; no arbitrary build settings are accepted. Prepare the existing
pinned dependencies first; this command does not install tools or change locks.

The private output contains DerivedData, the complete build log, exit code and a
`mode=compile-only`, unsigned, non-installable receipt. It never queries devices,
Keychain or signing identities, and never installs or launches an app. Signing and
installation still require the separate guarded workflows; this receipt is not
accepted by those workflows. Compilation does not verify device connectivity.

## Store publishing is unavailable

MyCMUX does not currently support TestFlight or App Store distribution. The old
`upload-testflight.sh`, `cloud-testflight.sh`, and `upload-app-store.sh` entry
points reject publishing, export-only, and prepare-only requests with exit 64.
`--help` only explains this limitation; it does not build or access credentials.

Compile-only outputs cannot be installed. Personal installation still requires
explicit authorization and the existing signing, team, profile, and receipt
checks. Local-direct delivery also requires manual pairing approval and the
terminal/reconnect/revocation acceptance checks; installation alone is not success.
