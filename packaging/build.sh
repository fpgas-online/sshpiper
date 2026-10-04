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
# are. Nothing in the checkout is changed. The one thing that differs from
# upstream's release: sshpiperd is linked against a copy of that crypto
# module with the patches in packaging/patches/sshpiper.crypto/ applied.
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

# Our patches to the patched crypto module (packaging/patches/sshpiper.crypto/,
# see the README). It is a Go module that Go fetches, not part of the
# checkout, so: copy the version cmd/sshpiperd/go.mod pins out of the module
# cache, apply every patch (any that doesn't apply exactly fails the build),
# and build sshpiperd in a Go workspace of cmd/sshpiperd and that copy. The
# workspace file lives outside the checkout, which stays as upstream's.
patches=$(cd "$(dirname "$0")" && pwd)/patches/sshpiper.crypto
work="$out.work"
rm -rf "$work"
mkdir -p "$work"
applied=
if ls "$patches"/*.patch > /dev/null 2>&1; then
  (cd "$src/cmd/sshpiperd" && go mod download golang.org/x/crypto)
  module=$(cd "$src/cmd/sshpiperd" &&
    go list -m -f '{{if .Replace}}{{.Replace.Path}} {{.Replace.Version}} {{.Replace.Dir}}{{end}}' golang.org/x/crypto)
  crypto_name=${module% *}
  crypto_dir=${module##* }
  case "$crypto_name" in
    "github.com/tg123/sshpiper.crypto "*) ;;
    *) echo "build.sh: cmd/sshpiperd/go.mod no longer replaces golang.org/x/crypto with github.com/tg123/sshpiper.crypto (got \"$module\"): the patches are for that module" >&2; exit 1 ;;
  esac
  [ -f "$crypto_dir/ssh/sshpiper.go" ] || { echo "build.sh: no ssh/sshpiper.go in $crypto_dir" >&2; exit 1; }
  cp -r "$crypto_dir" "$work/crypto"
  chmod -R u+w "$work/crypto"
  # git apply: exact (no fuzz), all of a patch or none of it, and git is
  # needed here anyway. In a repository of the copy's own, so the paths in a
  # patch are the module's whatever repository the output directory is in.
  git -C "$work/crypto" init -q
  for p in "$patches"/*.patch; do
    echo "applying $(basename "$p") to $crypto_name"
    git -C "$work/crypto" apply --verbose "$p"
    applied="$applied $(basename "$p")"
  done
  rm -rf "$work/crypto/.git"
  {
    sed -n 's/^go /go /p' "$src/cmd/sshpiperd/go.mod"
    echo "use $src/cmd/sshpiperd"
    echo "use $work/crypto"
  } > "$work/go.work"
  export GOWORK="$work/go.work"
fi

(cd "$src/cmd/sshpiperd" &&
  go build -trimpath -ldflags "-s -w -X main.mainver=$BINARY_VERSION" -o "$out/sshpiperd" .)
# The plugins are the root module's, which links upstream golang.org/x/crypto.
unset GOWORK
rm -rf "$work"
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
# And it was linked against the patched copy, which Go records as a
# development version, not against the module go.mod pins.
if [ -n "$applied" ] && ! printf '%s\n' "$stamp" | grep -q "dep[[:space:]]golang.org/x/crypto[[:space:]](devel)"; then
  echo "build.sh: $out/sshpiperd was not linked against the patched golang.org/x/crypto:" >&2
  printf '%s\n' "$stamp" | grep crypto >&2
  exit 1
fi

{
  cat <<EOF
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: sshpiper
Upstream-Contact: Boshi Lian (https://github.com/tg123)
Source: https://github.com/tg123/sshpiper
Comment: Built from upstream commit
 $commit
 ($describe), unchanged, by https://github.com/fpgas-online/sshpiper (branch
 packaging). The Go modules linked in (go.sum, cmd/sshpiperd/go.sum at that
 commit) keep their own licences.
 .
 sshpiperd is linked against ${crypto_name:-the golang.org/x/crypto its go.mod pins}
 with these patches from that branch's packaging/patches/sshpiper.crypto/:
 ${applied:- none}

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
