# sshpiper, packaged for Debian

A mirror repository in the sense of mithro/apt-repo-action's
[docs/packaging.md](https://github.com/mithro/apt-repo-action/blob/main/docs/packaging.md)
("Mirrors"). It keeps an exact copy of [sshpiper](https://github.com/tg123/sshpiper),
the SSH reverse proxy that routes by user name, and builds it as the Debian
package `sshpiper`, to be published as a signed apt repository at
<https://fpgas.online/sshpiper/>. sshpiper's own code is built unchanged; one
fix of ours is applied to the crypto module it links
([What the packaging changes](#what-the-packaging-changes)).

fpgas.online uses it on a site's gateway, so that
`ssh <board>@<board>.<site>` reaches the right board over IPv4
([fpgas.online-infra issue 191](https://github.com/fpgas-online/fpgas.online-infra/issues/191),
[apt issue 21](https://github.com/fpgas-online/apt/issues/21)).

Nothing here is ever sent to upstream: issues and pull requests for the
packaging belong in this repository, against `packaging`.

## Branches

| branch | what | history |
|---|---|---|
| `packaging` | `nfpm.yaml`, `packaging/` and `.github/`: the build and the sync. No sshpiper source. | its own, unrelated to sshpiper's |
| `master` (and every other upstream branch, and upstream's `v*` tags) | an exact copy of github.com/tg123/sshpiper's branch or tag of the same name | upstream's |

Nothing is ever committed to a mirrored branch. Changes to how sshpiper is
packaged are pull requests against `packaging`.

This repository is a GitHub fork of tg123/sshpiper, so GitHub offers upstream
as the target of a new pull request: choose `fpgas-online/sshpiper` and the
base `packaging`. With `gh`, always pass `--repo fpgas-online/sshpiper`.

## The package

| path | what |
|---|---|
| `/usr/sbin/sshpiperd` | the daemon |
| `/usr/lib/sshpiper/plugins/<name>` | upstream's plugins, one program each: `failtoban`, `fixed`, `lua`, `username-router`, `workingdir`, `yaml` (the set upstream ships in its own Linux package, the snap) |
| `/usr/share/doc/sshpiper/copyright` | upstream's licence (MIT), and the upstream commit the package was built from |

No systemd unit and no configuration: whatever deploys it owns those (for
fpgas.online, the infra repository's ssh proxy role). `sshpiperd` takes each
plugin as a path on its command line:

```sh
sshpiperd --server-key /etc/ssh/ssh_host_ed25519_key --drop-hostkeys-message \
  /usr/lib/sshpiper/plugins/yaml --config /etc/sshpiper/config.yaml
```

The programs are statically linked Go (`CGO_ENABLED=0`), so the package
depends on nothing and every suite's package holds the same files. It is built
for amd64 and arm64, the two architectures upstream releases for Linux.

`sshpiperd --version` reports the package's version, the upstream commit and
the Go it was built with.

## How it is built

`packaging/build.sh` builds an unmodified checkout of `master` the way
upstream's release does (its `.goreleaser.yaml`):
- `sshpiperd` from `cmd/sshpiperd`, which is a Go module of its own: its
  `go.mod` replaces `golang.org/x/crypto` with upstream's patched
  `github.com/tg123/sshpiper.crypto`, so that fork is fetched by Go at the
  version upstream pinned (upstream no longer uses git submodules). Our
  patches to that module are applied to a copy of it, and `sshpiperd` is
  built in a Go workspace of `cmd/sshpiperd` and the copy; the workspace file
  is outside the checkout, which stays exactly upstream's;
- each plugin from `./plugin/<name>` with the build tag `full`;
- everything with `CGO_ENABLED=0 -trimpath -ldflags "-s -w"`, and the version
  in `main.mainver`.

`packaging/nfpm.sh` then packages the result once per suite with
[nfpm](https://nfpm.goreleaser.com/) and `nfpm.yaml` (the shared convention
for Go programs: no `debian/` directory). Every packaged file carries the
packaging commit's time, so building the same two commits again gives the
same package, byte for byte.

Upstream's own test suite is not run here: upstream's CI tests each commit.
What this repository tests is what it adds, the package and our patch (the
install test below).

## How it runs

- **Sync upstream** (`.github/workflows/sync-upstream.yml`, daily and on
  demand) calls mithro/apt-repo-action's shared mirror sync
  (`sync-mirror.yml`), driven by `.github/apt-packaging.toml`. It copies every
  branch and tag of github.com/tg123/sshpiper here under the same name,
  forced, so each is always identical to upstream's. `packaging` and its tags
  are never touched, and nothing is ever deleted. When `master` moved, it
  starts **Debian packages**.
- **Debian packages** (`.github/workflows/deb.yml`, on every push to
  `packaging`, when Sync upstream starts it, and on pull requests without
  publishing) checks out `master` into `src/`, builds it for amd64 and arm64,
  packages it for bookworm, trixie, forky and sid, runs the install test on
  each, and publishes through mithro/apt-repo-action's `publish-apt.yml`.

A new upstream commit is then published the day it lands, with no review.

The install test (`packaging/install-test.sh`) installs the package in a
clean container of each suite, checks its files, `sshpiperd --version` and
every plugin, and then makes a real login: an OpenSSH client connects to
`sshpiperd` running the `fixed` plugin with an explicit Ed25519
`--server-key` and `--drop-hostkeys-message`, and must land in a session of a
throwaway `sshd` behind it, having verified sshpiperd's host key and without
being sent the sshd's own.

### Settings this needs

The sync and the publish only work once the repository is set up as a mirror
(docs/packaging.md, "Repository settings"); until then **Debian packages**
builds and tests on every push to `packaging` and publishes nothing:

- the default branch is `packaging` (scheduled workflows run only from the
  default branch, the sync reads the declaration from it, and `publish-apt`
  refuses any other branch);
- Pages is built from GitHub Actions, with HTTPS enforced;
- the secret `APT_GPG_PRIVATE_KEY` holds this repository's own signing key;
- the secret `MIRROR_TOKEN` holds a token with Contents and Workflows write:
  upstream's branches carry `.github/workflows/` files, which the workflow's
  own token may not push;
- upstream's own workflows (`benchmark.yml`, `e2e.yml`, `gofumpt.yml`,
  `release.yaml`, `test.yml` on the mirrored branches) are disabled here: a
  push made with `MIRROR_TOKEN` would otherwise start them.

## Versions

apt-repo-action's shared `scripts/deb-version.py` (mirror form): upstream's
version, then ours.

```
1.6.1.post14+fpgasonline.0.0.post5~deb13
^^^^^^^^^^^^             ^^^^^^^^^ ^^^^^
|                        |         suite (none on sid); ~pr<P> on previews
|                        this branch: 5 commits after v0.0
upstream: 14 commits after its v1.6.1 tag
```

Either a new upstream commit or a new packaging commit raises it. No dates.

## What the packaging changes

Nothing in sshpiper's own repository: `master` is built as it is. One patch
is applied to the Go module `sshpiperd` links for SSH, upstream's
`github.com/tg123/sshpiper.crypto` (a patched `golang.org/x/crypto`, pinned
in `cmd/sshpiperd/go.mod`). That module is not in this repository, so the
patch is a file here, applied by `packaging/build.sh` on every build; a patch
that no longer applies exactly fails the build.

| patch | what |
|---|---|
| `packaging/patches/sshpiper.crypto/0001-close-onward-connection-when-login-fails.patch` | sshpiperd makes a new connection to the upstream server for every authentication attempt of a client, and never closed one whose authentication failed. Every wrong password through the proxy left an unauthenticated connection at the upstream sshd until that sshd's `LoginGraceTime` (120 s), each holding one of its `MaxStartups` slots: a dozen wrong passwords shut real logins out. The patch closes the upstream connection when its authentication fails, and when the client goes away, or never proves it holds an offered public key, after a callback had already authenticated upstream. A client's retries in one connection are unaffected: each attempt gets a new upstream connection, as before. |

The patch file's header has the details and how it is tested: the install
test sends 12 wrong passwords through `sshpiperd` and then requires that no
connection is left open at the backend sshd, that a wrong password followed by
the right one in one connection logs in, and that one connection gets its
three attempts.

Every published version is a patched one, and the version says so in its
`+fpgasonline.<X.Y.postN>` half: a change to a patch is a commit to
`packaging`, which raises it. `/usr/share/doc/sshpiper/copyright` lists the
patches a package was built with. Nothing here is offered to or filed with
upstream.

Related, for whoever deploys it: every login through sshpiperd reaches the
upstream sshd from sshpiperd's address. OpenSSH 9.8 and later penalise an
address after failed logins (`PerSourcePenalties`), so an upstream sshd needs
the proxy's address in its `PerSourcePenaltyExemptList`, or a few wrong
passwords by anyone shut everyone's proxied logins out for a while.

A change of ours to sshpiper's own code goes on a patch branch, never into a
mirrored branch (docs/packaging.md, "Our own patches on a mirror"): our
commits on `patches/<topic>`, on top of a commit of `master`, pinned in
`.github/apt-packaging.toml` as `[[mirror.patches]]`, and applied to `src/` by
the build. The first one planned is phase 2 of the ssh proxy
([fpgas.online-infra issue 190](https://github.com/fpgas-online/fpgas.online-infra/issues/190)):
an opt-in flag that makes sshpiperd dial the upstream from the client's own
address (`IP_TRANSPARENT`), so that boards see the real source of a proxied
login. It would be `patches/ip-transparent`. It is not written yet, and
neither is the step of this build that applies patch branches (the shared
tooling generates a quilt series for `dpkg-buildpackage`; an nfpm build has to
apply the pinned commits itself, and fail if one doesn't apply).

## Building locally

Needs docker, git and python3 (with [uv](https://docs.astral.sh/uv/), or run
the script with `python3`).

```sh
git clone --branch packaging https://github.com/fpgas-online/sshpiper.git
cd sshpiper
uv run --no-project packaging/local-build.py --suites trixie --arch amd64
```

It clones `master` into `tmp/src`, builds in a `golang` container of the Go
version upstream's `go.mod` names, leaves the packages in
`built-debs/<suite>/` and runs the install test in a clean `debian:<suite>`
container. Without options it builds every suite and both architectures.

## Install

Not published yet: the apt repository appears at <https://fpgas.online/sshpiper/>
with the first publish, and its key's fingerprint goes here then.

```sh
sudo install -d -m0755 /etc/apt/keyrings
curl -fsSL https://fpgas.online/sshpiper/sshpiper.gpg | sudo tee /etc/apt/keyrings/sshpiper.gpg > /dev/null
echo "deb [signed-by=/etc/apt/keyrings/sshpiper.gpg] https://fpgas.online/sshpiper/trixie/ ./" \
  | sudo tee /etc/apt/sources.list.d/sshpiper.list
sudo apt update
sudo apt install sshpiper
```

For another suite, replace `trixie` with `bookworm`, `forky` or `sid`.

## Licence

sshpiper is MIT licensed (Boshi Lian); see `LICENSE` on `master`. The
packaging here is under the same licence.
