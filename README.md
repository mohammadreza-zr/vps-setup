# vps-setup

Turn a fresh VPS into a **hardened, shared Claude Code development server** for a small team — then keep managing it (users, SSH keys, remote desktops, internal GitLab access, office services) with one command.

| Script | Target | Version |
|---|---|---|
| [`vps-setup.sh`](vps-setup.sh) | Ubuntu Server 22.04 / 24.04 / 26.04 LTS (amd64, arm64) | 2.3.0 |
| [`vps-setup.ps1`](vps-setup.ps1) | Windows Server 2019 / 2022 / 2025 (x64) | 2.2.0-windows |

Each script is a single self-contained file: no dependencies to fetch first, nothing to build.

## Quick start

### Ubuntu

Copy `vps-setup.sh` to the server (e.g. with `scp`) and run it as root from that file — don't pipe it into bash, it is interactive:

```bash
sudo bash vps-setup.sh
```

### Windows Server

From an elevated PowerShell, in the console or an RDP session:

```powershell
powershell -ExecutionPolicy Bypass -File .\vps-setup.ps1
```

The setup **asks every question first** (admin, developers and their SSH keys, SSH ports, GitLab, desktops…), shows the plan, then runs every step. A step that fails is reported and the rest still run; a full report is printed at the end. It is safe to re-run.

Afterwards the script installs itself as the `vps-setup` command:

```bash
sudo vps-setup help      # Ubuntu
vps-setup help           # Windows (elevated, or over SSH as the admin)
```

## What it sets up

**Users**
- One **admin** (full sudo / Administrators) and any number of **developers** with **no root of any kind**.
- Only members of the `ssh-users` group can log in over SSH. Homes are private to their owner.
- Ubuntu: every user gets Claude Code, nvm + Node, npm, bun, pipx/uv and Go — all in their own home, so they can add more tools without root. Windows: nothing is installed for users; they install their own tools (Claude Code, Git, Node…) into their profile, without admin rights.

**Hardening**
- SSH: **key-only**, no root login, several ports (if one is blocked on a network, clients fall back to the next).
- SSH changes use an **automatic rollback**: if the admin doesn't log in through the new configuration within 10 minutes, it is undone — you can't lock yourself out.
- Firewall (ufw / Windows Defender Firewall): everything inbound blocked except SSH (and optionally 80/443).
- Brute-force protection: fail2ban on Ubuntu; on Windows a scheduled task reads the OpenSSH event log and blocks offenders.
- Automatic security updates, kernel/network sysctl hardening, journald size cap.

**Sharing one server fairly** (Ubuntu)
- CPU and disk I/O are split by equal weight between users who are busy at the same time — an idle server lets one user use 100%.
- Memory: each active user gets a protected share, re-balanced every 30 s; all users together stay below 95% of RAM so sshd always has room.
- `vps-setup memory`: zswap (compressed swap in RAM) and an OOM guard that ends a thrashing user's heaviest app — never sshd or system services.

**Docker** (Ubuntu, optional)
- The admin uses the system Docker; every developer gets their **own rootless Docker** — nobody sees anyone else's containers.
- Published ports bind to `127.0.0.1` by default, so `-p 8080:80` is not exposed to the internet behind ufw's back.

