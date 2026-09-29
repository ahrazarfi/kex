#!/bin/bash
# Runs on the machine that hosts the desktop: a cloud VM (--mode vm) or WSL2 itself (--mode wsl).
set -euo pipefail

INI=/etc/xrdp/xrdp.ini
SESMAN=/etc/xrdp/sesman.ini
STATE_DIR="$HOME/.local/state/kex"
XSESSION_MARKER="# managed by kex"

MODE=""
PORT=""
ACTION="install"
FULL=0

info() { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    echo "usage: kex-server.sh --mode vm|wsl --port N [--install|--uninstall|--start|--stop] [--full]" >&2
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --mode) MODE="${2:-}"; shift 2 ;;
        --port) PORT="${2:-}"; shift 2 ;;
        --install) ACTION=install; shift ;;
        --uninstall) ACTION=uninstall; shift ;;
        --start) ACTION=start; shift ;;
        --stop) ACTION=stop; shift ;;
        --full) FULL=1; shift ;;
        *) usage ;;
    esac
done

case "$MODE" in vm|wsl) ;; *) usage ;; esac
if [ "$ACTION" != uninstall ] && [ "$ACTION" != stop ]; then
    if ! { [[ "$PORT" =~ ^[0-9]{1,5}$ ]] && [ "$PORT" -ge 1024 ] && [ "$PORT" -le 65535 ]; }; then
        die "--port must be a number between 1024 and 65535"
    fi
fi

[ "$(id -u)" -ne 0 ] || die "Run this as your normal user, not root. kex uses sudo where needed and never lets root log in to the desktop."

is_wsl() {
    # Not /proc/version: Docker Desktop containers run on the WSL kernel too.
    [ -d /run/WSL ] || [ -n "${WSL_DISTRO_NAME:-}" ] || compgen -G '/proc/sys/fs/binfmt_misc/WSLInterop*' >/dev/null
}
has_systemd() { [ -d /run/systemd/system ]; }

svc() {
    if has_systemd; then
        sudo systemctl "$1" xrdp
    elif [ -x /etc/init.d/xrdp ]; then
        sudo service xrdp "$1"
    else
        die "Can't manage the xrdp service: no systemd and no /etc/init.d/xrdp."
    fi
}

check_os() {
    [ -r /etc/os-release ] || die "Can't identify this OS (/etc/os-release missing)."
    local id ver major
    id=$(. /etc/os-release && echo "${ID:-}")
    ver=$(. /etc/os-release && echo "${VERSION_ID:-0}")
    major=${ver%%.*}
    case "$id" in
        ubuntu) [ "$major" -ge 20 ] 2>/dev/null || die "Ubuntu $ver is too old; kex supports Ubuntu 20.04 and newer." ;;
        debian) [ "$major" -ge 11 ] 2>/dev/null || die "Debian $ver is too old; kex supports Debian 11 and newer." ;;
        *) die "Unsupported OS '$id'. kex supports Ubuntu 20.04+ and Debian 11+. On EC2 / Oracle Cloud, pick an Ubuntu image." ;;
    esac
}

check_sudo() {
    command -v sudo >/dev/null || die "sudo is not installed."
    # Not `sudo -v`: on sudo 1.9 it demands a password whenever any matching rule lacks NOPASSWD,
    # even if the user has NOPASSWD:ALL (typical cloud images). `sudo true` prompts only if actually needed.
    sudo -n true 2>/dev/null || sudo true || die "This account can't use sudo."
}

sshd_value() {
    # $1 = full `sshd -T` output, $2.. = option names (first match wins)
    local cfg="$1" key; shift
    for key in "$@"; do
        awk -v k="$key" '$1 == k { print $2; found = 1; exit } END { exit !found }' <<<"$cfg" && return 0
    done
    return 1
}

check_ssh_key_only() {
    local sshd cfg pw kbd pam
    sshd=$(command -v sshd || echo /usr/sbin/sshd)
    [ -x "$sshd" ] || die "Can't find sshd on this VM, so kex can't confirm SSH is key-only."
    # Evaluate as if this user connected from an arbitrary internet address, so Match blocks are applied.
    cfg=$(sudo "$sshd" -T -C "user=$USER,host=kex-check.invalid,addr=198.51.100.7" 2>/dev/null) \
        || die "Couldn't read the SSH server's effective configuration (sshd -T failed)."
    pw=$(sshd_value "$cfg" passwordauthentication || echo yes)
    kbd=$(sshd_value "$cfg" kbdinteractiveauthentication challengeresponseauthentication || echo yes)
    pam=$(sshd_value "$cfg" usepam || echo no)

    if [ "$pw" != no ] || { [ "$kbd" != no ] && [ "$pam" != no ]; }; then
        cat >&2 <<EOF
ERROR: This VM's SSH server accepts passwords.
kex sets a login password for the desktop. With password SSH enabled, anyone on the
internet could try to guess it. Disable password SSH first (only if you log in with an
SSH key, or you will lock yourself out):

  printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' | sudo tee /etc/ssh/sshd_config.d/00-kex-key-only.conf
  sudo systemctl reload ssh

Then run kex setup again.
EOF
        exit 1
    fi

    if sudo grep -qsiE '^[[:space:]]*Match[[:space:]]' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; then
        warn "Your sshd config has Match blocks. kex verified password SSH is off for connections from the internet, but a Match rule could still allow passwords from specific networks or users."
    fi
}

