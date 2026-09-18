#!/usr/bin/env python3
"""Validate package versions, changelogs, release tags, and Docker tag policy."""

import argparse
import re
import sys
from collections import namedtuple
from pathlib import Path


PVP_VERSION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$")
CHANGELOG_HEADING = re.compile(
    r"^##\s+(?P<label>Unreleased|[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)"
    r"(?:\s+--\s+(?P<status>.+))?\s*$"
)
RELEASE_DATE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
COMMIT_SHA = re.compile(r"^[0-9a-fA-F]{7,40}$")

PACKAGE_CONFIG = {
    "redis-client": {
        "cabal": Path("redis-client.cabal"),
        "changelog": Path("CHANGELOG.md"),
        "tag_prefix": "redis-client-v",
        "publishes_docker": True,
    },
    "hask-redis-mux": {
        "cabal": Path("hask-redis-mux") / "hask-redis-mux.cabal",
        "changelog": Path("hask-redis-mux") / "CHANGELOG.md",
        "tag_prefix": "hask-redis-mux-v",
        "publishes_docker": False,
    },
}


ChangelogEntry = namedtuple("ChangelogEntry", ["version", "status", "body"])
PackageState = namedtuple(
    "PackageState",
    ["package_name", "manifest_name", "version", "changelog", "config"],
)


def read_cabal_field(path, field_name):
    prefix = f"{field_name.lower()}:"
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.lower().startswith(prefix):
            return line.split(":", 1)[1].strip()
    raise ValueError(f"{path}: missing {field_name} field")


def read_top_changelog_entry(path):
    lines = path.read_text(encoding="utf-8").splitlines()
    for heading_index, line in enumerate(lines):
        if not line.startswith("## "):
            continue
        match = CHANGELOG_HEADING.fullmatch(line.strip())
        if match is None:
            raise ValueError(f"{path}: malformed top version heading {line.strip()!r}")
        body_lines = []
        for body_line in lines[heading_index + 1 :]:
            if body_line.startswith("## "):
                break
            body_lines.append(body_line)
        label = match.group("label")
        return ChangelogEntry(
            version=None if label == "Unreleased" else label,
            status=match.group("status"),
            body="\n".join(body_lines).strip(),
        )
    raise ValueError(f"{path}: missing version heading")


def package_state(root, package_name):
    config = PACKAGE_CONFIG[package_name]
    cabal_path = root / config["cabal"]
    changelog_path = root / config["changelog"]
    return PackageState(
        package_name=package_name,
        manifest_name=read_cabal_field(cabal_path, "name"),
        version=read_cabal_field(cabal_path, "version"),
        changelog=read_top_changelog_entry(changelog_path),
        config=config,
    )


def validate_package_state(state):
    failures = []
    if state.manifest_name != state.package_name:
        failures.append(
            f"{state.config['cabal']}: cabal name {state.manifest_name} "
            f"does not match expected package {state.package_name}"
        )
    if not PVP_VERSION.fullmatch(state.version):
        failures.append(f"{state.config['cabal']}: invalid version {state.version}")
    if state.changelog.version is None:
        failures.append(
            f"{state.config['changelog']}: top heading must name version "
            f"{state.version}; use '## {state.version} -- Unreleased' during development"
        )
    elif state.changelog.version != state.version:
        failures.append(
            f"{state.config['changelog']}: top changelog version "
            f"{state.changelog.version} does not match cabal version {state.version}"
        )
    if not state.changelog.body:
        failures.append(f"{state.config['changelog']}: top changelog entry is empty")
    return failures


def validate_repository(root):
    failures = []
    for package_name in PACKAGE_CONFIG:
        try:
            state = package_state(root, package_name)
        except ValueError as error:
            failures.append(str(error))
            continue
        failures.extend(validate_package_state(state))
    return failures


def release_state_from_tag(root, release_tag):
    matches = []
    for package_name, config in PACKAGE_CONFIG.items():
        if release_tag.startswith(config["tag_prefix"]):
            matches.append((package_name, release_tag[len(config["tag_prefix"]) :]))
    if len(matches) != 1:
        raise ValueError(
            f"release tag {release_tag} must match exactly one known prefix"
        )
    package_name, tag_version = matches[0]
    if not PVP_VERSION.fullmatch(tag_version):
        raise ValueError(f"release tag {release_tag} must end with X.Y.Z.W")
    return package_state(root, package_name), tag_version


