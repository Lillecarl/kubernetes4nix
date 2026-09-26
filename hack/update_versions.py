#!/usr/bin/env python3
"""Regenerate versions.json.

Version support status comes from two files in kubernetes/website, the same
two that render https://kubernetes.io/releases/:

  * data/releases/schedule.yaml  -- currently maintained release series
  * data/releases/eol.yaml       -- end-of-life series and their last patch

The authoritative list of released patch versions comes from the git tags of
kubernetes/kubernetes. Every release is tagged vX.Y.Z, so the tags, and not a
curated page, are the exhaustive source. The public release buckets are not:
kubernetes-release stops at v1.30 and recent artifacts sit behind the private
bucket that dl.k8s.io serves.

Pins (source-archive and release-archive hashes) are carried over from the
existing file. A pin is computed only when it is absent, so a normal run over
an unchanged matrix downloads nothing.
"""

from __future__ import annotations

import argparse
import json
import re
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Final

import anyio
from anyio import to_thread

SCHEDULE_URL: Final = (
    "https://raw.githubusercontent.com/kubernetes/website/main/data/releases/schedule.yaml"
)
EOL_URL: Final = (
    "https://raw.githubusercontent.com/kubernetes/website/main/data/releases/eol.yaml"
)
RELEASES_GIT: Final = "https://github.com/kubernetes/kubernetes"
RELEASES_REMOTE: Final = RELEASES_GIT + ".git"

DEFAULT_PINS: Final = ("src", "client-amd64")

TAG_REF: Final = re.compile(r"^refs/tags/v(1\.\d+\.\d+)$")

UNPACKED: Final = frozenset({"src"})

LOCK: Final = anyio.Lock()


async def fetch_text(url: str) -> str:
    def _get() -> str:
        with urllib.request.urlopen(url, timeout=60) as response:
            return response.read().decode()

    return await to_thread.run_sync(_get)


async def yaml_to_json(text: str) -> Any:
    process = await anyio.run_process(
        ["yq", "-o=json", "-I=0", "."], input=text.encode(), check=False
    )
    if process.returncode != 0:
        raise RuntimeError(f"yq failed: {process.stderr.decode()}")
    return json.loads(process.stdout)


def version_key(version: str) -> tuple[int, int, int]:
    major, minor, patch = version.split(".")
    return int(major), int(minor), int(patch)


def minor_of(version: str) -> str:
    return ".".join(version.split(".")[:2])


def minor_key(minor: str) -> tuple[int, int]:
    major, series = minor.split(".")
    return int(major), int(series)


async def list_patches() -> dict[str, list[str]]:
    """Every released stable patch, grouped by release series."""
    process = await anyio.run_process(
        ["git", "ls-remote", "--tags", "--refs", RELEASES_REMOTE], check=True
    )
    grouped: dict[str, list[str]] = {}
    for line in process.stdout.decode().splitlines():
        _, _, ref = line.partition("\t")
        match = TAG_REF.match(ref)
        if match is None:
            continue
        version = match.group(1)
        grouped.setdefault(minor_of(version), []).append(version)

    for versions in grouped.values():
        versions.sort(key=version_key)
    return grouped


def artifact_url(strategy: str, version: str) -> str:
    if strategy == "src":
        return f"https://github.com/kubernetes/kubernetes/archive/refs/tags/v{version}.tar.gz"
    flavor, _, arch = strategy.partition("-")
    return (
        f"https://dl.k8s.io/release/v{version}/"
        f"kubernetes-{flavor}-linux-{arch}.tar.gz"
    )


async def prefetch(strategy: str, version: str, limiter: anyio.Semaphore) -> str:
    url = artifact_url(strategy, version)
    command = ["nix-prefetch-url"]
    if strategy in UNPACKED:
        command.append("--unpack")
    command.append(url)

    async with limiter:
        process = await anyio.run_process(command, check=False)
        if process.returncode != 0:
            raise RuntimeError(f"nix-prefetch-url {url}: {process.stderr.decode().strip()}")
        base32 = process.stdout.decode().strip()
        convert = await anyio.run_process(
            [
                "nix",
                "hash",
                "convert",
                "--hash-algo",
                "sha256",
                "--from",
                "nix32",
                "--to",
                "sri",
                base32,
            ],
            check=True,
        )
    return convert.stdout.decode().strip()


