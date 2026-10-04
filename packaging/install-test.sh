#!/bin/sh
# Install test (mithro/apt-repo-action docs/packaging.md, "Builds"): run as
# root in a clean debian:<suite> container after the built sshpiper package
# was installed there with apt.
#
# 1. The package: its files, no service and no configuration, the version
#    and upstream commit sshpiperd reports, every plugin runs.
# 2. A real login through it: an OpenSSH client connects to sshpiperd, which
#    runs the `fixed` plugin with an explicit --server-key and
#    --drop-hostkeys-message (how fpgas.online's gateway runs it), and is
#    piped to a throwaway sshd in the same container. The client must have
#    been shown sshpiperd's host key, must land in a session of that sshd,
#    and must not be sent the sshd's own host keys.
#
# EXPECT_VERSION (the version built into sshpiperd) and EXPECT_COMMIT (the
# upstream commit) are checked when set.
#
# sshpiper is statically linked and depends on nothing, so the OpenSSH
# packages this test installs can't change anything it runs with.
set -eu
export DEBIAN_FRONTEND=noninteractive

PLUGIN_DIR=/usr/lib/sshpiper/plugins
PLUGINS="failtoban fixed lua username-router workingdir yaml"
BACKEND_PORT=2201
PROXY_PORT=2202

fail() {
  echo "install-test: FAIL: $*" >&2
  exit 1
}

# In the container, which is thrown away with everything in it.
d=$(mktemp -d)

echo "== the package"
dpkg-query -W -f 'sshpiper ${Version} ${Architecture} ${Status}\n' sshpiper
dpkg -L sshpiper
if dpkg -L sshpiper | grep -E '^/etc(/|$)|systemd|/init\.d/'; then
  fail "the package ships configuration or a service (the lines above); it must not"
fi
[ "$(command -v sshpiperd)" = /usr/sbin/sshpiperd ] || fail "sshpiperd is not /usr/sbin/sshpiperd"
[ -s /usr/share/doc/sshpiper/copyright ] || fail "no /usr/share/doc/sshpiper/copyright"

echo "== sshpiperd --version"
reported=$(sshpiperd --version)
echo "$reported"
if [ -n "${EXPECT_VERSION:-}" ]; then
  case "$reported" in
    *"version $EXPECT_VERSION, "*) ;;
    *) fail "sshpiperd --version does not report $EXPECT_VERSION" ;;
  esac
fi
if [ -n "${EXPECT_COMMIT:-}" ]; then
  short=$(printf %.9s "$EXPECT_COMMIT")
  case "$reported" in
    *", $short, "*) ;;
    *) fail "sshpiperd --version does not report upstream commit $short" ;;
  esac
  grep -q "$EXPECT_COMMIT" /usr/share/doc/sshpiper/copyright ||
    fail "/usr/share/doc/sshpiper/copyright does not name upstream commit $EXPECT_COMMIT"
fi

echo "== sshpiperd --help"
sshpiperd --help > "$d/sshpiperd-help.txt"
for flag in --server-key --drop-hostkeys-message; do
  grep -q -- "$flag" "$d/sshpiperd-help.txt" || fail "sshpiperd --help does not list $flag"
done
sed -n '1,8p' "$d/sshpiperd-help.txt"

echo "== plugins in $PLUGIN_DIR"
ls -l "$PLUGIN_DIR"
got=$(ls "$PLUGIN_DIR" | tr '\n' ' ' | sed 's/ $//')
[ "$got" = "$PLUGINS" ] || fail "plugins are \"$got\", not \"$PLUGINS\""
# A plugin has no --help or --version (upstream hides them), and started
# without a flag it doesn't know it serves sshpiperd on its standard input
# and output. So each is started with --help, which upstream's plugin library
# turns down in its own words: the program runs here, and is an sshpiper
# plugin.
for p in $PLUGINS; do
  said=$("$PLUGIN_DIR/$p" --help 2>&1 < /dev/null) || fail "plugin $p exited $?: $said"
  case "$said" in
    *"cannot start plugin: flag: help requested"*) echo "$p: starts" ;;
    *) fail "plugin $p didn't answer as an sshpiper plugin: $said" ;;
  esac
