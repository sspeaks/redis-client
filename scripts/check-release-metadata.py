#!/usr/bin/env python3
"""Validate package versions, changelog headings, and release tag policy."""

import argparse
import re
import sys
from pathlib import Path


SEMVER = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$")
CHANGELOG_VERSION = re.compile(r"^##\s+([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)(?:\s+--.*)?$")
COMMIT_SHA = re.compile(r"^[0-9a-fA-F]{7,40}$")

PACKAGE_CONFIG = {
    "redis-client": {
        "cabal": Path("redis-client.cabal"),
        "changelog": Path("CHANGELOG.md"),
        "tag_prefix": "redis-client-v",
        "requires_docker_tags": True,
    },
    "hask-redis-mux": {
        "cabal": Path("hask-redis-mux") / "hask-redis-mux.cabal",
        "changelog": Path("hask-redis-mux") / "CHANGELOG.md",
        "tag_prefix": "hask-redis-mux-v",
        "requires_docker_tags": False,
    },
}


def read_cabal_field(path, field_name):
    prefix = f"{field_name.lower()}:"
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.lower().startswith(prefix):
            return line.split(":", 1)[1].strip()
    raise ValueError(f"{path}: missing {field_name} field")


def latest_changelog_version(path):
    for line in path.read_text(encoding="utf-8").splitlines():
        match = CHANGELOG_VERSION.match(line.strip())
        if match:
            return match.group(1)
    raise ValueError(f"{path}: missing version heading")


def package_state(root, package_name):
    config = PACKAGE_CONFIG[package_name]
    cabal_path = root / config["cabal"]
    changelog_path = root / config["changelog"]
    manifest_name = read_cabal_field(cabal_path, "name")
    version = read_cabal_field(cabal_path, "version")
    changelog_version = latest_changelog_version(changelog_path)
    return {
        "package_name": package_name,
        "manifest_name": manifest_name,
        "version": version,
        "changelog_version": changelog_version,
        "config": config,
    }


def validate_repository(root):
    failures = []
    for package_name in PACKAGE_CONFIG:
        try:
            state = package_state(root, package_name)
        except ValueError as error:
            failures.append(str(error))
            continue
        if state["manifest_name"] != package_name:
            failures.append(
                "{}: cabal name {} does not match expected package {}".format(
                    state["config"]["cabal"], state["manifest_name"], package_name
                )
            )
        if not SEMVER.fullmatch(state["version"]):
            failures.append(
                "{}: invalid version {}".format(
                    state["config"]["cabal"], state["version"]
                )
            )
        if state["version"] != state["changelog_version"]:
            failures.append(
                "{}: changelog version {} does not match cabal version {}".format(
                    state["config"]["changelog"],
                    state["changelog_version"],
                    state["version"],
                )
            )
    return failures


def release_state_from_tag(root, release_tag):
    matches = []
    for package_name, config in PACKAGE_CONFIG.items():
        if release_tag.startswith(config["tag_prefix"]):
            matches.append((package_name, release_tag[len(config["tag_prefix"]) :]))
    if len(matches) != 1:
        raise ValueError(
            "release tag {} must match exactly one known prefix".format(release_tag)
        )
    package_name, version = matches[0]
    if not SEMVER.fullmatch(version):
        raise ValueError(
            "release tag {} must end with X.Y.Z.W".format(release_tag)
        )
    state = package_state(root, package_name)
    state["release_tag"] = release_tag
    state["tag_version"] = version
    return state


def short_sha(commit_sha):
    if not COMMIT_SHA.fullmatch(commit_sha):
        raise ValueError("commit SHA must be 7-40 hexadecimal characters")
    return commit_sha.lower()[:12]


def validate_release(root, release_tag, commit_sha=None, docker_tags=(), allow_latest=False):
    failures = []
    try:
        state = release_state_from_tag(root, release_tag)
    except ValueError as error:
        return [str(error)]

    if state["version"] != state["changelog_version"]:
        failures.append(
            "{}: changelog version {} does not match cabal version {}".format(
                state["config"]["changelog"],
                state["changelog_version"],
                state["version"],
            )
        )
    if state["tag_version"] != state["version"]:
        failures.append(
            "release tag {} targets version {}, but {} declares {}".format(
                release_tag,
                state["tag_version"],
                state["config"]["cabal"],
                state["version"],
            )
        )

    docker_tags = list(docker_tags)
    if state["config"]["requires_docker_tags"]:
        if commit_sha is None:
            failures.append(
                "redis-client releases must provide --commit-sha for Docker tag validation"
            )
        else:
            try:
                expected_sha_tag = "sha-" + short_sha(commit_sha)
            except ValueError as error:
                failures.append(str(error))
                expected_sha_tag = None
            if state["version"] not in docker_tags:
                failures.append(
                    "redis-client releases must publish Docker tag {}".format(
                        state["version"]
                    )
                )
            if expected_sha_tag is not None and expected_sha_tag not in docker_tags:
                failures.append(
                    "redis-client releases must publish Docker tag {}".format(
                        expected_sha_tag
                    )
                )
        if "latest" in docker_tags and not allow_latest:
            failures.append(
                "Docker tag latest requires --allow-latest so it is only used intentionally"
            )
    elif docker_tags:
        failures.append(
            "{} releases must not declare Docker tags".format(state["package_name"])
        )

    return failures


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).parents[1])
    parser.add_argument("--release-tag")
    parser.add_argument("--commit-sha")
    parser.add_argument("--docker-tag", action="append", default=[])
    parser.add_argument("--allow-latest", action="store_true")
    args = parser.parse_args()

    root = args.root.resolve()
    if args.release_tag:
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

    if args.release_tag:
        print("Release metadata checks passed for {}.".format(args.release_tag))
    else:
        print("Repository release metadata checks passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
