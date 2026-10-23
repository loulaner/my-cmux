#!/usr/bin/env python3
"""Renew this local personal iOS build. No source updates or Mac app operations."""
import argparse
import fcntl
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--renew", action="store_true", help="authorize Apple provisioning, build and install")
    parser.add_argument("--team", help="explicit 10-character signing team identifier")
    parser.add_argument("--device", action="append", help="explicit device UDID; repeat for each intended device")
    parser.add_argument("--expected-revision", help="explicit approved full 40-character commit SHA")
    parser.add_argument("--list-devices", action="store_true", help="list connected/known devices without building")
    args = parser.parse_args(argv)
    if args.list_devices:
        if args.renew or args.device or args.team or args.expected_revision:
            parser.error("--list-devices cannot be combined with renewal options")
        return subprocess.call(["xcrun", "devicectl", "list", "devices"])
    if not args.renew:
        parser.error("supply --renew to provision, build and install")
    if not args.team or not args.device or not args.expected_revision:
        parser.error("--renew requires --team, --device and --expected-revision")
    if not re.fullmatch(r"[A-Z0-9]{10}", args.team):
        parser.error("invalid signing team identifier")
    if not re.fullmatch(r"[0-9a-fA-F]{40}", args.expected_revision):
        parser.error("--expected-revision must be a full 40-character commit SHA")
    devices = list(dict.fromkeys(args.device))
    if any(not re.fullmatch(r"[A-Za-z0-9-]+", d) or d.startswith("-") for d in devices):
        parser.error("invalid device identifier")
    env = {k: v for k, v in os.environ.items() if not k.startswith("DEVICECTL_CHILD_")}
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    if head != args.expected_revision.lower():
        print("STOP: checkout is not the approved base revision; no source reset or update was attempted.", file=sys.stderr)
        return 1
    if not (ROOT / "GhosttyKit.xcframework").is_dir():
        print("STOP: prepare the pinned dependencies first; this script does not download them.", file=sys.stderr)
        return 1
    state = ROOT / ".build/ios-personal-renew"
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (state / "renew.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("STOP: another renewal is running.", file=sys.stderr)
            return 1
        logs = Path(tempfile.mkdtemp(prefix="run-", dir=state))
        print(f"Logs (private; may contain device/account details): {logs}", flush=True)
        print("Uses current local personal changes on the fixed base; no git pull, clean, checkout or upload.", flush=True)

        def run(label, command, accepted=(0,)):
            with (logs / (label + ".log")).open("wb") as log:
                result = subprocess.run(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT)
            (logs / (label + ".exit-code")).write_text(str(result.returncode) + "\n")
            if result.returncode not in accepted:
                print(f"STOP: {label}, exit {result.returncode}. See {logs / (label + '.log')}", file=sys.stderr)
                return False
            return True

        # Check all requested devices before provisioning or installing any app.
        for i, device in enumerate(devices, 1):
            if not run(f"{i}-device", ["xcrun", "devicectl", "--timeout", "30", "device", "info", "details", "--device", device]):
                return 1
        installed = []
        for i, device in enumerate(devices, 1):
            print(f"[{i}/{len(devices)}] Provision and build for {device}", flush=True)
            build = ["bash", str(ROOT / "ios/scripts/build-personal.sh"), "--build", "--team", args.team,
                     "--provision-device", device, "--allow-provisioning"]
            install = ["bash", str(ROOT / "ios/scripts/install-personal.sh"), "--install", "--team", args.team, "--device", device,
                       "--no-launch", "--min-valid-days", "5"]
            # The device-specific build may replace the previous profile: validate/install
            # immediately, never reuse that artifact for a later device without rebuilding.
            if not run(f"{i}-build", build) or not run(f"{i}-install", install, accepted=(75,)):
                print("Previously installed in this run:", ", ".join(installed) or "none", flush=True)
                return 1
            installed.append(device)
            print(f"INSTALLED: {device}; signed profile has >5 days remaining. Connection not tested.", flush=True)
        print("PENDING: manually open each app and verify the existing Mac terminal. No app was auto-launched.")
        print("Schedule the next renewal in 5–6 days, before the free profile expires.")
        return 75


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, subprocess.CalledProcessError) as error:
        print(f"STOP: {error}", file=sys.stderr)
        sys.exit(1)
