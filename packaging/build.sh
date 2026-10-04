#!/bin/sh
# Build sshpiperd and the packaged plugins from an upstream checkout, the way
# upstream's own release does (.goreleaser.yaml on master):
#
#   sshpiperd   in cmd/sshpiperd (a Go module of its own, whose go.mod
#               replaces golang.org/x/crypto with upstream's patched
#               github.com/tg123/sshpiper.crypto), CGO_ENABLED=0, -trimpath,
#               -ldflags "-s -w -X main.mainver=<version>"
#   plugins     ./plugin/<name> in the root module, CGO_ENABLED=0, -trimpath,
#               -ldflags "-s -w", -tags full
#
# goreleaser's `go mod tidy` hooks are left out on purpose: they may rewrite
# go.mod and go.sum, and the package is built from upstream's files as they
# are. Nothing in the checkout is changed.
#
#   GOARCH=amd64 BINARY_VERSION=1.6.1.post14+fpgasonline.0.0 \
#     sh packaging/build.sh <upstream checkout> <output directory>
#
# Writes <output>/sshpiperd, <output>/plugins/<name> and <output>/copyright.
# Needs go (the version upstream's go.mod names: no toolchain is downloaded)
# and git. The checkout must be a git clone, unmodified: Go stamps the
# binaries with its commit, which `sshpiperd --version` prints.
set -eu

src=${1:?usage: build.sh <upstream checkout> <output directory>}
out=${2:?usage: build.sh <upstream checkout> <output directory>}
: "${GOARCH:?set GOARCH (amd64, arm64)}"
: "${BINARY_VERSION:?set BINARY_VERSION, the version sshpiperd --version reports}"

# The plugins upstream ships in its own Linux package (the snap in
# .goreleaser.yaml). docker and kubernetes are left out: they are for
# container hosts, and each links a whole client library.
PLUGINS=${PLUGINS:-failtoban fixed lua username-router workingdir yaml}

mkdir -p "$out/plugins"
out=$(cd "$out" && pwd)
src=$(cd "$src" && pwd)

export CGO_ENABLED=0 GOOS=linux GOARCH
# The go on PATH must be new enough for upstream's go.mod: fail, don't fetch
# another toolchain.
export GOTOOLCHAIN=local
# Fail unless the commit can be stamped into the binaries.
export GOFLAGS=-buildvcs=true

commit=$(git -C "$src" rev-parse HEAD)
describe=$(git -C "$src" describe --tags --long --match 'v[0-9]*')
if [ -n "$(git -C "$src" status --porcelain)" ]; then
  echo "build.sh: $src has local changes; the package is built from upstream's files as they are" >&2
  git -C "$src" status --short >&2
  exit 1
fi
echo "building sshpiper $describe ($commit) for linux/$GOARCH as $BINARY_VERSION with $(go version)"

(cd "$src/cmd/sshpiperd" &&
  go build -trimpath -ldflags "-s -w -X main.mainver=$BINARY_VERSION" -o "$out/sshpiperd" .)
for p in $PLUGINS; do
  (cd "$src" &&
    go build -trimpath -ldflags "-s -w" -tags full -o "$out/plugins/$p" "./plugin/$p")
done

# The commit really is in the binary, and the tree it was built from clean.
stamp=$(go version -m "$out/sshpiperd")
for want in "vcs.revision=$commit" "vcs.modified=false"; do
  if ! printf '%s\n' "$stamp" | grep -q "$want"; then
    echo "build.sh: $out/sshpiperd is not stamped with $want" >&2
    exit 1
  fi
done

{
  cat <<EOF
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: sshpiper
Upstream-Contact: Boshi Lian (https://github.com/tg123)
Source: https://github.com/tg123/sshpiper
Comment: Built unchanged from upstream commit
 $commit
 ($describe) by https://github.com/fpgas-online/sshpiper (branch packaging).
 The Go modules linked in (go.sum, cmd/sshpiperd/go.sum at that commit) keep
 their own licences.

Files: *
Copyright: 2014 Boshi Lian
License: Expat

License: Expat
EOF
  # upstream's LICENSE, as a copyright-format paragraph: its text after the
  # title and copyright lines, indented, with " ." for an empty line.
  sed -n '/^Permission is hereby granted/,$p' "$src/LICENSE" | sed -e 's/^$/./' -e 's/^/ /'
} > "$out/copyright"
if ! grep -q "Permission is hereby granted" "$out/copyright"; then
  echo "build.sh: $src/LICENSE is no longer the MIT text this script expects" >&2
  exit 1
fi

ls -l "$out" "$out/plugins"
