# kex

**A full Linux desktop in one command, for WSL2 or any Ubuntu/Debian cloud VM.**

Inspired by Kali's Win-KeX, but for plain Ubuntu/Debian, and it also works with cloud VMs (AWS EC2, Google Cloud, Oracle Cloud, or any VPS). You run `kex setup` once, then `kex` opens an XFCE desktop in Remote Desktop.

```text
$ kex setup      # asks: WSL2 or cloud VM? then installs and secures everything
$ kex            # start the desktop and open Remote Desktop
$ kstatus        # what's running
$ kexit          # stop it
```

- **WSL2:** a desktop for your WSL distro, opened in Windows Remote Desktop.
- **Cloud VM:** a desktop on the VM, reached through an encrypted SSH tunnel. The Remote Desktop port is never exposed to the internet.

## Supported platforms

| Where the desktop runs | Where you connect from |
| --- | --- |
| WSL2 with Ubuntu 20.04+ or Debian 11+ | Windows (Remote Desktop, built in) |
| Cloud VM with Ubuntu 20.04+ or Debian 11+ (x86_64 or arm64) | Windows (PowerShell, no WSL needed), WSL2, Linux (FreeRDP or Remmina), macOS (Windows App) |

Amazon Linux, Oracle Linux, RHEL and other non-Debian distros aren't supported. On EC2 and Oracle Cloud, pick an **Ubuntu** image.

## Install

**Linux / WSL2 / macOS**

```bash
git clone https://github.com/ahrazarfi/kex.git
cd kex && ./install.sh
```

This installs to `~/.local/share/kex` and adds `kex`, `kexit` and `kstatus` to `~/.local/bin`. No root needed.

**Windows (PowerShell)**

```powershell
git clone https://github.com/ahrazarfi/kex.git
cd kex
powershell -ExecutionPolicy Bypass -File windows\install.ps1
```

This installs to `%LOCALAPPDATA%\kex` and adds it to your user `PATH`; open a new terminal afterwards. It needs the built-in OpenSSH client (Windows 10 1809+, on by default in Windows 11). The Windows client connects to cloud VMs. For a desktop *inside* WSL2, run kex from your WSL terminal.

## Quick start

### Desktop inside WSL2

```bash
kex setup      # choose 1) Here, in this WSL2 distro
kex            # Remote Desktop opens; log in with your WSL username and password
```

### Desktop on a cloud VM

1. Create an **Ubuntu** VM and make sure `ssh user@ip` works with your key.
2. In the cloud firewall (security group / VCN security list / VPC firewall), allow **only SSH, port 22**, ideally only from your IP. **Do not open port 3389.**
3. Run setup and choose the cloud VM option:

   ```bash
   kex setup
   ```

   It asks for:
   - the SSH login (e.g. `ubuntu@203.0.113.10`);
   - your key file, or leave it empty if your SSH agent/config already has it;
   - a profile name.

4. **Setup prints a random desktop password once.** Save it in your password manager. You'll type it at the xrdp login screen together with the username.
5. Connect:

   ```bash
   kex
   ```

## Commands

| Command | What it does |
| --- | --- |
| `kex setup` | Set up a new desktop. In WSL it asks whether the desktop runs in WSL or on a cloud VM. |
| `kex` / `kex start [name]` | Start the desktop (WSL) or open the SSH tunnel (VM), then launch Remote Desktop. |
| `kex stop [name]` / `kexit` | Stop xrdp (WSL) or close the tunnel (VM). |
| `kex status [name]` / `kstatus` | Show each desktop and whether it's running or connected. |
| `kex list` | List saved profiles. |
| `kex remove <name>` | Uninstall xrdp from that machine and delete the profile. |

Each desktop is a saved **profile**, so you can have WSL plus several VMs. With only one profile, `kex` needs no name.

## How it works

```text
 your computer                                   cloud VM
┌──────────────────────────┐                   ┌──────────────────────────────┐
│ Remote Desktop client    │                   │ xrdp  (127.0.0.1:3389 only)  │
│   -> 127.0.0.1:3391      │                   │   -> XFCE desktop session    │
│         │                │   SSH (port 22)   │            ▲                 │
│   ssh -L tunnel ─────────┼═══════════════════┼──> sshd ───┘                 │
└──────────────────────────┘  encrypted, key   └──────────────────────────────┘
                              authenticated         port 3389 is never open
```

- **`kex setup` (VM):** the server script is sent over SSH and:
  1. checks the OS and that SSH is key-only;
  2. installs XFCE and xrdp;
  3. binds xrdp to `127.0.0.1` and verifies it;
  4. sets a random password and warns if automatic updates are off.
- **`kex` (VM):** opens `ssh -L 127.0.0.1:<local>:127.0.0.1:3389` in the background and points Remote Desktop at the local end.
- **WSL:** xrdp runs inside WSL on `127.0.0.1:3390`, which Windows reaches through WSL's localhost forwarding. It only runs between `kex` and `kexit`.

## Security model

What kex guarantees, and how:

