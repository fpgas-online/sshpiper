#!/usr/bin/env python3
"""Build and test the sshpiper packages on this machine, as deb.yml does.

    uv run --no-project packaging/local-build.py [--suites trixie bookworm] [--arch amd64]

from the root of a checkout of the `packaging` branch. Needs docker, git and
python3; nothing else is installed on the host. It:

1. clones (or updates) the upstream branch the package is built from
   (`[mirror] build` in .github/apt-packaging.toml) into tmp/src, from this
   repository's own copy of it, and mithro/apt-repo-action into
   tmp/apt-repo-action, for the shared version script;
2. gets each suite's version from that script, as the deb-version action does;
3. builds sshpiperd and the plugins (packaging/build.sh) and packages them
   for each suite (packaging/nfpm.sh), in a golang:<version>-bookworm
   container, <version> being the Go that upstream's go.mod names;
4. installs each suite's package in a clean debian:<suite> container and
   runs packaging/install-test.sh there (only for this machine's own
   architecture).

The packages are left in built-debs/<suite>/. Everything else it writes is
under tmp/ and dist/, which git ignores.

Standard library only.
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ACTION = "https://github.com/mithro/apt-repo-action.git"
MIRROR = "https://github.com/fpgas-online/sshpiper.git"
GOARCH = {"amd64": "amd64", "arm64": "arm64"}
DEBIAN_IMAGE = {"amd64": "amd64/debian", "arm64": "arm64v8/debian"}


def run(*args: str, cwd: Path = ROOT, capture: bool = False, env: dict | None = None) -> str:
    print("+", " ".join(args), flush=True)
    r = subprocess.run(args, cwd=cwd, text=True, env=env,
                       stdout=subprocess.PIPE if capture else None)
    if r.returncode != 0:
        sys.exit(f"local-build.py: {args[0]} failed ({r.returncode})")
    return r.stdout.strip() if capture else ""


def checkout(url: str, branch: str, dest: Path) -> None:
    """A plain clone of `branch` (with its history and tags: the version is
    git describe's) at its newest commit."""
    if not (dest / ".git").is_dir():
        dest.parent.mkdir(parents=True, exist_ok=True)
        run("git", "clone", "--branch", branch, url, str(dest))
        return
    run("git", "fetch", "--tags", "origin", branch, cwd=dest)
    run("git", "checkout", "--detach", "FETCH_HEAD", cwd=dest)


def main() -> None:
    decl = tomllib.loads((ROOT / ".github/apt-packaging.toml").read_text())
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--suites", nargs="+", default=decl["suites"], choices=decl["suites"])
    ap.add_argument("--arch", nargs="+", default=decl["architectures"], choices=sorted(GOARCH))
    ap.add_argument("--mirror", default=MIRROR,
                    help="where to clone the built branch from (default: %(default)s)")
    ap.add_argument("--no-test", action="store_true", help="build only")
    args = ap.parse_args()

    src, action = ROOT / "tmp/src", ROOT / "tmp/apt-repo-action"
    checkout(args.mirror, decl["mirror"]["build"], src)
    checkout(ACTION, "main", action)
    commit = run("git", "rev-parse", "HEAD", cwd=src, capture=True)

    def version(suite: str) -> str:
        return run("python3", str(action / "scripts/deb-version.py"), "--suite", suite,
                   "--owner-tag", "fpgasonline", "--upstream-dir", "tmp/src", capture=True)

    versions = {suite: version(suite) for suite in args.suites}
    # What sshpiperd --version reports: the suite-independent version, sid's.
    binary = version("sid")

    go = re.search(r"^go (\S+)$", (src / "go.mod").read_text(), re.M)
    if not go:
        sys.exit("local-build.py: tmp/src/go.mod names no Go version")
    image = f"golang:{go.group(1)}-bookworm"
    host = run("dpkg", "--print-architecture", capture=True)
    for d in ("tmp/go", "tmp/home", "dist", "built-debs"):
        (ROOT / d).mkdir(parents=True, exist_ok=True)
    for arch in args.arch:
        steps = [f"GOARCH={GOARCH[arch]} BINARY_VERSION='{binary}' sh packaging/build.sh tmp/src dist/{arch}"]
        steps += [f"ARCH={arch} sh packaging/nfpm.sh {suite} '{versions[suite]}'" for suite in args.suites]
        # As this user, so nothing under the checkout ends up owned by root,
        # and git accepts tmp/src as the user's own.
        run("docker", "run", "--rm", "--user", f"{os.getuid()}:{os.getgid()}",
            "-v", f"{ROOT}:/work", "-w", "/work",
            "-e", "HOME=/work/tmp/home", "-e", "GOPATH=/work/tmp/go", "-e", "GOCACHE=/work/tmp/go/cache",
            image, "sh", "-euc", "\n".join(steps))

    for suite in args.suites:
        for arch in args.arch:
            deb = ROOT / f"built-debs/{suite}/sshpiper_{versions[suite]}_{arch}.deb"
            if not deb.is_file():
                sys.exit(f"local-build.py: {deb} was not built")
            print(f"built {deb.relative_to(ROOT)}")
        if args.no_test:
            continue
        if host not in args.arch or host not in DEBIAN_IMAGE:
            print(f"no install test for {suite}: this machine is {host}, which wasn't built")
            continue
        # Only this machine's package: /debs holds every architecture's. The
        # image is Docker's per-architecture one (amd64/debian, the same
        # image debian:<suite> is on amd64): a local debian:<suite> tag may
        # have been left pointing at another architecture's image, which
        # docker then runs whatever --platform says.
        run("docker", "run", "--rm", "--platform", f"linux/{host}",
            "-v", f"{ROOT / 'built-debs' / suite}:/debs:ro",
            "-v", f"{ROOT / 'packaging/install-test.sh'}:/install-test.sh:ro",
            "-e", f"EXPECT_VERSION={binary}", "-e", f"EXPECT_COMMIT={commit}",
            f"{DEBIAN_IMAGE[host]}:{suite}", "sh", "-ec",
            f"apt-get update\napt-get install -y /debs/*_{host}.deb\nsh /install-test.sh")
    print("upstream commit built:", commit)
    for suite, v in versions.items():
        print(f"{suite}: sshpiper {v}")


if __name__ == "__main__":
    main()
