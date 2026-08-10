#!/usr/bin/env python3
"""Validate that Xcode, README, changelog, and an optional release tag agree."""

import argparse
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "ios/Lillygram.xcodeproj/project.pbxproj"
CHANGELOG = ROOT / "CHANGELOG.md"
README = ROOT / "README.md"
SEMVER = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")


def fail(message: str) -> None:
    raise SystemExit(f"release metadata error: {message}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", help="Release tag to compare, for example v0.3.0")
    args = parser.parse_args()

    project = PROJECT.read_text()
    versions = re.findall(r"\bMARKETING_VERSION = ([^;]+);", project)
    builds = re.findall(r"\bCURRENT_PROJECT_VERSION = ([^;]+);", project)
    if len(versions) != 2 or len(set(versions)) != 1:
        fail(f"expected two identical MARKETING_VERSION values, got {versions}")
    if len(builds) != 2 or len(set(builds)) != 1:
        fail(f"expected two identical CURRENT_PROJECT_VERSION values, got {builds}")

    version = versions[0]
    if not SEMVER.fullmatch(version):
        fail(f"MARKETING_VERSION is not MAJOR.MINOR.PATCH: {version}")

    headings = re.findall(r"^## \[([^]]+)]", CHANGELOG.read_text(), re.MULTILINE)
    if not headings or headings[0] != version:
        fail(f"top changelog version must be {version}, got {headings[0] if headings else 'none'}")

    readme = README.read_text()
    if f"Current version: **{version}**" not in readme:
        fail(f"README current version is not {version}")

    if args.tag:
        tag_version = args.tag.removeprefix("refs/tags/").removeprefix("v")
        if tag_version != version:
            fail(f"tag {args.tag} does not match MARKETING_VERSION {version}")

    print(f"release metadata OK: version={version} local-build={builds[0]}")


if __name__ == "__main__":
    main()