done

echo "== a login through sshpiperd (fixed plugin) to a throwaway sshd"
apt-get install -y --no-install-recommends openssh-server openssh-client sshpass iproute2 > "$d/apt-tools.log" 2>&1 ||
  { cat "$d/apt-tools.log" >&2; fail "couldn't install the OpenSSH tools the test uses"; }
ssh -V

password=install-test-$$
useradd --create-home --shell /bin/sh backenduser
echo "backenduser:$password" | chpasswd
# Both Ed25519, as fpgas.online's fleet key is; different keys, so the client
# can only have verified the one sshpiperd was given.
ssh-keygen -q -t ed25519 -N '' -C backend -f "$d/backend_host_key"
ssh-keygen -q -t ed25519 -N '' -C proxy -f "$d/proxy_host_key"

mkdir -p /run/sshd
# OpenSSH 9.8 and later penalise a source address after failed logins
# (PerSourcePenalties) and then drop its connections. Every login through
# sshpiperd comes from sshpiperd's address, so the wrong passwords below
# would shut this test's own later logins out. Off where sshd knows the
# option (bookworm's 9.2 doesn't). A real backend behind sshpiperd needs the
# proxy's address in its PerSourcePenaltyExemptList for the same reason.
penalties=
if /usr/sbin/sshd -t -f /dev/null -o HostKey="$d/backend_host_key" -o PerSourcePenalties=no 2> "$d/sshd-probe.err"; then
  penalties="-o PerSourcePenalties=no"
fi
# shellcheck disable=SC2086 # $penalties is one option or nothing
/usr/sbin/sshd -f /dev/null -E "$d/sshd.log" \
  -o ListenAddress=127.0.0.1 -o Port=$BACKEND_PORT -o HostKey="$d/backend_host_key" \
  -o PidFile="$d/sshd.pid" -o PasswordAuthentication=yes -o UsePAM=no $penalties
echo "backend sshd started${penalties:+ with PerSourcePenalties=no}"

sshpiperd --address 127.0.0.1 --port $PROXY_PORT \
  --server-key "$d/proxy_host_key" --server-key-generate-mode disable \
  --drop-hostkeys-message \
  "$PLUGIN_DIR/fixed" --target 127.0.0.1:$BACKEND_PORT > "$d/sshpiperd.log" 2>&1 &
piper=$!

logs() {
  echo "--- sshpiperd log"; cat "$d/sshpiperd.log"
  echo "--- sshd log"; cat "$d/sshd.log"
  if [ -f "$d/ssh.log" ]; then echo "--- ssh client log"; cat "$d/ssh.log"; fi
}

# Wait for sshpiperd to answer, and read the host key it presents.
presented=
for _ in $(seq 1 50); do
  kill -0 "$piper" 2> /dev/null || { logs >&2; fail "sshpiperd exited"; }
  # Newer ssh-keyscans also print the server's banner, as a # comment.
  if ssh-keyscan -T 2 -t ed25519 -p $PROXY_PORT 127.0.0.1 > "$d/keyscan.out" 2> "$d/keyscan.err"; then
    presented=$(grep -v '^#' "$d/keyscan.out" || true)
    [ -z "$presented" ] || break
  fi
  sleep 0.2
done
[ -n "$presented" ] || { cat "$d/keyscan.err" >&2; logs >&2; fail "sshpiperd never answered on port $PROXY_PORT"; }
want_key=$(cut -d' ' -f1,2 "$d/proxy_host_key.pub")
[ "$(echo "$presented" | cut -d' ' -f2,3)" = "$want_key" ] ||
  { logs >&2; fail "sshpiperd presents \"$presented\", not the --server-key $want_key"; }
echo "sshpiperd presents its --server-key: $want_key"