**Remote desktops** (only reachable through an SSH tunnel)
- RDP for every user (xrdp on Ubuntu, Windows' own RDP on Windows).
- Ubuntu: a personal **VNC desktop** per user, on a Unix socket only, with an X authorization cookie. `vps-setup vnc timeout` closes a desktop after its user has been disconnected for a while.
- `vps-setup apps install vscode chrome firefox …` — desktop apps from apt (no snaps).

**Your office network, on the server**
- **Internal GitLab**: `git clone git@gitlab.company.com:…` and `https://gitlab.company.com` work on the server exactly like on your PC, carried through the developers' own SSH connections (`RemoteForward`).
- **Office services**: `vps-setup forward add http://192.168.2.212:8100/docs` makes any office host:port reachable on the server the same way — for everyone, or `--user <name>` for one person only.

**Reports**
- After every change, a report and one sheet per user (their `~/.ssh/config` block, credentials made for them) are rewritten — root/administrators only.

## Commands (Ubuntu)

```text
setup                        First-time setup (interactive). Safe to re-run.
status                       Users, SSH, GitLab gateway, firewall, fail2ban, desktops.

add-user <name> [--admin] [--vnc] [--apps "vscode vlc"] [--forward "host:port ..."]
remove-user <name>           Remove a user (their home is archived first).
add-key <name>               Add another SSH public key for a user.
password <name>              Set or reset a password (sudo and RDP - never SSH).
client-config <name>         The ~/.ssh/config block for that user's computer.

docker <name>                (Re)create that developer's private rootless Docker.
rdp enable|disable           RDP desktop for every user, through an SSH tunnel.
vnc enable|disable <name> [--new-password] [--reset-look]
vnc timeout <30m|2h|3d|off> [<name>]
memory [apply|status]        zswap and the OOM guard.
apps install|remove <app>... | apps list
gitlab [apply|disable]       Re-apply or remove the internal GitLab gateway.
forward add|remove <host:port|URL> [--user <name>] | forward list|apply
usage [<user>] [--mem] [--watch [s]] [--disk]
report                       Rewrite the report and the user sheets.

ssh [--ports "22 9011"]      Re-apply the SSH hardening or change ports (auto-rollback).
confirm                      Keep a pending SSH change now.
```

Run `sudo vps-setup help` for the full text. The Windows version has the same commands except `docker`, `vnc`, `memory` and `apps`, and `rdp enable [--multi]` can add the RDS role for more than two desktops at a time.

## Connecting

Each user gets a ready-made `~/.ssh/config` block for their own computer:

```bash
sudo vps-setup client-config alice
```

It includes the server's ports with fallback, agent forwarding (so `git` on the server uses the key on your PC — no private key is stored on the server), the GitLab/office-service tunnels and the desktop forwards. Then:

- **VS Code**: Remote-SSH → Connect to Host.
- **Claude Code**: run `claude` and log in with your own account. For long tasks use `claude-session` (a persistent tmux session — Claude keeps working after you disconnect).
- **VNC**: point a viewer at `localhost:5901` while connected. **RDP**: `localhost:13389`.

## Files

| | Ubuntu | Windows |
|---|---|---|
| Command | `/usr/local/sbin/vps-setup` | `C:\Program Files\vps-setup` |
| Configuration | `/etc/vps-setup/config` | `C:\ProgramData\vps-setup\config.json` |
| Log (no secrets) | `/var/log/vps-setup.log` | `C:\ProgramData\vps-setup\vps-setup.log` |
| Report | `/root/vps-setup-report.txt` | `C:\ProgramData\vps-setup\report.txt` |
| Per-user sheets | `/root/vps-setup-users/` | `C:\ProgramData\vps-setup\users\` |
| Generated passwords / keys | `/root/vps-setup-credentials/` | `C:\ProgramData\vps-setup\credentials\` |

Generated passwords and private keys are stored in plain text, readable by root/administrators only. **Hand them over privately, then delete them.**

## Security notes

Things to know before you put several people on one server:

- **Shared tunnels mean shared trust.** When a user's own tunnel is down, GitLab and "for everyone" office-service traffic goes through **another developer's** SSH connection. A malicious developer could point their tunnel at a fake server. Pin your GitLab's SSH host key in `/etc/ssh/ssh_known_hosts` (the default is `StrictHostKeyChecking accept-new`) and use HTTPS with a valid certificate rather than plain HTTP.
- **Loopback ports are shared.** Any local user can bind a free `127.0.0.1` port; if xrdp (`3389`) or the office-services gateway (`47070`) is stopped, someone else could take its port.
- **Windows:** the per-user tunnels are plain loopback TCP ports, so personal office services (`forward add --user`) are not isolated from other local users the way they are on Ubuntu (Unix sockets, mode 0600).
- **Agent forwarding** is on so developers can use their own keys for git; root on the server can use a connected user's agent.
- The Claude Code, nvm and bun installers are fetched from their official URLs and run as each user.

## Upgrading an existing server

Copy the new script to the server and run its setup — it installs itself over the old `vps-setup` command and updates everything in place:

```bash
sudo bash vps-setup.sh setup
```

After upgrading from a version before the VNC authorization fix, restart each VNC desktop so it picks up the new session script (the VNC password is kept):

```bash
sudo vps-setup vnc enable <user>
```