def short_sha(commit_sha):
    if not COMMIT_SHA.fullmatch(commit_sha):
        raise ValueError("commit SHA must be 7-40 hexadecimal characters")
    return commit_sha.lower()[:12]


def validate_release_state(state, tag_version, release_tag):
    failures = validate_package_state(state)
    if tag_version != state.version:
        failures.append(
            f"release tag {release_tag} targets version {tag_version}, "
            f"but {state.config['cabal']} declares {state.version}"
        )

    status = state.changelog.status
    if state.changelog.version is None or (status and status.casefold() == "unreleased"):
        failures.append(
            f"{state.config['changelog']}: version {state.version} is still Unreleased"
        )
    elif status is None or RELEASE_DATE.fullmatch(status) is None:
        failures.append(
            f"{state.config['changelog']}: released version {state.version} "
            "must use a YYYY-MM-DD release date"
        )
    return failures


def validate_release(
    root, release_tag, commit_sha=None, docker_tags=(), allow_latest=False
):
    try:
        state, tag_version = release_state_from_tag(root, release_tag)
    except ValueError as error:
        return [str(error)]

    failures = validate_release_state(state, tag_version, release_tag)

    docker_tags = list(docker_tags)
    if state.config["publishes_docker"]:
        if commit_sha is None:
            failures.append(
                "redis-client releases must provide --commit-sha for Docker tag validation"
            )
            expected_sha_tag = None
        else:
            try:
                expected_sha_tag = "sha-" + short_sha(commit_sha)
            except ValueError as error:
                failures.append(str(error))
                expected_sha_tag = None

        expected_tags = {state.version}
        if expected_sha_tag is not None:
            expected_tags.add(expected_sha_tag)
        if allow_latest:
            expected_tags.add("latest")
        actual_tags = set(docker_tags)
        for missing_tag in sorted(expected_tags - actual_tags):
            failures.append(
                f"redis-client releases must publish Docker tag {missing_tag}"
            )
        for unexpected_tag in sorted(actual_tags - expected_tags):
            failures.append(
                f"redis-client release declared unexpected Docker tag {unexpected_tag}"
            )
        if len(docker_tags) != len(actual_tags):
            failures.append("redis-client release declared duplicate Docker tags")
        if "latest" in actual_tags and not allow_latest:
            failures.append(
                "Docker tag latest requires --allow-latest so only stable CLI releases move it"
            )
    else:
        if commit_sha is not None:
            failures.append(
                f"{state.package_name} releases must not declare a Docker commit SHA"
            )
        if docker_tags:
            failures.append(
                f"{state.package_name} releases must not declare Docker tags"
            )
        if allow_latest:
            failures.append(
                f"{state.package_name} releases must not request the Docker latest tag"
            )

    return failures


def release_notes(root, release_tag):
    state, tag_version = release_state_from_tag(root, release_tag)
    failures = validate_release_state(state, tag_version, release_tag)
    if failures:
        raise ValueError("\n".join(failures))
    return f"## {state.package_name} {tag_version}\n\n{state.changelog.body}\n"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).parents[1])
    parser.add_argument("--release-tag")
    parser.add_argument("--commit-sha")
    parser.add_argument("--docker-tag", action="append", default=[])
    parser.add_argument("--allow-latest", action="store_true")
    parser.add_argument("--write-release-notes", type=Path)
    args = parser.parse_args()

    root = args.root.resolve()
    notes = None
    if args.write_release_notes:
        if not args.release_tag:
            parser.error("--write-release-notes requires --release-tag")
        try:
            notes = release_notes(root, args.release_tag)
            failures = []
        except ValueError as error:
            failures = [str(error)]
    elif args.release_tag:
        failures = validate_release(
            root,
            args.release_tag,
            commit_sha=args.commit_sha,
            docker_tags=args.docker_tag,
            allow_latest=args.allow_latest,
        )
    else:
        failures = validate_repository(root)

    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1

    if args.write_release_notes:
        args.write_release_notes.write_text(notes, encoding="utf-8")

    if args.release_tag:
        print(f"Release metadata checks passed for {args.release_tag}.")
    else:
        print("Repository release metadata checks passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