- **xrdp is never reachable from the network.** It's bound to `127.0.0.1`. Setup then inspects every socket xrdp and its session manager actually listen on, and **stops xrdp and fails** if any of them isn't loopback. It handles both xrdp config syntaxes (`address=` in older versions, `port=tcp://` in newer ones).
- **The only way in is SSH.** Remote Desktop traffic goes through an SSH tunnel that your key authenticates, so it's encrypted end to end. The tunnel's local end listens only on `127.0.0.1` of your computer.
- **A desktop password never opens a password door to SSH.** Before setting any password, setup evaluates the VM's *effective* SSH config (`sshd -T`, as if connecting from an internet address) and **refuses to continue** if password or keyboard-interactive login is enabled. It never edits your SSH config, so it can't lock you out.
- **Random password, shown once.**
  - 24 characters (about 140 bits) from `/dev/urandom`.
  - Set via `chpasswd` on stdin, so it never appears in a process list.
  - Not stored anywhere.
  - If your account already has a password, setup asks before replacing it.
- **Root can't log in to the desktop** (`AllowRootLogin=false`), and setup refuses to run as root.
- **No code injection from config.** Profiles are parsed as plain data, never executed, and every field is validated. Hosts can't start with `-`, and `ssh` always gets `--` before the host.
- **The setup script is sent safely.** It goes to a private `mktemp` file on the VM, runs, and is deleted.
- **Your other services are left alone.** Package installs run with `NEEDRESTART_SUSPEND=1`, so Ubuntu's `needrestart` won't restart unrelated services like Docker on a live server. Setup warns before installing on machines with less than 2 GB of RAM.
- **Windows:** the tunnel's `ssh.exe` is tracked by PID *and* start time, so `kexit` can never kill an unrelated process that reused the PID.
- **Updates:** setup warns if `unattended-upgrades` is off. xrdp has had vulnerabilities in the past, and the loopback-only binding is what keeps them from being reachable. Keep the VM patched anyway.

What kex does **not** protect against:

- Someone who already has a shell on your VM or your computer. Other local users can reach `127.0.0.1` ports, though they still need the desktop password.
- A stolen SSH key. Use a passphrase or an agent.
- `Match` blocks in `sshd_config` that enable passwords for specific networks or users. Setup warns when it sees them.

## Troubleshooting

| Problem | Fix |
| --- | --- |
| Remote Desktop warns the certificate isn't trusted | Expected. xrdp uses a self-signed certificate, and the connection is already encrypted and authenticated by SSH. Tick "Don't ask me again". |
| Setup refuses: "SSH server accepts passwords" | Disable password SSH on the VM (the error shows the exact commands). Only do this if you log in with a key. |
| "SSH refuses keys other users can read" | Common with keys stored under `/mnt/c` in WSL. Copy the key to `~/.ssh/` and `chmod 600` it (the error shows the commands). |
| Forgot the desktop password | Run `kex setup` again for the same VM and answer **y** when asked to replace the password. |
| VM uses a non-standard SSH port or a jump host | Add a `Host` entry in `~/.ssh/config` and use that alias as the SSH login. |
| Black screen in WSL | Always start with `kex`. It fixes WSLg's read-only `/tmp/.X11-unix`, which breaks xrdp. |
| Desktop is slow on a 1 GB VM | Add swap, or use a VM with 2 GB+ of RAM. The desktop session keeps running on the VM until you log out inside it; `kexit` only closes the tunnel. |

## Uninstall

- **From a machine:** `kex remove <name>` purges xrdp, removes the session file kex created, and offers to lock the password again (back to key-only login). XFCE packages are left installed, and it prints the command to remove them.
- **The client:** delete `~/.local/share/kex`, the `kex`/`kexit`/`kstatus` links in `~/.local/bin`, and `~/.config/kex`. On Windows, delete `%LOCALAPPDATA%\kex` and `%APPDATA%\kex`.

## Testing status

kex is new. Here's exactly what has been verified:

| Scenario | Status |
| --- | --- |
| WSL2 (Ubuntu 20.04): setup and desktop login | ✅ tested manually |
| Cloud VM on Ubuntu 22.04: setup, loopback-only binding, port unreachable from the network, root login blocked, RDP login to XFCE, tunnel start/stop | ✅ automated end-to-end test |
| Cloud VM on Ubuntu 24.04: setup | ✅ automated (remaining checks were interrupted by a test-environment issue) |
| Real Oracle Cloud Ubuntu 24.04 VM: preflight checks (key-only SSH, sudo, OS) | ✅ |
| Cloud VM on Ubuntu 20.04 and Debian 12; macOS client; Windows client end to end | ⚠️ not yet verified |
| Static checks: ShellCheck (bash), PowerShell parser, injection and argument-quoting tests | ✅ |

The end-to-end suite lives in `tests/e2e/`. It runs the real install in systemd containers that mimic cloud VMs, logs in over RDP and takes a screenshot:

```bash
tests/e2e/run.sh                       # all distros (needs Docker)
DOCKER=docker.exe tests/e2e/run.sh     # from WSL with Docker Desktop
```

The test containers run `--privileged` and share the host kernel. Units that change global kernel state are masked, but run the suite on a machine you don't mind poking at.

## Project layout

```text
kex                     client for Linux / WSL2 / macOS (bash)
server/kex-server.sh    runs on the desktop host: install, verify, start/stop, uninstall
windows/kex.ps1         client for Windows (PowerShell 5.1+), plus kex/kexit/kstatus .cmd wrappers
install.sh              installer for Linux / WSL2 / macOS
windows/install.ps1     installer for Windows
tests/e2e/              end-to-end tests (Docker)
```

Issues and pull requests are welcome.

## License

[MIT](LICENSE)
