#!/usr/bin/env python3
"""Compile public iPad sources to arm64 iPhoneOS objects, without game content.

This is an object build only: it does not link an app, sign, install, run code,
run tests, or use a simulator. Both TOTK 1.4.3 display configurations compile
against the installed Apple SDK and checked-in production headers, without
stubs. Outputs and exact toolchain/command metadata go to --output.
"""

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parents[4]
TOTK = ROOT / "games/totk"
SOURCES = tuple(sorted((TOTK / "ios/Sources").glob("*.m"))) + (
    TOTK / "runtime/frontend_ios.m",
    TOTK / "runtime/gamepad.m",
)
PROFILES = {
    "v143-default": ["-DTOTK_GAME_V143=1"],
    "v143-display-settings": ["-DTOTK_GAME_V143=1", "-DTOTK_IOS_DISPLAY_SETTINGS=1"],
}


def capture(command, env=None):
    result = subprocess.run(command, env=env, cwd=ROOT, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
    if result.returncode:
        raise RuntimeError(f"{' '.join(map(str, command))}: {result.stderr.strip()}")
    return result.stdout.strip()


def version_tuple(value):
    match = re.match(r"\d+(?:\.\d+)*", value)
    parts = tuple(int(part) for part in match[0].split(".")) if match else ()
    return parts + (0,) * max(0, 2 - len(parts)) if parts else ()


def apple_toolchain(requested):
    """Use an explicit Xcode, or the newest supported installed stable Xcode."""
    if requested:
        candidates = [Path(requested)]
    elif os.environ.get("DEVELOPER_DIR"):
        candidates = [Path(os.environ["DEVELOPER_DIR"])]
    else:
        candidates = []
        try:
            candidates.append(Path(capture(["/usr/bin/xcode-select", "-p"])))
        except RuntimeError:
            pass
        candidates.extend(app / "Contents/Developer" for app in sorted(Path("/Applications").glob("Xcode*.app"))
                          if "beta" not in app.name.lower())
    found, errors, seen = [], [], set()
    for candidate in candidates:
        # Accept an .app path for convenience, as DEVELOPER_DIR does.
        if candidate.suffix == ".app":
            candidate /= "Contents/Developer"
        candidate = candidate.resolve()
        if not requested and not os.environ.get("DEVELOPER_DIR") and any(
                part.endswith(".app") and "beta" in part.lower() for part in candidate.parts):
            continue
        if candidate in seen:
            continue
        seen.add(candidate)
        env = dict(os.environ, DEVELOPER_DIR=str(candidate))
        try:
            sdk_version = capture(["/usr/bin/xcrun", "--sdk", "iphoneos", "--show-sdk-version"], env)
            xcode_version = capture(["/usr/bin/xcodebuild", "-version"], env)
            if version_tuple(sdk_version) < (26, 0):
                raise RuntimeError(f"iPhoneOS SDK {sdk_version} is older than required 26.0")
            xcode_match = re.search(r"^Xcode (\S+)", xcode_version, re.MULTILINE)
            xcode_number = version_tuple(xcode_match[1]) if xcode_match else ()
            if xcode_number < (26, 0):
                raise RuntimeError(f"Xcode 26 or later is required: {xcode_version}")
            sdk = capture(["/usr/bin/xcrun", "--sdk", "iphoneos", "--show-sdk-path"], env)
            clang = capture(["/usr/bin/xcrun", "--sdk", "iphoneos", "--find", "clang"], env)
            found.append((version_tuple(sdk_version), xcode_number, str(candidate), {
                "developer_dir": str(candidate), "xcode": xcode_version,
                "sdk": sdk, "sdk_version": sdk_version, "clang": clang,
                "clang_version": capture([clang, "--version"], env),
            }))
        except (RuntimeError, subprocess.TimeoutExpired) as error:
            errors.append(f"{candidate}: {error}")
    if not found:
        raise RuntimeError("An installed Xcode 26+ with iPhoneOS SDK 26+ is required. "
                           "No SDK is downloaded.\n" + "\n".join(errors))
    return max(found, key=lambda entry: entry[:3])[3]


def file_hash(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def compile_one(profile, defines, source, output, toolchain):
    relative = source.relative_to(ROOT)
    object_file = output / profile / relative.with_suffix(".o")
    object_file.parent.mkdir(parents=True, exist_ok=True)
    log_file = object_file.with_suffix(".log")
    command = [
        toolchain["clang"], "-target", "arm64-apple-ios26.0", "-isysroot", toolchain["sdk"],
        "-std=gnu11", "-fobjc-arc", "-fblocks", "-fmodules",
        f"-fmodules-cache-path={output / 'module-cache'}", "-O0", "-mcpu=apple-a15",
        "-Wall", "-Wextra", "-Werror=implicit-function-declaration",
        "-I", str(TOTK / "runtime"),
        "-I", str(TOTK / "third_party/d2r_gfx/gfx/nvn"),
        "-I", str(TOTK / "third_party/d2r_gfx/gfx/nvn/include"),
        "-I", str(TOTK / "ios/Sources"),
        *defines, "-c", str(source), "-o", str(object_file),
    ]
    env = dict(os.environ, DEVELOPER_DIR=toolchain["developer_dir"])
    started = time.monotonic()
    status = None
    with log_file.open("w") as log:
        try:
            result = subprocess.run(command, env=env, cwd=ROOT, stdout=log,
                                    stderr=subprocess.STDOUT, timeout=180)
            status = result.returncode
        except subprocess.TimeoutExpired:
            log.write("\nCompilation exceeded 180 seconds.\n")
        except OSError as error:
            log.write(f"\nCannot invoke compiler: {error}\n")
    record = {
        "profile": profile, "source": str(relative), "source_sha256": file_hash(source),
        "command": command, "returncode": status, "seconds": round(time.monotonic() - started, 3),
        "log": str(log_file.relative_to(output)), "success": status == 0,
    }
    if status == 0:
        record.update(object=str(object_file.relative_to(output)), object_sha256=file_hash(object_file),
                      object_bytes=object_file.stat().st_size)
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path, help="directory for objects, logs, and report.json")
    parser.add_argument("--jobs", type=int, default=4, help="parallel compiler processes (1 through 8)")
    parser.add_argument("--developer-dir", help="explicit installed Xcode .app or Contents/Developer directory")
    args = parser.parse_args()
    if not 1 <= args.jobs <= 8:
        parser.error("--jobs must be from 1 through 8")
    if sys.platform != "darwin":
        parser.error("iPhoneOS object compilation requires macOS and installed Xcode 26+; no simulator or SDK download is used")
    output = args.output.resolve()
    if output.exists() and (not output.is_dir() or any(output.iterdir())):
        parser.error("--output must be a new or empty directory; existing build outputs are not reused")
    if any(source.resolve().is_relative_to(output) for source in SOURCES):
        parser.error("--output must not contain production source files")
    output.mkdir(parents=True, exist_ok=True)
    report = {"kind": "iphoneos-object-compilation", "full_app_build": False,
              "linked": False, "signed": False, "executed": False,
              "tests_run": False, "simulator_used": False, "generated_header_stubs": False,
              "target": "arm64-apple-ios26.0", "jobs": args.jobs, "results": []}
    report_path = output / "report.json"
    try:
        report["revision"] = capture(["git", "rev-parse", "HEAD"])
        status_lines = capture(["git", "status", "--porcelain=v1"]).splitlines()
        report["tracked_dirty"] = any(not line.startswith("??") for line in status_lines)
        report["untracked_present"] = any(line.startswith("??") for line in status_lines)
        report["working_tree_clean"] = not status_lines
        toolchain = apple_toolchain(args.developer_dir)
        report["toolchain"] = toolchain
        print(f"{toolchain['xcode']}\niPhoneOS SDK {toolchain['sdk_version']}\nRevision {report['revision']}", flush=True)
        work = [(profile, defines, source) for profile, defines in PROFILES.items() for source in SOURCES]
        report["expected_object_count"] = len(work)
        with ThreadPoolExecutor(max_workers=args.jobs) as executor:
            futures = [executor.submit(compile_one, profile, defines, source, output, toolchain)
                       for profile, defines, source in work]
            for future in as_completed(futures):
                result = future.result()
                report["results"].append(result)
                print(f"{'COMPILED' if result['success'] else 'FAILED'} {result['profile']} {result['source']}", flush=True)
                if not result["success"]:
                    print((output / result["log"]).read_text(), flush=True)
        report["results"].sort(key=lambda result: (result["profile"], result["source"]))
        report["compiled_object_count"] = sum(result["success"] for result in report["results"])
        report["success"] = bool(work) and report["compiled_object_count"] == len(work)
    except (RuntimeError, OSError, subprocess.TimeoutExpired) as error:
        report.update(success=False, error=str(error))
        print(str(error), file=sys.stderr)
    finally:
        report_path.write_text(json.dumps(report, indent=2) + "\n")
    print(f"Object-build report: {report_path}", flush=True)
    return 0 if report["success"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
