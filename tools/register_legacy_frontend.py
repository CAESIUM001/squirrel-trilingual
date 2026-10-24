"""Refresh LS/TIS for an old Squirrel bundle whose registration CLI is broken.

SPDX-License-Identifier: GPL-3.0-or-later
No registration is performed on import. Used only during installation rollback.
"""
import ctypes as C
import argparse
from contextlib import ExitStack
from pathlib import Path
import plistlib
import json

BUNDLE_ID = "im.rime.inputmethod.Squirrel"
MODES = {BUNDLE_ID + ".Hans", BUNDLE_ID + ".Hant"}


def _registration(app, inspect_only=False):
    app = Path(app).resolve()
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != BUNDLE_ID:
        raise ValueError("Legacy registration target has an unexpected bundle ID")
    cf = C.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    ls = C.CDLL("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/LaunchServices")
    tis = C.CDLL("/System/Library/Frameworks/Carbon.framework/Frameworks/HIToolbox.framework/HIToolbox")

    def bind(lib, name, args, result):
        fn = getattr(lib, name)
        fn.argtypes, fn.restype = args, result
        return fn

    ptr, status = C.c_void_p, C.c_int32
    release = bind(cf, "CFRelease", [ptr], None)
    create_url = bind(cf, "CFURLCreateFromFileSystemRepresentation", [ptr, C.c_char_p, C.c_long, C.c_ubyte], ptr)
    array_count = bind(cf, "CFArrayGetCount", [ptr], C.c_long)
    array_item = bind(cf, "CFArrayGetValueAtIndex", [ptr, C.c_long], ptr)
    get_string = bind(cf, "CFStringGetCString", [ptr, C.c_char_p, C.c_long, C.c_uint32], C.c_ubyte)
    get_bool = bind(cf, "CFBooleanGetValue", [ptr], C.c_ubyte)
    run_loop = bind(cf, "CFRunLoopRunInMode", [ptr, C.c_double, C.c_ubyte], C.c_int32)
    default_run_loop_mode = ptr.in_dll(cf, "kCFRunLoopDefaultMode").value
    prop = bind(tis, "TISGetInputSourceProperty", [ptr, ptr], ptr)
    create_list = bind(tis, "TISCreateInputSourceList", [ptr, C.c_ubyte], ptr)
    current = bind(tis, "TISCopyCurrentKeyboardInputSource", [], ptr)
    ls_register = bind(ls, "LSRegisterURL", [ptr, C.c_ubyte], status)
    tis_register = bind(tis, "TISRegisterInputSource", [ptr], status)
    enable = bind(tis, "TISEnableInputSource", [ptr], status)
    disable = bind(tis, "TISDisableInputSource", [ptr], status)
    select = bind(tis, "TISSelectInputSource", [ptr], status)
    keys = {name: ptr.in_dll(tis, name).value for name in (
        "kTISPropertyInputSourceID", "kTISPropertyBundleID", "kTISPropertyInputSourceIsEnabled")}

    def string_property(source, name):
        value = prop(source, keys[name]) if source else None
        if not value:
            return None
        buffer = C.create_string_buffer(4096)
        if not get_string(value, buffer, len(buffer), 0x08000100):
            raise RuntimeError("Unable to read a TIS string property")
        return buffer.value.decode("utf-8")

    with ExitStack() as owned:
        def keep(value):
            if value:
                owned.callback(release, value)
            return value

        def snapshot():
            array = keep(create_list(None, 1))
            if not array:
                raise RuntimeError("Unable to enumerate TIS input sources")
            modes = {}
            for i in range(array_count(array)):
                source = array_item(array, i)
                if string_property(source, "kTISPropertyBundleID") != BUNDLE_ID:
                    continue
                source_id = string_property(source, "kTISPropertyInputSourceID")
                if source_id not in MODES:
                    continue
                value = prop(source, keys["kTISPropertyInputSourceIsEnabled"])
                modes[source_id] = (source, bool(get_bool(value)) if value else False)
            return modes

        before = snapshot()
        enabled_before = {key for key, (_, enabled) in before.items() if enabled}
        expected_enabled = enabled_before or {BUNDLE_ID + ".Hans"}
        selected_before = keep(current())
        selected_id_before = string_property(selected_before, "kTISPropertyInputSourceID")
        if inspect_only:
            return {"protocolVersion": 1, "appPath": str(app), "bundleID": BUNDLE_ID,
                    "registeredModes": sorted(before), "enabledModes": sorted(enabled_before),
                    "selectedSource": selected_id_before}
        path = str(app).encode()
        url = keep(create_url(None, path, len(path), 1))
        if not url:
            raise RuntimeError("Unable to create registration URL")
        launch_status = ls_register(url, 1)
        input_status = tis_register(url) if launch_status == 0 else None
        restore_statuses = {}
        selection_status = None
        if launch_status == 0 and input_status == 0:
            for _ in range(40):
                modes = snapshot()
                for key, (source, enabled) in modes.items():
                    desired = key in expected_enabled
                    if enabled != desired and restore_statuses.get(key) != 0:
                        restore_statuses[key] = enable(source) if desired else disable(source)
                fresh = snapshot()
                if set(fresh) == MODES and {key for key, (_, value) in fresh.items() if value} == expected_enabled:
                    break
                run_loop(default_run_loop_mode, 0.05, 0)
            selected_now = keep(current())
            if selected_before and string_property(selected_now, "kTISPropertyInputSourceID") != selected_id_before:
                selection_status = select(selected_before)
                for _ in range(40):
                    if string_property(keep(current()), "kTISPropertyInputSourceID") == selected_id_before:
                        break
                    run_loop(default_run_loop_mode, 0.05, 0)
        after = snapshot()
        enabled_after = {key for key, (_, enabled) in after.items() if enabled}
        selected_id_after = string_property(keep(current()), "kTISPropertyInputSourceID")
        success = (launch_status == 0 and input_status == 0
                   and all(value == 0 for value in restore_statuses.values())
                   and selection_status in (None, 0) and set(after) == MODES
                   and expected_enabled == enabled_after and selected_id_before == selected_id_after)
        return {"protocolVersion": 1, "success": success, "appPath": str(app),
                "launchServicesStatus": launch_status, "textInputSourceStatus": input_status,
                "modeRestoreStatuses": restore_statuses, "selectionRestoreStatus": selection_status,
                "registeredModes": sorted(after), "enabledModesBefore": sorted(enabled_before),
                "expectedEnabledModes": sorted(expected_enabled),
                "enabledModesAfter": sorted(enabled_after), "selectedSourceBefore": selected_id_before,
                "selectedSourceAfter": selected_id_after, "legacyCompatibility": True}


def refresh_legacy_registration(app):
    return _registration(app)


def read_input_source_status(app):
    """Read the target bundle's TIS modes without changing any registration."""
    return _registration(app, inspect_only=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Read Squirrel's registered input modes without changing them")
    parser.add_argument("command", choices=["status"])
    parser.add_argument("app", type=Path)
    arguments = parser.parse_args()
    print(json.dumps(read_input_source_status(arguments.app), sort_keys=True))