check_memory() {
    local kb answer
    kb=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)
    if [ "$kb" -lt 1900000 ]; then
        warn "This machine has only $((kb / 1024)) MB of RAM. The desktop uses roughly 300-500 MB while you're connected, which can slow down other services running here."
        read -rp "Continue anyway? [y/N] " answer
        [[ "$answer" =~ ^[yY] ]] || die "Stopped. Nothing was installed."
    fi
}

install_packages() {
    info "Installing XFCE desktop and xrdp (this can take a few minutes)..."
    sudo apt-get update
    # Name a screen locker explicitly, or apt picks light-locker, which drags in lightdm (useless over RDP).
    local locker=xscreensaver
    if apt-cache policy xfce4-screensaver 2>/dev/null | grep -q 'Candidate: [0-9]'; then
        locker=xfce4-screensaver
    fi
    local pkgs=(xfce4 xfce4-terminal "$locker" dbus-x11 xrdp xorgxrdp)
    [ "$FULL" = 1 ] && pkgs+=(xfce4-goodies)
    # NEEDRESTART_*: never let Ubuntu's needrestart restart unrelated services (e.g. Docker) on a live server.
    sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 NEEDRESTART_MODE=l apt-get install -y "${pkgs[@]}"
}

# Every TCP socket owned by xrdp or xrdp-sesman, one "addr:port" per line.
xrdp_listeners() {
    sudo ss -ltnpH | awk '/"xrdp(-sesman)?",pid=/ { print $4 }'
}

wait_for_port() {
    local _
    for _ in $(seq 1 10); do
        xrdp_listeners | grep -qE ":$PORT\$" && return 0
        sleep 1
    done
    return 1
}

only_loopback() {
    local exposed
    exposed=$(xrdp_listeners | grep -vE '^(127\.0\.0\.1|\[::1\]|\[::ffff:127\.0\.0\.1\]):' || true)
    [ -z "$exposed" ]
}

restart_and_verify() {
    svc restart >/dev/null
    wait_for_port && only_loopback
}

configure_xrdp() {
    info "Restricting xrdp to 127.0.0.1:$PORT..."
    sudo cp -n "$INI" "$INI.kex-orig"
    sudo cp -n "$SESMAN" "$SESMAN.kex-orig"

    sudo sed -i '/^\[Security\]/,/^\[/ s/^AllowRootLogin=.*/AllowRootLogin=false/' "$SESMAN"

    # Older xrdp (e.g. 0.9.12 on Ubuntu 20.04) uses address=; newer uses port=tcp://ip:port.
    sudo sed -i '/^\[Globals\]/,/^\[/{/^address=/d;s/^port=.*/port='"$PORT"'\naddress=127.0.0.1/}' "$INI"
    if ! restart_and_verify; then
        sudo sed -i '/^\[Globals\]/,/^\[/{/^address=/d;s|^port=.*|port=tcp://127.0.0.1:'"$PORT"'|}' "$INI"
        if ! restart_and_verify; then
            svc stop >/dev/null 2>&1 || true
            printf 'xrdp listeners were:\n%s\n' "$(xrdp_listeners)" >&2
            die "Couldn't confirm xrdp listens on localhost only, so it has been stopped. Nothing is exposed."
        fi
    fi
    info "Verified: xrdp is only reachable from this machine (and through the SSH tunnel)."
}

configure_session() {
    local xs="$HOME/.xsession"
    if [ ! -e "$xs" ] || head -n1 "$xs" | grep -qxF "$XSESSION_MARKER"; then
        # WAYLAND_DISPLAY leaking in from WSLg would send app windows to Windows instead of the RDP session.
        printf '%s\nunset WAYLAND_DISPLAY\nexec xfce4-session\n' "$XSESSION_MARKER" > "$xs"
    else
        warn "$xs already exists and wasn't created by kex; leaving it alone. The remote desktop will start whatever it runs."
    fi
}

