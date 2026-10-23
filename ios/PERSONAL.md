# Personal-device Release preparation

This local variant targets the installed Stable Mac at commit
`9d01f956c51cd895e10e7d56b6dd7b5f6fcce625` (0.65.2, build 111).
The personal Release has been signed and installed on the iPhone; the user has
reported terminal display. The weekly renewal workflow below has portable mock
tests only: live renewal, iPad installation and disconnect/reconnect acceptance
remain unverified.

## Artifact contract

- Workspace: `ios/cmux.xcworkspace`; scheme/target: `cmux-personal`.
- Release only, no DEBUG or development tag; production account and Iroh v2 services.
- Bundle ID: `com.loulaner.cmuxpersonal`; display name: `cmux Personal`.
- The signing Team is intentionally blank. Select your own Personal Team in Xcode
  after signing preparation is approved. Never use the publisher's Team or identity.
- Same app sources/resources; neither NotificationService nor CloudVPN is built or embedded.
- Only the app's own Keychain group is claimed; no App Group, APNs, Apple sign-in,
  time-sensitive notifications or Network Extension entitlement.
- Normal email-code authentication remains required. OAuth buttons and remote-push
  controls are absent. Push opt-in, token callbacks, foreground recovery and auth
  restoration cannot register push in this artifact. Existing distributions retain
  their behavior when `CMUXPersonalBuild` is absent.
- CloudVPN already checks for its embedded extension and returns no controller
  when absent; do not duplicate or bypass that check.
- Iroh may use direct or relay paths. This is **not** a Tailscale-only guarantee.
  Account, team, device proof and transport authorization remain unchanged.

`PersonalInfo.plist` intentionally mirrors `Info.plist` except the personal marker,
remote-notification background mode and CloudVPN provider ID. The structural guard
fails if the two drift elsewhere.

## Renew a personal installation

Renewal requires an explicit signing team, each intended device, and the approved
full 40-character source revision. There is no default personal team or device.
From your checkout root, replace these placeholders before running:

```sh
python3 ios/scripts/renew-personal.py --renew \
  --team YOUR_TEAM_ID \
  --device YOUR_DEVICE_UDID \
  --expected-revision APPROVED_FULL_40_CHARACTER_COMMIT_SHA
```

Repeat `--device YOUR_OTHER_DEVICE_UDID` to include another device. Use
`python3 ios/scripts/renew-personal.py --list-devices` to explicitly list devices
without building. Listing cannot be combined with renewal options.

The revision must match `git rev-parse HEAD`; an incorrect or missing revision
stops before any device query or build. The script uses the current working tree,
including local changes, so review those changes separately before approving a
revision. It does not pull, reset, clean, update sources or upload artifacts.

Connect and unlock each device, enable Developer Mode, and establish trust in
Xcode first. The user must configure the Apple account in Xcode; do not put
passwords, signing credentials or personal device identifiers in the repository.
Apple's free-team and registered-device limits still apply.

After checking every requested device, renewal builds and validates each signed
artifact before installing it on that device. The profile must cover that device
and have more than five days remaining. A failed build cannot install an older
artifact. Private logs remain under `.build/ios-personal-renew`; never publish them.

Renewal does not launch the app, uninstall an old app, clear accounts or control
the Mac app or Pi. Exit 75 means installation is still awaiting manual connection
acceptance, not a verified terminal connection. A same-team, same-bundle renewal
is intended to retain data; a future different bundle is an independent app and
must not import old accounts or pairing data automatically. Plan free-profile
renewal before its expiration, typically after five or six days.

Direct installation also requires the same explicit team: `bash ios/scripts/install-personal.sh --install --team YOUR_TEAM_ID --device YOUR_DEVICE_UDID --no-launch --min-valid-days 5`. The installer never infers the expected team from an artifact.