# Only sshpiperd's key is known, and checking is strict: a login that
# succeeds verified that key. UpdateHostKeys is on, so the client would take
# up the hostkeys-00@openssh.com message if the sshd's reached it.
echo "[127.0.0.1]:$PROXY_PORT $want_key" > "$d/known_hosts"
cp "$d/known_hosts" "$d/known_hosts.before"
landed=$(sshpass -p "$password" ssh -v -E "$d/ssh.log" -p $PROXY_PORT \
  -o UserKnownHostsFile="$d/known_hosts" -o GlobalKnownHostsFile=/dev/null \
  -o StrictHostKeyChecking=yes -o UpdateHostKeys=yes \
  -o PreferredAuthentications=password -o PubkeyAuthentication=no \
  backenduser@127.0.0.1 'echo "user=$(id -un) connection=$SSH_CONNECTION"') ||
  { logs >&2; fail "the login through sshpiperd failed"; }
echo "the client landed on: $landed"

# SSH_CONNECTION is "<client ip> <client port> <server ip> <server port>" as
# the sshd that ran the session saw it: the backend's port, though the client
# dialled sshpiperd's.
case "$landed" in
  "user=backenduser connection=127.0.0.1 "*" 127.0.0.1 $BACKEND_PORT") ;;
  *) logs >&2; fail "the session is not backenduser's on the backend sshd (port $BACKEND_PORT)" ;;
esac
grep -q "Accepted password for backenduser from 127.0.0.1" "$d/sshd.log" ||
  { logs >&2; fail "the backend sshd logged no accepted login"; }
grep -q "Authenticated to 127.0.0.1 (\[127.0.0.1\]:$PROXY_PORT)" "$d/ssh.log" ||
  { logs >&2; fail "the client did not authenticate to sshpiperd's port $PROXY_PORT"; }

# --drop-hostkeys-message: the sshd's hostkeys-00@openssh.com must not reach
# the client, which would otherwise learn (or warn about) the backend's keys.
if grep -q "hostkeys-00@openssh.com" "$d/ssh.log"; then
  logs >&2
  fail "the client was sent hostkeys-00@openssh.com despite --drop-hostkeys-message"
fi
cmp -s "$d/known_hosts" "$d/known_hosts.before" ||
  { logs >&2; fail "the client's known_hosts changed: it learnt a key through sshpiperd"; }
echo "no hostkeys-00@openssh.com reached the client; its known_hosts is unchanged"

echo "== failed logins leave no connection open at the backend sshd"
# The defect packaging/patches/sshpiper.crypto/ fixes: sshpiperd kept its
# onward connection open after the backend refused the relayed password, so
# every wrong password held one of the backend sshd's unauthenticated
# connection slots (MaxStartups, 10:30:100 by default) until that sshd's
# LoginGraceTime (120 s), and enough of them shut real logins out.
#
# What is counted: established TCP connections at the backend sshd's port
# (its side of each: source port BACKEND_PORT), as the kernel lists them.
backend_connections() {
  ss -Htn state established "( sport = :$BACKEND_PORT )" | wc -l
}
# Polled for up to 5 s: sshpiperd closes the connection as it answers the
# client, which can return a moment before the kernel has it gone.
no_backend_connections() {
  for _ in $(seq 1 25); do
    [ "$(backend_connections)" -eq 0 ] && return 0
    sleep 0.2
  done
  return 1
}
# The client's settings, in a file: sshpass runs ssh itself.
cat > "$d/ssh_config" <<EOF
Host 127.0.0.1
  Port $PROXY_PORT
  UserKnownHostsFile $d/known_hosts
  GlobalKnownHostsFile /dev/null
  StrictHostKeyChecking yes
  PreferredAuthentications password
  PubkeyAuthentication no
EOF
no_backend_connections || { logs >&2; fail "$(backend_connections) connections at the backend before the test started"; }

# More wrong passwords than MaxStartups' 10, each in a connection of its own.
WRONG=12
for i in $(seq 1 $WRONG); do
  if sshpass -p "wrong-$i" ssh -F "$d/ssh_config" -o NumberOfPasswordPrompts=1 backenduser@127.0.0.1 true 2> "$d/wrong.err"; then
    fail "a wrong password was let in"
  fi
  grep -q "Permission denied" "$d/wrong.err" ||
    { cat "$d/wrong.err" >&2; logs >&2; fail "wrong password $i was not turned down with Permission denied"; }
done
if ! no_backend_connections; then
  left=$(backend_connections)
  ss -tn state established "( sport = :$BACKEND_PORT )" >&2
  grep -i "maxstartups" "$d/sshd.log" >&2 || true
  fail "$left connections are still open at the backend sshd after $WRONG wrong passwords through sshpiperd (every client has gone)"
