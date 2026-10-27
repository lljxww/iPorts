#!/usr/bin/env python3
"""Validate release versions and stamp only the staged application bundle."""

import argparse
import plistlib
import re
from pathlib import Path


def parse_version(version):
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version):
        raise ValueError("Version must be MAJOR.MINOR.PATCH, without leading zeroes or suffixes")
    components = tuple(int(part) for part in version.split("."))
    if any(part > limit for part, limit in zip(components, (9999, 99, 99))):
        raise ValueError("Version exceeds CFBundleVersion limits (9999.99.99)")
    return components


def version_from_tag(tag):
    if not tag.startswith("v"):
        raise ValueError("Release tag must start with v, for example v1.2.3")
    version = tag[1:]
    parse_version(version)
    return version


def set_version(plist_path, version):
    parse_version(version)
    with plist_path.open("rb") as source:
        metadata = plistlib.load(source)
    metadata["CFBundleShortVersionString"] = version
    metadata["CFBundleVersion"] = version
    with plist_path.open("wb") as destination:
        plistlib.dump(metadata, destination, sort_keys=False)


def should_be_latest(tag, latest_tag):
    version = parse_version(version_from_tag(tag))
    return not latest_tag or version > parse_version(version_from_tag(latest_tag))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    validate = commands.add_parser("validate-tag")
    validate.add_argument("tag")
    stamp = commands.add_parser("set-version")
    stamp.add_argument("plist", type=Path)
    stamp.add_argument("version")
    latest = commands.add_parser("is-latest")
    latest.add_argument("tag")
    latest.add_argument("latest_tag", nargs="?", default="")
    arguments = parser.parse_args()
    try:
        if arguments.command == "validate-tag":
            print(version_from_tag(arguments.tag))
        elif arguments.command == "set-version":
            set_version(arguments.plist, arguments.version)
        elif arguments.command == "is-latest":
            print(str(should_be_latest(arguments.tag, arguments.latest_tag)).lower())
    except ValueError as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
