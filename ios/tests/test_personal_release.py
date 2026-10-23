#!/usr/bin/env python3
"""Portable structural guards for the personal iOS artifact (not a build test)."""
import importlib.util
import plistlib
from pathlib import Path
import sys
import os
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock
import datetime
import contextlib
import io
import xml.etree.ElementTree as ET

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("project_parser", ROOT / "scripts/check-pbxproj-group-membership.py")
parser = importlib.util.module_from_spec(spec)
spec.loader.exec_module(parser)


class PersonalReleaseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.project = parser.parse((ROOT / "ios/cmux-ios.xcodeproj/project.pbxproj").read_text())
        cls.objects = cls.project["objects"]
        cls.targets = {v["name"]: v for v in cls.objects.values() if v.get("isa") == "PBXNativeTarget"}

    def test_personal_target_has_no_extensions_or_target_dependencies(self):
        target = self.targets["cmux-personal"]
        self.assertEqual(target["dependencies"], [])
        phases = [self.objects[key] for key in target["buildPhases"]]
        self.assertNotIn("PBXCopyFilesBuildPhase", [p["isa"] for p in phases])
        scripts = [p["shellScript"] for p in phases if p["isa"] == "PBXShellScriptBuildPhase"]
        self.assertEqual(scripts, ['"${SRCROOT}/scripts/copy-markdown-viewer-assets.sh"\n'])
        self.assertFalse(parser.orphans(self.project))

    def test_personal_sources_match_original_but_phases_are_isolated(self):
        def file_refs(name, kind):
            target = self.targets[name]
            phases = [self.objects[key] for key in target["buildPhases"] if self.objects[key]["isa"] == kind]
            return {self.objects[key].get("fileRef", self.objects[key].get("productRef"))
                    for phase in phases for key in phase["files"]}
        original = file_refs("cmux", "PBXSourcesBuildPhase")
        personal = file_refs("cmux-personal", "PBXSourcesBuildPhase")
        fixtures = {"LocalTerminalUIAcceptance.swift", "LocalTerminalRendererRPCFixture.swift"}
        fixture_refs = {ref for ref in original if self.objects[ref]["path"].split("/")[-1] in fixtures}
        self.assertEqual({self.objects[ref]["path"].split("/")[-1] for ref in fixture_refs}, fixtures)
        self.assertEqual(original - personal, fixture_refs)
        self.assertEqual(original - fixture_refs, personal)
        for name in fixtures:
            source = (ROOT / "ios/cmuxLocalTerminalTests" / name).read_text()
            self.assertRegex(source.splitlines()[0], r"^#if DEBUG(?: &&|$)")
            self.assertEqual(source.strip().splitlines()[-1], "#endif")
        for kind in ["PBXResourcesBuildPhase", "PBXFrameworksBuildPhase"]:
            self.assertEqual(file_refs("cmux", kind), file_refs("cmux-personal", kind))
        self.assertTrue(set(self.targets["cmux"]["buildPhases"]).isdisjoint(self.targets["cmux-personal"]["buildPhases"]))
        self.assertEqual(len(self.targets["cmux"]["dependencies"]), 2)

    def test_only_release_is_selectable_and_scheme_targets_personal(self):
        target = self.targets["cmux-personal"]
        configs = self.objects[target["buildConfigurationList"]]["buildConfigurations"]
        self.assertEqual([self.objects[key]["name"] for key in configs], ["Release"])
        configuration = self.objects[configs[0]]
        self.assertEqual(self.objects[configuration["baseConfigurationReference"]]["path"], "PersonalRelease.xcconfig")
        self.assertEqual(configuration["buildSettings"]["INFOPLIST_FILE"], "Config/PersonalInfo.plist")
        scheme = ET.parse(ROOT / "ios/cmux-ios.xcodeproj/xcshareddata/xcschemes/cmux-personal.xcscheme")
        for action in ["LaunchAction", "ProfileAction", "AnalyzeAction", "ArchiveAction"]:
            self.assertEqual(scheme.find(action).get("buildConfiguration"), "Release")
        for ref in scheme.findall(".//BuildableReference"):
            self.assertEqual(self.objects[ref.get("BlueprintIdentifier")]["name"], "cmux-personal")

    def test_personal_entitlements_are_only_own_keychain(self):
        entitlements = plistlib.loads((ROOT / "ios/Config/cmux-personal.entitlements").read_bytes())
        self.assertEqual(entitlements, {"keychain-access-groups": ["$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)"]})

    def test_personal_metadata_preserves_protocol_and_removes_background_push(self):
        original = plistlib.loads((ROOT / "ios/Config/Info.plist").read_bytes())
        personal = plistlib.loads((ROOT / "ios/Config/PersonalInfo.plist").read_bytes())
        self.assertTrue(personal.pop("CMUXPersonalBuild"))
        for key in ["UIBackgroundModes", "CMUXCloudVPNProviderBundleIdentifier"]:
            self.assertNotIn(key, personal)
            original.pop(key)
        self.assertEqual(personal, original)

    def test_personal_config_does_not_claim_official_signing_identity(self):
        values = {}
        for line in (ROOT / "ios/Config/PersonalRelease.xcconfig").read_text().splitlines():
            if line.strip().startswith(("//", "#")) or "=" not in line:
                continue
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip()
        self.assertEqual(values["DEVELOPMENT_TEAM"], "")
        self.assertEqual(values["CMUX_APP_BUNDLE_IDENTIFIER"], "com.loulaner.mycmux.ios")
        self.assertEqual(values["SWIFT_ACTIVE_COMPILATION_CONDITIONS"], "")
        self.assertEqual(values["CMUX_DEV_TAG"], "")
        self.assertEqual(values["CMUX_IOS_AUTH_ENV"], "production")
        self.assertEqual(values["CMUX_IROH_V2_ENVIRONMENT"], "production")
        self.assertEqual(values["CMUX_APP_CODE_SIGN_ENTITLEMENTS"], "Config/cmux-personal.entitlements")


