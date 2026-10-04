#!/bin/sh
# Package what packaging/build.sh built (dist/<arch>/) for one suite, with
# nfpm and the repository's nfpm.yaml:
#
#   ARCH=amd64 sh packaging/nfpm.sh <suite> <version>
#
# from the root of the packaging checkout. Writes
# built-debs/<suite>/sshpiper_<version>_<arch>.deb. The binaries are static,
# so every suite's package holds the same files; only the version differs
# (its ~deb<R> suffix), which is why each suite is packaged separately.
#
# nfpm itself is fetched once, at a pinned version and checksum, and unpacked
# under tmp/ (no root needed): needs curl, sha256sum and dpkg-deb.
set -eu

suite=${1:?usage: nfpm.sh <suite> <version>}
version=${2:?usage: nfpm.sh <suite> <version>}
: "${ARCH:?set ARCH, the Debian architecture of dist/<arch> (amd64, arm64)}"

NFPM_VERSION=2.47.0
host=$(dpkg --print-architecture)
case "$host" in
  amd64) sha256=3f1cf344bd0b57373ca55636a78c08b0491f7293d609a456a9ac3b0b150fda97 ;;
  arm64) sha256=27419eb382695a7942be8ad52259f3ec1854fad001b3ae4baed34ce39a223b97 ;;
  *) echo "nfpm.sh: no pinned nfpm for a $host host" >&2; exit 1 ;;
esac
tools=tmp/nfpm-$NFPM_VERSION-$host
if [ ! -x "$tools/usr/bin/nfpm" ]; then
  mkdir -p tmp
  curl -fsSL -o "$tools.deb" \
    "https://github.com/goreleaser/nfpm/releases/download/v$NFPM_VERSION/nfpm_${NFPM_VERSION}_$host.deb"
  echo "$sha256  $tools.deb" | sha256sum -c
  dpkg-deb -x "$tools.deb" "$tools"
fi

mkdir -p "built-debs/$suite"
root=$(pwd)
# In dist/<arch>: nfpm.yaml's contents are relative to it (nfpm expands
# ${ARCH} in `arch`, but not in a `src` path).
(cd "dist/$ARCH" &&
  ARCH=$ARCH VERSION=$version "$root/$tools/usr/bin/nfpm" package -p deb \
    -f "$root/nfpm.yaml" -t "$root/built-debs/$suite/")
deb="built-debs/$suite/sshpiper_${version}_$ARCH.deb"
dpkg-deb -f "$deb" Package Version Architecture
got=$(dpkg-deb -f "$deb" Version)
if [ "$got" != "$version" ]; then
  echo "nfpm.sh: $deb has version $got, not $version" >&2
  exit 1
fi