fi
# Each one reached the backend and was refused there: none was dropped for
# want of a slot.
refused=$(grep -c "Failed password for backenduser" "$d/sshd.log")
[ "$refused" -eq $WRONG ] || { logs >&2; fail "the backend sshd refused $refused passwords, not $WRONG"; }
echo "$WRONG wrong passwords, each refused by the backend: 0 connections left open at the backend sshd"

# One connection, one wrong password, then the right one: the client's
# normal retries must still work. ssh asks this program for each password.
cat > "$d/askpass" <<EOF
#!/bin/sh
n=\$(cat "$d/askpass.count")
n=\$((n + 1))
echo "\$n" > "$d/askpass.count"
if [ "\$n" -ge "\$(cat "$d/askpass.right-at")" ]; then echo "$password"; else echo "wrong-in-connection-\$n"; fi
EOF
chmod +x "$d/askpass"
echo 0 > "$d/askpass.count"
echo 2 > "$d/askpass.right-at"
landed=$(SSH_ASKPASS="$d/askpass" SSH_ASKPASS_REQUIRE=force ssh -F "$d/ssh_config" -o NumberOfPasswordPrompts=3 \
  backenduser@127.0.0.1 'echo "user=$(id -un) connection=$SSH_CONNECTION"' < /dev/null 2> "$d/retry.err") ||
  { cat "$d/retry.err" >&2; logs >&2; fail "a wrong password and then the right one, in one connection, did not log in"; }
[ "$(cat "$d/askpass.count")" -eq 2 ] || fail "ssh asked for $(cat "$d/askpass.count") passwords, not 2"
case "$landed" in
  "user=backenduser connection=127.0.0.1 "*" 127.0.0.1 $BACKEND_PORT") ;;
  *) logs >&2; fail "after a wrong password, the right one did not land on the backend sshd: $landed" ;;
esac
echo "one connection, a wrong password then the right one: landed on: $landed"

# One connection, three wrong passwords: the client gets all three attempts.
echo 0 > "$d/askpass.count"
echo 99 > "$d/askpass.right-at"
if SSH_ASKPASS="$d/askpass" SSH_ASKPASS_REQUIRE=force ssh -F "$d/ssh_config" -o NumberOfPasswordPrompts=3 \
  backenduser@127.0.0.1 true < /dev/null 2> "$d/three.err"; then
  fail "three wrong passwords were let in"
fi
[ "$(cat "$d/askpass.count")" -eq 3 ] ||
  { cat "$d/three.err" >&2; logs >&2; fail "the client got $(cat "$d/askpass.count") password attempts in one connection, not 3"; }
refused=$(grep -c "Failed password for backenduser" "$d/sshd.log")
[ "$refused" -eq $((WRONG + 1 + 3)) ] ||
  { logs >&2; fail "the backend sshd has refused $refused passwords in all, not $((WRONG + 1 + 3))"; }
no_backend_connections ||
  { ss -tn state established "( sport = :$BACKEND_PORT )" >&2; fail "$(backend_connections) connections left open at the backend sshd after the retries"; }
echo "one connection, three wrong passwords: three attempts, all refused; 0 connections left open at the backend sshd"

# And a correct login still works after all of that.
landed=$(sshpass -p "$password" ssh -F "$d/ssh_config" backenduser@127.0.0.1 'echo "user=$(id -un) connection=$SSH_CONNECTION"') ||
  { logs >&2; fail "a correct login through sshpiperd failed after the wrong ones"; }
case "$landed" in
  "user=backenduser connection=127.0.0.1 "*" 127.0.0.1 $BACKEND_PORT") ;;
  *) logs >&2; fail "the login after the wrong ones did not land on the backend sshd: $landed" ;;
esac
echo "a correct login afterwards landed on: $landed"

kill "$piper"
kill "$(cat "$d/sshd.pid")"
echo "install-test: OK: sshpiper $(dpkg-query -W -f '${Version}' sshpiper) installs, and a login through sshpiperd + fixed landed on the backend sshd"