class PersonalBuildEntrypointTests(unittest.TestCase):
    def test_build_wrapper_only_requests_the_personal_ios_release(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script = root / "ios/scripts/build-personal.sh"
            script.parent.mkdir(parents=True)
            shutil.copyfile(ROOT / "ios/scripts/build-personal.sh", script)
            (root / "GhosttyKit.xcframework").mkdir()
            fakebin = root / "bin"
            fakebin.mkdir()
            fake = fakebin / "xcodebuild"
            fake.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
            fake.chmod(0o755)
            env = dict(os.environ, PATH=str(fakebin) + os.pathsep + os.environ["PATH"])
            result = subprocess.run(["bash", str(script), "--build", "--team", "ABCDE12345"], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.splitlines(), [
                "-workspace", str(root / "ios/cmux.xcworkspace"),
                "-scheme", "cmux-personal", "-configuration", "Release",
                "-destination", "generic/platform=iOS",
                "-derivedDataPath", str(root / ".build/ios-personal"),
                "-disableAutomaticPackageResolution", "DEVELOPMENT_TEAM=ABCDE12345",
                "CODE_SIGN_IDENTITY=Apple Development", "build",
            ])

    def test_provisioning_requires_explicit_device_and_permission(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script = root / "ios/scripts/build-personal.sh"
            script.parent.mkdir(parents=True)
            shutil.copyfile(ROOT / "ios/scripts/build-personal.sh", script)
            (root / "GhosttyKit.xcframework").mkdir()
            fakebin = root / "bin"; fakebin.mkdir()
            fake = fakebin / "xcodebuild"
            fake.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
            fake.chmod(0o755)
            env = dict(os.environ, PATH=str(fakebin) + os.pathsep + os.environ["PATH"])
            base = ["bash", str(script), "--build", "--team", "ABCDE12345", "--provision-device", "PHONE"]
            denied = subprocess.run(base, env=env, capture_output=True, text=True)
            self.assertEqual(denied.returncode, 2)
            accepted = subprocess.run(base + ["--allow-provisioning"], env=env, capture_output=True, text=True)
            self.assertEqual(accepted.returncode, 0, accepted.stderr)
            for value in ["platform=iOS,id=PHONE", "-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration"]:
                self.assertIn(value, accepted.stdout.splitlines())

    def test_help_and_invalid_requests_do_not_build(self):
        script = ROOT / "ios/scripts/build-personal.sh"
        for args, expected in [(["--help"], 0), ([], 2),
                               (["--build", "--team", "7WLXT3NR37"], 2),
                               (["--build", "--team", "bad"], 2)]:
            with self.subTest(args=args):
                result = subprocess.run(["bash", str(script), *args], capture_output=True, text=True)
                self.assertEqual(result.returncode, expected, result.stderr)


class PersonalRenewalTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location("personal_renew", ROOT / "ios/scripts/renew-personal.py")
        self.renew = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.renew)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "GhosttyKit.xcframework").mkdir()
        self.renew.ROOT = self.root
        env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
        subprocess.run(["git", "init", "-q", str(self.root)], env=env, check=True)
        subprocess.run(["git", "-C", str(self.root), "-c", "user.name=Fixture",
                        "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty",
                        "-qm", "Synthetic renewal fixture"], env=env, check=True)
        self.revision = subprocess.check_output(["git", "-C", str(self.root), "rev-parse", "HEAD"], text=True).strip()

    def arguments(self, *devices):
        return ["--renew", "--team", "ABCDE12345", "--expected-revision", self.revision,
                *[item for device in (devices or ("PHONE",)) for item in ("--device", device)]]

    def invoke(self, args, failure=None):
        calls = []
        real_run = subprocess.run
        def run(command, **kwargs):
            if command[0] == "git":
                return real_run(command, **kwargs)
            calls.append(command)
            code = 75 if "--install" in command else 0
            if failure and failure(command):
                code = 42
            return subprocess.CompletedProcess(command, code)
        with mock.patch.object(self.renew.subprocess, "run", side_effect=run), \
             contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            result = self.renew.main(args)
        return result, calls

    def test_explicit_phone_and_pending_acceptance(self):
        code, calls = self.invoke(self.arguments())
        self.assertEqual(code, 75)
        self.assertEqual(len(calls), 3)
        self.assertIn("PHONE", calls[0])
        self.assertIn("--allow-provisioning", calls[1])
        self.assertEqual(calls[2][-3:], ["--no-launch", "--min-valid-days", "5"])
        self.assertEqual(len(list(self.root.rglob("*.exit-code"))), 3)

    def test_all_devices_checked_then_each_built_and_installed(self):
        code, calls = self.invoke(self.arguments("PHONE", "PAD", "PAD"))
        self.assertEqual(code, 75)
        self.assertEqual(len(calls), 6)
        self.assertIn("PHONE", calls[0]); self.assertIn("PAD", calls[1])
        self.assertIn("PHONE", calls[2]); self.assertIn("PHONE", calls[3])
        self.assertIn("PAD", calls[4]); self.assertIn("PAD", calls[5])

    def test_preflight_failure_prevents_every_build(self):
        code, calls = self.invoke(self.arguments("PHONE", "PAD"),
                                  failure=lambda c: "PAD" in c)
        self.assertEqual(code, 1)
        self.assertEqual(len(calls), 2)

    def test_failed_build_cannot_install_stale_artifact(self):
        code, calls = self.invoke(self.arguments(), failure=lambda c: "--build" in c)
        self.assertEqual(code, 1)
        self.assertFalse(any("--install" in c for c in calls))

    def test_wrong_revision_never_builds(self):
        args = self.arguments()
        args[args.index("--expected-revision") + 1] = "0" * 40
        code, calls = self.invoke(args)
        self.assertEqual((code, calls), (1, []))

    def test_missing_or_malformed_authority_never_queries_devices(self):
        for flag in ["--team", "--device", "--expected-revision"]:
            args = self.arguments()
            index = args.index(flag)
            del args[index:index + 2]
            with self.subTest(missing=flag), mock.patch.object(self.renew.subprocess, "run") as run, \
                 contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
                self.renew.main(args)
            self.assertEqual(error.exception.code, 2)
            run.assert_not_called()
        for flag, value in [("--team", "bad"), ("--device", "../other"),
                            ("--expected-revision", "main"), ("--expected-revision", "a" * 39)]:
            args = self.arguments()
            args[args.index(flag) + 1] = value
            with self.subTest(flag=flag, value=value), mock.patch.object(self.renew.subprocess, "run") as run, \
                 contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
                self.renew.main(args)
            self.assertEqual(error.exception.code, 2)
            run.assert_not_called()

    def test_matching_revision_still_requires_prepared_artifact(self):
        (self.root / "GhosttyKit.xcframework").rmdir()
        code, calls = self.invoke(self.arguments())
        self.assertEqual((code, calls), (1, []))

    def test_only_explicit_devices_and_team_are_forwarded(self):
        code, calls = self.invoke(self.arguments("ONLY-PAD"))
        self.assertEqual(code, 75)
        for command in calls:
            self.assertIn("ONLY-PAD", command)
            self.assertNotIn("PHONE", command)
        for command in calls[1:]:
            self.assertEqual(command[command.index("--team") + 1], "ABCDE12345")

    def test_second_device_failure_preserves_first_delivery_receipt(self):
        code, calls = self.invoke(self.arguments("PHONE", "PAD"),
                                  failure=lambda c: "PAD" in c and "--build" in c)
        self.assertEqual(code, 1)
        self.assertEqual(sum("--install" in c for c in calls), 1)
        self.assertEqual(len(list(self.root.rglob("*.exit-code"))), 5)


