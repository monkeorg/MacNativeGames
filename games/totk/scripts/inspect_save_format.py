#!/usr/bin/env python3
"""Inspect a local progress.sav candidate without editing it.

Independent reader based on published format facts in the MIT-licensed reference:
https://github.com/marcrobledo/savegame-editors/blob/450752f98876755944ea22eb457f4dc1468d79ea/zelda-totk/zelda-totk.js
License at the same revision:
https://github.com/marcrobledo/savegame-editors/blob/450752f98876755944ea22eb457f4dc1468d79ea/LICENSE

The reference identifies a 1.4.x family signature, not an exact 1.4.3 version.
Its wallet UI range is a reference policy, not a verified game-format limit.
This reader checks only that signature and the wallet record before the first
table terminator. It does not validate integrity or establish a valid game save.
There is no write path. Default JSON omits the path and wallet value; revealing
the value requires --show-private-value. Symlinks in the input path are refused.
"""
import argparse
import json
import os
from pathlib import Path
import stat
import struct
import sys


EXPECTED_SIZE = 2_307_856
EXPECTED_WORDS = (0x01020304, 0x0049E946, 0x0003C138)
TABLE_START = 0x28
RECORD_SIZE = 8
WALLET_HASH = 0xA77921D7
TERMINATOR_HASH = 0xA3DB7114
REFERENCE_UI_MAX_RUPEES = 999_999
LIMITATIONS = {
    "format_family": "TOTK 1.4.x candidate",
    "exact_game_version": "unverified",
    "integrity": "unverified",
    "game_save_validity": "not_established",
    "editing_enabled": False,
}


class InspectionError(ValueError):
    """A fixed, nonprivate refusal reason suitable for the JSON response."""


def inspect_save_bytes(data: bytes, *, show_private_value: bool = False) -> dict:
    """Return structural metadata only unless the caller opts into the value.

    This pure function accepts immutable bytes. Unknown records and everything
    after the first table terminator remain uninterpreted.
    """
    if not isinstance(data, bytes):
        raise InspectionError("immutable_bytes_required")
    if len(data) != EXPECTED_SIZE:
        raise InspectionError("unexpected_file_size")
    if struct.unpack_from("<III", data, 0) != EXPECTED_WORDS:
        raise InspectionError("unknown_signature")

    wallet = None
    wallet_record = None
    terminator = None
    for offset in range(TABLE_START, len(data), RECORD_SIZE):
        if offset + RECORD_SIZE > len(data):
            raise InspectionError("truncated_record")
        key, value = struct.unpack_from("<II", data, offset)
        if key == TERMINATOR_HASH:
            terminator = offset
            break
        if key == WALLET_HASH:
            if wallet_record is not None:
                raise InspectionError("duplicate_wallet_record")
            if value > REFERENCE_UI_MAX_RUPEES:
                raise InspectionError("wallet_outside_reference_ui_range")
            wallet_record, wallet = offset, value
    if terminator is None:
        raise InspectionError("missing_table_terminator")
    if wallet_record is None:
        raise InspectionError("missing_wallet_record")

    result = {
        **LIMITATIONS,
        "status": "structural_candidate",
        "signature": "reference_tuple_match",
        "size_bytes": len(data),
        "table_start": TABLE_START,
        "terminator_record_offset": terminator,
        "wallet_record_offset": wallet_record,
        "wallet_storage": "inline_u32_le",
        "wallet_reference_ui_range": [0, REFERENCE_UI_MAX_RUPEES],
    }
    if show_private_value:
        result["private_wallet_value"] = wallet
    return result


def _open_without_links(path: Path) -> int:
    """Open relative to directory descriptors so no path component follows a link."""
    if not hasattr(os, "O_NOFOLLOW") or not hasattr(os, "O_DIRECTORY") or os.open not in os.supports_dir_fd:
        raise InspectionError("safe_open_unavailable")
    parts = path.parts[1:] if path.is_absolute() else path.parts
    if not parts or "\x00" in os.fspath(path) or any(part == ".." for part in parts):
        raise InspectionError("unsupported_input_path")
    common = os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
    directory = os.open(path.anchor if path.is_absolute() else ".", common | os.O_DIRECTORY)
    try:
        for part in parts[:-1]:
            child = os.open(part, common | os.O_DIRECTORY, dir_fd=directory)
            os.close(directory)
            directory = child
        # Nonblocking open prevents a FIFO from blocking before fstat can refuse it.
        return os.open(parts[-1], common | os.O_NONBLOCK, dir_fd=directory)
    finally:
        os.close(directory)


def read_candidate(path: Path) -> bytes:
    """Read at most the expected length plus one byte, refusing metadata changes.

    Metadata checks bound ordinary concurrent-change detection; they do not
    provide a filesystem snapshot or validate the save's internal integrity.
    """
    descriptor = _open_without_links(path)
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise InspectionError("regular_file_required")
        if before.st_size != EXPECTED_SIZE:
            raise InspectionError("unexpected_file_size")
        data = bytearray()
        while len(data) < EXPECTED_SIZE + 1:
            chunk = os.read(descriptor, min(65_536, EXPECTED_SIZE + 1 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
        after = os.fstat(descriptor)
        if (before.st_size, before.st_mtime_ns, before.st_ctime_ns, before.st_nlink) != (
                after.st_size, after.st_mtime_ns, after.st_ctime_ns, after.st_nlink):
            raise InspectionError("file_changed_during_read")
        if len(data) != EXPECTED_SIZE:
            raise InspectionError("unexpected_file_size")
        return bytes(data)
    finally:
        os.close(descriptor)


class _JSONArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        # argparse's usual diagnostic echoes user arguments, which can be private paths.
        print(json.dumps({**LIMITATIONS, "status": "rejected", "reason": "invalid_arguments"}))
        raise SystemExit(2)


def main(argv=None) -> int:
    parser = _JSONArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="local progress.sav candidate; no links")
    parser.add_argument("--show-private-value", action="store_true",
                        help="explicitly include the wallet value for local comparison")
    args = parser.parse_args(argv)
    try:
        result = inspect_save_bytes(read_candidate(args.source), show_private_value=args.show_private_value)
    except InspectionError as error:
        print(json.dumps({**LIMITATIONS, "status": "rejected", "reason": str(error)}))
        return 1
    except OSError:
        print(json.dumps({**LIMITATIONS, "status": "rejected", "reason": "cannot_read_input_safely"}))
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