def load_existing(path: Path) -> dict[str, dict[str, str]]:
    """Pins from a previous run, keyed by version then strategy."""
    if not path.exists():
        return {}
    document = json.loads(path.read_text())
    pins: dict[str, dict[str, str]] = {}
    for release in document.get("releases", []):
        for patch in release.get("patches", []):
            pins[patch["version"]] = dict(patch.get("pins", {}))
    return pins


def build_releases(
    patches: dict[str, list[str]],
    schedule: dict[str, dict[str, Any]],
    eol: dict[str, dict[str, Any]],
) -> list[dict[str, Any]]:
    minors = sorted(
        set(patches) | set(schedule) | set(eol), key=minor_key, reverse=True
    )
    releases: list[dict[str, Any]] = []
    for minor in minors:
        series = schedule.get(minor, {})
        dead = eol.get(minor, {})
        supported = minor in schedule
        series_patches = patches.get(minor, [])
        releases.append(
            {
                "minor": minor,
                "supported": supported,
                "releaseDate": series.get("releaseDate"),
                "endOfLifeDate": series.get("endOfLifeDate") or dead.get("endOfLifeDate"),
                "maintenanceModeStartDate": series.get("maintenanceModeStartDate"),
                "finalPatchRelease": dead.get("finalPatchRelease"),
                "latest": series_patches[-1] if series_patches else None,
                "patches": (
                    [{"version": version, "pins": {}} for version in series_patches]
                    if supported
                    else []
                ),
            }
        )
    return releases


async def compute_pins(
    releases: list[dict[str, Any]],
    strategies: list[str],
    existing: dict[str, dict[str, str]],
    jobs: int,
) -> None:
    limiter = anyio.Semaphore(jobs)
    work: list[tuple[str, str]] = []
    for release in releases:
        for patch in release["patches"]:
            version = patch["version"]
            held = existing.get(version, {})
            for strategy in strategies:
                if strategy not in held:
                    work.append((version, strategy))

    computed: dict[tuple[str, str], str] = {}

    async def run_one(version: str, strategy: str) -> None:
        pin = await prefetch(strategy, version, limiter)
        async with LOCK:
            computed[(version, strategy)] = pin
            print(f"pinned {strategy} {version} {pin}", flush=True)

    async with anyio.create_task_group() as group:
        for version, strategy in work:
            group.start_soon(run_one, version, strategy)

    for release in releases:
        for patch in release["patches"]:
            version = patch["version"]
            pins = dict(existing.get(version, {}))
            for strategy in strategies:
                if (version, strategy) in computed:
                    pins[strategy] = computed[(version, strategy)]
            patch["pins"] = pins


async def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output", type=Path, default=Path(__file__).resolve().parent.parent / "versions.json"
    )
    parser.add_argument(
        "--pins",
        default=",".join(DEFAULT_PINS),
        help="comma-separated strategies to pin, or empty to leave pins untouched",
    )
    parser.add_argument("--jobs", type=int, default=8)
    args = parser.parse_args()

    schedule = (await yaml_to_json(await fetch_text(SCHEDULE_URL))).get("schedules", [])
    schedule = {entry["release"]: entry for entry in schedule}
    eol = (await yaml_to_json(await fetch_text(EOL_URL))).get("branches", [])
    eol = {entry["release"]: entry for entry in eol}

    releases = build_releases(await list_patches(), schedule, eol)
    strategies = [s for s in args.pins.split(",") if s]
    existing = load_existing(args.output)
    await compute_pins(releases, strategies, existing, args.jobs)

    document = {
        "generated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "sources": {
            "schedule": SCHEDULE_URL,
            "eol": EOL_URL,
            "releases": RELEASES_GIT,
        },
        "strategies": sorted(
            {
                strategy
                for release in releases
                for patch in release["patches"]
                for strategy in patch["pins"]
            }
        ),
        "releases": releases,
    }
    args.output.write_text(json.dumps(document, indent=2, sort_keys=False) + "\n")
    supported = [r for r in releases if r["supported"]]
    total = sum(len(r["patches"]) for r in supported)
    print(f"wrote {args.output}: {len(supported)} supported series, {total} patches")
    return 0


if __name__ == "__main__":
    raise SystemExit(anyio.run(main))
