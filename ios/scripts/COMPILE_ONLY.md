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
