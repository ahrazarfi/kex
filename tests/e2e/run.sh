#!/bin/bash
# End-to-end test of kex against containers that behave like cloud VMs.
# Installs the real desktop, checks the security properties, logs in over RDP and takes a screenshot.
#
#   tests/e2e/run.sh                      # all distros
#   tests/e2e/run.sh ubuntu:24.04         # just one
#   DOCKER=docker.exe tests/e2e/run.sh    # from WSL with Docker Desktop
set -euo pipefail

DOCKER=${DOCKER:-docker}
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT=${OUT:-$HERE/out}
NET=kex-e2e
DISTROS=("$@")
[ ${#DISTROS[@]} -gt 0 ] || DISTROS=(ubuntu:20.04 ubuntu:22.04 ubuntu:24.04 debian:12)

d() { "$DOCKER" "$@"; }
tag_of() { printf '%s' "$1" | tr -d ':.'; }

prepare() {
    mkdir -p "$OUT"
    [ -f "$OUT/id_test" ] || ssh-keygen -q -t ed25519 -N '' -C kex-e2e -f "$OUT/id_test"
    local ctx="$OUT/ctx" img
    rm -rf "$ctx" && mkdir -p "$ctx"
    cp "$HERE/server.Dockerfile" "$HERE/client.Dockerfile" "$OUT/id_test" "$OUT/id_test.pub" "$ctx/"
    d network create "$NET" >/dev/null 2>&1 || true
    echo "Building images..."
    tar -C "$ctx" -cf - . | d build -q -f client.Dockerfile -t kex-e2e-client - >/dev/null
    for img in "${DISTROS[@]}"; do
        tar -C "$ctx" -cf - . | d build -q -f server.Dockerfile --build-arg BASE="$img" -t "kex-e2e-srv:$(tag_of "$img")" - >/dev/null
    done
}

# One distro, fully isolated (own server + own client). All output goes to $OUT/<tag>.results.
test_one() {
    local img="$1" t srv cli log pw lport
    set +e  # a failing check must be reported, not abort the whole run
    t=$(tag_of "$img"); srv="kex-e2e-$t"; cli="kex-e2e-cli-$t"; log="$OUT/$t.log"
    : > "$log"

    pass() { echo "PASS  [$t] $*"; }
    fail() { echo "FAIL  [$t] $*"; }
    check() { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi; }
    cx() { d exec -i "$cli" bash -c "$1" 2>&1 | tr -d '\r'; return "${PIPESTATUS[0]}"; }
    sx() { d exec -i "$srv" bash -c "$1" 2>&1 | tr -d '\r'; return "${PIPESTATUS[0]}"; }
    no_public() { ! printf '%s\n' "$1" | grep -vqE '^(127\.0\.0\.1|\[::1\]):'; }
    unreachable() { ! cx "timeout 3 bash -c '</dev/tcp/$srv/3389'"; }
    has_pw_status() { sx "passwd -S ubuntu" | awk -v s="$1" '{ exit $2 != s }'; }

    d rm -f "$srv" "$cli" >/dev/null 2>&1 || true
    d run -d --name "$srv" --hostname "$srv" --network "$NET" --privileged --cgroupns=private \
        --tmpfs /run --tmpfs /run/lock "kex-e2e-srv:$t" >/dev/null
    d run -d --name "$cli" --network "$NET" kex-e2e-client >/dev/null
    d exec "$cli" mkdir -p /kex
    tar -C "$ROOT" -cf - kex server | d cp - "$cli:/kex"

    local ok=""
    for _ in $(seq 1 60); do
        if cx "ssh-keyscan -T 2 $srv 2>/dev/null > /root/.ssh/known_hosts && test -s /root/.ssh/known_hosts"; then ok=1; break; fi
        sleep 2
    done
    [ -n "$ok" ] || { fail "server's sshd never came up"; return; }

    # --- setup: goodies? n | host | key | profile name | xrdp port (default)
    cx "cd /kex && printf 'n\nubuntu@$srv\n/root/.ssh/id_test\n$t\n\n' | ./kex setup" >> "$log" || true
    pw=$(grep -oE 'password: [A-Za-z0-9]+' "$log" | awk '{ print $2 }' | head -n1 || true)
    check "setup completes" grep -q "Done. Connect with: kex start $t" "$log"
    check "random 24-char password generated" test "${#pw}" -eq 24

    # --- security properties on the "VM"
    local listeners
    listeners=$(sx "ss -ltnpH" | awk '/"xrdp(-sesman)?",pid=/ { print $4 }')
    printf "      xrdp sockets: %s\n" "${listeners//$'\n'/ }" >> "$log"
    check "xrdp listens on 127.0.0.1:3389" grep -qx '127.0.0.1:3389' <<<"$listeners"
    check "no xrdp socket on a non-loopback address" no_public "$listeners"
    check "port 3389 unreachable from the network" unreachable
    check "root login to desktop disabled" sx "grep -qx 'AllowRootLogin=false' /etc/xrdp/sesman.ini"
    check "account password set (was locked)" has_pw_status P
    check "xrdp enabled at boot" sx "systemctl is-enabled xrdp"

    # --- connect: tunnel + real RDP login + screenshot
    lport=$(cx "sed -n 's/^local_port=//p' /root/.config/kex/profiles/$t")
    cx "cd /kex && ./kex start $t" >> "$log" || true
    check "kex status: connected" cx "cd /kex && ./kex status $t | grep -q ' connected'"
    d exec -e PW="$pw" "$cli" bash -c "setsid nohup Xvfb :99 -screen 0 1280x800x24 >/dev/null 2>&1 </dev/null & sleep 2; DISPLAY=:99 setsid nohup xfreerdp /v:127.0.0.1:$lport /u:ubuntu /p:\"\$PW\" /cert:ignore /size:1280x800 >/tmp/rdp.log 2>&1 </dev/null &" || true
    for _ in $(seq 1 45); do sx "pgrep -u ubuntu -x xfce4-session" >/dev/null && break; sleep 2; done
    check "RDP login starts an XFCE session" sx "pgrep -u ubuntu -x xfce4-session"
    sleep 10
    cx "DISPLAY=:99 import -window root /tmp/shot.png" >/dev/null || true
    d exec "$cli" base64 /tmp/shot.png 2>/dev/null | tr -d '\r' | base64 -d > "$OUT/$t.png" 2>/dev/null || true
    cx "cd /kex && ./kex stop $t" >> "$log" || true
    check "kex stop closes the tunnel" cx "cd /kex && ./kex status $t | grep -q 'not connected'"

    if [ "$t" = ubuntu2404 ]; then
        local h1 h2
        h1=$(sx "getent shadow ubuntu | cut -d: -f2")
        cx "cd /kex && printf 'n\nubuntu@$srv\n/root/.ssh/id_test\n$t-b\n\nN\n' | ./kex setup" >> "$log" || true
        h2=$(sx "getent shadow ubuntu | cut -d: -f2")
        check "re-run setup keeps existing password when told N" test "$h1" = "$h2"
        check "second profile got the next free local port" cx "grep -qx 'local_port=3392' /root/.config/kex/profiles/$t-b"

        d exec -i "$srv" bash -s -- --mode vm --port 3389 < "$ROOT/server/kex-server.sh" > "$OUT/$t.root.log" 2>&1 || true
        check "server script refuses to run as root" grep -q 'not root' "$OUT/$t.root.log"

        cx "cd /kex && printf 'y\nY\n' | ./kex remove $t" >> "$log" || true
        check "remove: xrdp uninstalled" sx "! dpkg -s xrdp"
        check "remove: password locked again" has_pw_status L
        check "remove: nothing listening on 3389" sx "! ss -ltnH 'sport = :3389' | grep -q ."

        sx "printf 'PasswordAuthentication yes\n' > /etc/ssh/sshd_config.d/00-test.conf; systemctl reload ssh" >/dev/null || true
        cx "cd /kex && printf 'n\nubuntu@$srv\n/root/.ssh/id_test\n$t-c\n\n' | ./kex setup" > "$OUT/$t.pwssh.log" || true
        check "refuses setup when SSH accepts passwords" grep -q "accepts passwords" "$OUT/$t.pwssh.log"
        check "...and installs nothing" sx "! dpkg -s xrdp"
        check "...and leaves the password locked" has_pw_status L
    fi

    [ -n "${KEEP:-}" ] || d rm -f "$srv" "$cli" >/dev/null 2>&1 || true
}

prepare
echo "Running ${#DISTROS[@]} distro(s) in parallel; details in $OUT/<distro>.log"
for img in "${DISTROS[@]}"; do
    test_one "$img" > "$OUT/$(tag_of "$img").results" 2>&1 &
done
wait

cat "$OUT"/*.results
fails=$(cat "$OUT"/*.results | grep -c '^FAIL' || true)
passes=$(cat "$OUT"/*.results | grep -c '^PASS' || true)
echo
echo "$passes passed, $fails failed. Screenshots: $OUT/*.png"
[ "$fails" -eq 0 ]