class PersonalInstallRenewalTests(unittest.TestCase):
    def run_install(self, days=7, provisioned=True, valid_signature=True, arguments=None, profile_team="ABCDE12345"):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script = root / "ios/scripts/install-personal.sh"
            script.parent.mkdir(parents=True)
            shutil.copyfile(ROOT / "ios/scripts/install-personal.sh", script)
            app = root / ".build/ios-personal/Build/Products/Release-iphoneos/MyCMUX.app"
            app.mkdir(parents=True)
            (app / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "com.loulaner.mycmux.ios", "CMUXPersonalBuild": True,
                "CMUXAuthEnvironment": "production", "CMUX_IROH_V2_ENVIRONMENT": "production"}))
            identity = "ABCDE12345.com.loulaner.mycmux.ios"
            entitlements = {"application-identifier": identity, "keychain-access-groups": [identity]}
            (root / "entitlements.plist").write_bytes(plistlib.dumps(entitlements))
            (root / "profile.plist").write_bytes(plistlib.dumps({
                "TeamIdentifier": [profile_team], "Entitlements": entitlements, "ProvisionedDevices": ["PHONE"] if provisioned else [],
                "ExpirationDate": datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None) + datetime.timedelta(days=days)}))
            fakebin = root / "bin"; fakebin.mkdir()
            programs = {
                "codesign": '#!/bin/sh\nif [ "$1" = --verify ]; then exit ' + ('0' if valid_signature else '1') + '; fi\ncat "$FIXTURE/entitlements.plist"\n',
                "security": '#!/bin/sh\ncat "$FIXTURE/profile.plist"\n',
                "xcrun": '#!/bin/sh\nprintf "%s\\n" "$@" >> "$FIXTURE/calls"\n',
            }
            for name, content in programs.items():
                content = content.replace("#!/bin/sh\n", '#!/bin/sh\nprintf "%s\\n" "' + name + '" >> "$FIXTURE/tool-calls"\n', 1)
                path = fakebin / name; path.write_text(content); path.chmod(0o755)
            env = dict(os.environ, PATH=str(fakebin) + os.pathsep + os.environ["PATH"], FIXTURE=str(root))
            args = arguments if arguments is not None else ["--install", "--team", "ABCDE12345", "--device", "PHONE",
                                                            "--no-launch", "--min-valid-days", "5"]
            result = subprocess.run(["bash", str(script), *args], env=env, capture_output=True, text=True)
            if result.returncode == 2:
                self.assertFalse((root / "tool-calls").exists(), "invalid arguments reached external tools")
            calls = (root / "calls").read_text() if (root / "calls").exists() else ""
            return result, calls

    def test_fresh_profile_installs_without_launch(self):
        result, calls = self.run_install()
        self.assertEqual(result.returncode, 75, result.stderr)
        self.assertIn("install", calls)
        self.assertNotIn("launch", calls)
        self.assertIn("Provisioning expires", result.stdout)

    def test_invalid_cli_does_not_touch_signing_or_devices(self):
        base = ["--install", "--team", "ABCDE12345", "--device", "PHONE"]
        cases = [[], ["--install", "--device", "PHONE"], ["--install", "--team", "ABCDE12345"],
                 base + ["--team", "OTHER12345"], base + ["--device", "PAD"], base + ["--unknown"],
                 ["--install", "--team", "bad", "--device", "PHONE"],
                 ["--install", "--team", "ABCDE12345", "--device", "../bad"],
                 base + ["--min-valid-days", "5"], base + ["--no-launch"],
                 base + ["--no-launch", "--min-valid-days", "-1"]]
        for args in cases:
            with self.subTest(args=args):
                result, calls = self.run_install(arguments=args)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertEqual(calls, "")

    def test_wrong_explicit_team_does_not_install(self):
        result, calls = self.run_install(arguments=["--install", "--team", "OTHER12345", "--device", "PHONE"])
        self.assertEqual(calls, "")
        self.assertIn("Wrong signed identity", result.stderr)
        self.assertNotEqual(result.returncode, 75)

    def test_wrong_profile_team_does_not_install(self):
        result, calls = self.run_install(profile_team="OTHER12345")
        self.assertEqual(calls, "")
        self.assertIn("Wrong provisioning team", result.stderr)
        self.assertNotEqual(result.returncode, 75)

    def test_old_profile_does_not_install(self):
        result, calls = self.run_install(days=2)
        self.assertNotEqual(result.returncode, 75)
        self.assertEqual(calls, "")
        self.assertIn("insufficient", result.stderr)

    def test_unprovisioned_device_does_not_install(self):
        result, calls = self.run_install(provisioned=False)
        self.assertNotEqual(result.returncode, 75)
        self.assertEqual(calls, "")

    def test_invalid_signature_does_not_install(self):
        result, calls = self.run_install(valid_signature=False)
        self.assertNotEqual(result.returncode, 75)
        self.assertEqual(calls, "")


if __name__ == "__main__":
    unittest.main()