random_password() {
    local pw
    # Read a fixed amount instead of piping tr into head, which breaks under pipefail.
    pw=$(head -c 4096 /dev/urandom | LC_ALL=C tr -dc 'A-HJ-NP-Za-km-z2-9')
    pw=${pw:0:24}
    [ ${#pw} -eq 24 ] || die "Couldn't generate a random password."
    printf '%s' "$pw"
}

set_password() {
    local status answer pw
    status=$(sudo passwd -S "$USER" | awk '{ print $2 }')
    if [ "$status" = P ]; then
        read -rp "Account '$USER' already has a password. Replace it with a new random one? [y/N] " answer
        case "$answer" in
            [yY]*) ;;
            *) info "Keeping your existing password for desktop login."; return ;;
        esac
    fi

    pw=$(random_password)
    printf '%s:%s\n' "$USER" "$pw" | sudo chpasswd
    mkdir -p "$STATE_DIR"
    touch "$STATE_DIR/password-set-by-kex"

    cat <<EOF

  ============================================================
    Desktop login   user: $USER
                    password: $pw

    Save it in a password manager now. It is not stored
    anywhere by kex and will not be shown again.
  ============================================================

EOF
}

check_auto_updates() {
    if ! dpkg-query -W -f='${Status}' unattended-upgrades 2>/dev/null | grep -q 'install ok installed' \
        || ! apt-config dump 2>/dev/null | grep -q 'APT::Periodic::Unattended-Upgrade "1"'; then
        warn "Automatic security updates are off. Enable them so xrdp and the desktop get patched:"
        warn "  sudo apt-get install -y unattended-upgrades && sudo dpkg-reconfigure -plow unattended-upgrades"
    fi
}

fix_wslg_x11_dir() {
    # WSLg mounts /tmp/.X11-unix read-only, which stops xrdp's X server from creating its socket.
    if findmnt -no OPTIONS /tmp/.X11-unix 2>/dev/null | grep -qE '(^|,)ro(,|$)'; then
        sudo mount -o remount,rw /tmp/.X11-unix
        sudo chmod 1777 /tmp/.X11-unix
    fi
}

do_install() {
    check_os
    if [ "$MODE" = wsl ]; then
        is_wsl || die "This isn't WSL. Use the cloud VM option instead."
    fi
    check_sudo
    if [ "$MODE" = vm ]; then
        check_ssh_key_only
        check_memory
    fi

    install_packages
    configure_session
    configure_xrdp

    if [ "$MODE" = wsl ]; then
        # Only run the desktop when `kex` asks for it.
        if has_systemd; then sudo systemctl disable xrdp >/dev/null 2>&1 || true; fi
        svc stop >/dev/null 2>&1 || true
    else
        if has_systemd; then sudo systemctl enable xrdp >/dev/null 2>&1 || true; fi
        set_password
        check_auto_updates
    fi
    info "Setup finished."
}

do_start() {
    [ -f "$INI" ] || die "xrdp isn't installed. Run 'kex setup' first."
    fix_wslg_x11_dir
    if xrdp_listeners | grep -qE ":$PORT\$"; then
        only_loopback || die "xrdp is listening on a non-local address. Run 'kex setup' again to fix its config."
        info "xrdp already running."
        return
    fi
    svc start >/dev/null
    wait_for_port || die "xrdp didn't start listening on port $PORT."
    only_loopback || { svc stop >/dev/null 2>&1; die "xrdp came up on a non-local address, so it was stopped. Run 'kex setup' again."; }
}

do_stop() {
    svc stop >/dev/null
    info "xrdp stopped."
}

do_uninstall() {
    local answer
    check_sudo
    svc stop >/dev/null 2>&1 || true
    sudo rm -f "$INI.kex-orig" "$SESMAN.kex-orig"
    sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 NEEDRESTART_MODE=l apt-get purge -y xrdp xorgxrdp
    if [ -f "$HOME/.xsession" ] && head -n1 "$HOME/.xsession" | grep -qxF "$XSESSION_MARKER"; then
        rm -f "$HOME/.xsession"
    fi
    if [ -f "$STATE_DIR/password-set-by-kex" ]; then
        read -rp "Lock the password kex set for '$USER' (back to SSH-key-only login)? [Y/n] " answer
        case "$answer" in
            [nN]*) ;;
            *) sudo passwd -l "$USER" >/dev/null && info "Password locked." ;;
        esac
        rm -f "$STATE_DIR/password-set-by-kex"
    fi
    info "xrdp removed. The XFCE packages were left installed; remove them with:"
    info "  sudo apt-get remove xfce4 xfce4-terminal xfce4-screensaver xscreensaver xfce4-goodies && sudo apt-get autoremove"
}

case "$ACTION" in
    install) do_install ;;
    start) do_start ;;
    stop) do_stop ;;
    uninstall) do_uninstall ;;
esac
