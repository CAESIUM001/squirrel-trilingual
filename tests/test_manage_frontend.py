"""Registration and startup regressions, using mocks without system changes."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import manage_frontend as manager

APP = Path("/tmp/Squirrel.app")
HANS = "im.rime.inputmethod.Squirrel.Hans"
HANT = "im.rime.inputmethod.Squirrel.Hant"


def report(enabled=None):
    modes = [HANS] if enabled is None else enabled
    expected = modes or [HANS]
    return {"protocolVersion": 1, "success": True, "appPath": str(APP),
            "launchServicesStatus": 0, "textInputSourceStatus": 0,
            "registeredModes": [HANS, HANT], "enabledModesBefore": modes,
            "expectedEnabledModes": expected, "enabledModesAfter": expected,
            "selectedSourceBefore": "com.apple.keylayout.ABC",
            "selectedSourceAfter": "com.apple.keylayout.ABC"}


class RegistrationTests(unittest.TestCase):
    def test_existing_modes_only_refresh_registration(self):
        with patch.object(manager.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, json.dumps(report()), "")) as run:
            manager.register(APP)
            self.assertEqual(run.call_count, 1)
            self.assertEqual(run.call_args.args[0][-1], "--register-input-source")

    def test_empty_snapshot_recovers_and_verifies_hans(self):
        process = subprocess.CompletedProcess([], 0, json.dumps(report([])), "")
        with patch.object(manager.subprocess, "run", return_value=process) as run:
            manager.register(APP)
            self.assertEqual(run.call_count, 1)
            manager.validate_registration(report([HANT]), APP)

    def test_reject_wrong_path_and_nonzero_api_status(self):
        for key, value in (("appPath", "/tmp/wrong.app"), ("textInputSourceStatus", -50),
                           ("success", False), ("registeredModes", [HANS]),
                           ("expectedEnabledModes", [HANT]), ("enabledModesAfter", [])):
            invalid = report(); invalid[key] = value
            with self.assertRaises(RuntimeError):
                manager.validate_registration(invalid, APP)

    def test_reject_legacy_unstructured_success(self):
        with patch.object(manager.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "Registered input source", "")):
            with self.assertRaises(RuntimeError):
                manager.register(APP)

    def test_legacy_rollback_uses_explicit_native_refresh(self):
        with patch.object(manager, "refresh_legacy_registration", return_value=report()) as refresh, \
             patch.object(manager.subprocess, "run") as run:
            manager.register(APP, legacy=True)
            refresh.assert_called_once_with(APP)
            run.assert_not_called()

    def test_start_refreshes_after_reload_and_checks_another_process(self):
        results = [subprocess.CompletedProcess([], 0), subprocess.CompletedProcess([], 1),
                   subprocess.CompletedProcess([], 0), subprocess.CompletedProcess([], 0)]
        events = []
        def registration(*args, **kwargs):
            events.append("register")
            return report()
        def command(*args, **kwargs):
            events.append(args[0][-1])
            return results.pop(0)
        with patch.object(manager, "register", side_effect=registration) as register, patch.object(manager.time, "sleep"), \
             patch.object(manager.subprocess, "run", side_effect=command) as run, \
             patch.object(manager, "stabilize_registration") as stabilize, \
             patch.object(manager, "verify_registration_in_fresh_process") as verify:
            manager.start(APP)
            self.assertEqual(register.call_count, 2)
            self.assertEqual(run.call_args.args[0][-1], "--reload")
            self.assertEqual(run.call_count, 4)
            self.assertEqual(events[-2:], ["--reload", "register"])
            verify.assert_called_once_with(APP, [HANS])
            stabilize.assert_called_once_with(APP, [HANS], False)

    def test_late_registration_loss_is_repaired_before_success(self):
        checks = [None] * 11 + [RuntimeError("late removal")] + [None] * 3
        with patch.object(manager, "verify_registration_in_fresh_process", side_effect=checks) as verify, \
             patch.object(manager, "register", return_value=report()) as register, \
             patch.object(manager.time, "sleep") as sleep:
            manager.stabilize_registration(APP, [HANS])
            self.assertEqual(verify.call_count, 15)
            register.assert_called_once_with(APP, legacy=False)
            self.assertEqual(sum(call.args[0] for call in sleep.call_args_list), 30)

    def test_cross_process_check_requires_stable_actual_modes(self):
        state = {"protocolVersion": 1, "bundleID": "im.rime.inputmethod.Squirrel", "appPath": str(APP),
                 "registeredModes": [HANS, HANT], "enabledModes": [HANS]}
        missing = dict(state, registeredModes=[], enabledModes=[])
        responses = [subprocess.CompletedProcess([], 0, json.dumps(item), "") for item in [missing, state, state]]
        with patch.object(manager.subprocess, "run", side_effect=responses) as run, patch.object(manager.time, "sleep"):
            self.assertEqual(manager.verify_registration_in_fresh_process(APP, [HANS]), state)
            self.assertEqual(run.call_count, 3)
            self.assertEqual(run.call_args.args[0][-2:], ["status", str(APP)])

    def test_failed_post_launch_install_stops_replacement_before_restoring(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, target, rime = root / "new.app", root / "installed.app", root / "Rime"
            for path in (source, target, rime):
                path.mkdir()
            (source / "binary").write_text("new")
            (target / "binary").write_text("old")
            original_style = "patch:\n  style/horizontal: true\n"
            (rime / "squirrel.custom.yaml").write_text(original_style)
            args = SimpleNamespace(app=source, target=target, rime_dir=rime, no_restart=False)
            events = []
            def stopped(app):
                events.append("stop:" + (app / "binary").read_text())
            def started(app, legacy_registration=False):
                events.append("start:" + (app / "binary").read_text())
                if not legacy_registration:
                    raise RuntimeError("synthetic registration failure")
            def copied(command, **kwargs):
                self.assertEqual(command[0], "/usr/bin/ditto")
                shutil.copytree(command[1], command[2])
                return subprocess.CompletedProcess(command, 0)
            with patch.object(manager, "verify_bundle"), \
                 patch.object(manager, "stop", side_effect=stopped), \
                 patch.object(manager, "start", side_effect=started), \
                 patch.object(manager.subprocess, "run", side_effect=copied):
                with self.assertRaisesRegex(RuntimeError, "synthetic registration failure"):
                    manager.install(args)
            self.assertEqual(events, ["stop:old", "start:new", "stop:new", "start:old"])
            self.assertEqual((target / "binary").read_text(), "old")
            self.assertEqual((rime / "squirrel.custom.yaml").read_text(), original_style)

    def test_failed_rollback_stop_preserves_replacement_and_original_backup(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, target, rime = root / "new.app", root / "installed.app", root / "Rime"
            for path in (source, target, rime):
                path.mkdir()
            (source / "binary").write_text("new")
            (target / "binary").write_text("old")
            args = SimpleNamespace(app=source, target=target, rime_dir=rime, no_restart=False)
            def stopped(app):
                if (app / "binary").read_text() == "new":
                    raise RuntimeError("replacement process still running")
            def copied(command, **kwargs):
                shutil.copytree(command[1], command[2])
                return subprocess.CompletedProcess(command, 0)
            with patch.object(manager, "verify_bundle"), \
                 patch.object(manager, "stop", side_effect=stopped), \
                 patch.object(manager, "start", side_effect=RuntimeError("registration failure")) as start, \
                 patch.object(manager.subprocess, "run", side_effect=copied):
                with self.assertRaisesRegex(RuntimeError, "original backup were preserved"):
                    manager.install(args)
            self.assertEqual(start.call_count, 1)
            self.assertEqual((target / "binary").read_text(), "new")
            backups = list((rime / "en_gloss-backups").glob("*/original-app/binary"))
            self.assertEqual(len(backups), 1)
            self.assertEqual(backups[0].read_text(), "old")


if __name__ == "__main__":
    unittest.main()
