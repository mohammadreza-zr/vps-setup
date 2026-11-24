#!/usr/bin/env bash
# =============================================================================
# vps-setup - turns a fresh Ubuntu VPS into a hardened, shared Claude Code
# development server, then manages it (users, keys, remote desktops, SSH,
# internal GitLab access).
#
# First run (as root, from a saved file - not piped into bash):
#     sudo bash vps-setup.sh
# It asks everything first, then does every server-side job. A step that fails
# is reported and the rest still runs; a full result report is printed at the
# end (and saved to /root/vps-setup-report.txt, without secrets).
#
# Afterwards it is installed as /usr/local/sbin/vps-setup:   sudo vps-setup help
#
# Supported: Ubuntu Server 22.04, 24.04 and 26.04 LTS (amd64 / arm64).
# Log (never contains secrets): /var/log/vps-setup.log
# Generated passwords/keys:     /root/vps-setup-credentials (root only)
# =============================================================================
set -Eeuo pipefail
umask 022

readonly SCRIPT_VERSION="2.3.0"
readonly INSTALL_PATH="/usr/local/sbin/vps-setup"
readonly LIB_DIR="/usr/local/lib/vps-setup"
readonly STATE_DIR="/etc/vps-setup"
readonly CONF_FILE="$STATE_DIR/config"
readonly BACKUP_DIR="$STATE_DIR/backup"
readonly ROLLBACK_DIR="$STATE_DIR/ssh-rollback"
readonly RUN_NOTES="$STATE_DIR/.run-notes"
readonly RUN_CREDS="$STATE_DIR/.run-creds"
readonly CRED_DIR="/root/vps-setup-credentials"
readonly ARCHIVE_DIR="/root/vps-setup-archive"
readonly REPORT_FILE="/root/vps-setup-report.txt"
readonly LOG_FILE="/var/log/vps-setup.log"
readonly SSH_DROPIN_NAME="00-vps-setup.conf"
readonly VNC_SESSION="$LIB_DIR/vnc-session"
readonly VNC_TIMEOUT_CMD="/usr/local/bin/vnc-timeout"          # each user sets their own disconnect timeout
readonly VNC_TIMEOUT_DEFAULT="$LIB_DIR/vnc-disconnect-timeout"  # the server default for it
readonly VNC_UNIT_FILE="/etc/systemd/system/vps-vnc@.service"
readonly GITLAB_GW="$LIB_DIR/gitlab-gw"
readonly GITLAB_UNIT="vps-gitlab-gw.service"
readonly GITLAB_IP="127.77.0.1"              # what gitlab.local resolves to on the server
readonly GITLAB_RUN_DIR="/run/vps-gitlab"
readonly GITLAB_SSH_CLIENT_CONF="/etc/ssh/ssh_config.d/50-vps-setup-gitlab.conf"
readonly FWD_UNIT="vps-fwd-gw.service"       # other office services (vps-setup forward)
readonly FWD_NAT="$LIB_DIR/fwd-nat"
readonly FWD_GW_PORT=47070                   # 127.0.0.1: where the NAT rules send them
readonly FWD_NAME_NET="127.77.1"             # office hostnames resolve to 127.77.1.<n> here
readonly DESKTOP_XDG="$LIB_DIR/xdg"          # desktop defaults (theme, no compositing, panel)
readonly USERS_DIR="/root/vps-setup-users"   # one up-to-date sheet per user (root only)
readonly LAST_SETUP="$STATE_DIR/last-setup"  # steps + details of the last full setup run
readonly ROLLBACK_UNIT="vps-setup-ssh-rollback"
readonly ROLLBACK_MINUTES=10
readonly SSH_GROUP="ssh-users"   # only members may log in over SSH
readonly DEV_GROUP="devs"        # marks developers (no sudo rights of any kind)
readonly RDP_LOCAL_PORT=3389

SSH_DIR="/etc/ssh"               # a variable (not readonly) so the tests can point it elsewhere

BASE_PKGS=(
  ca-certificates curl wget gnupg openssl sudo openssh-server
  ufw fail2ban python3-systemd unattended-upgrades
  git vim nano less htop tmux jq ripgrep fd-find unzip zip tree ncdu rsync lsof
  bind9-dnsutils iproute2 netcat-openbsd build-essential pkg-config
  python3 python3-venv python3-pip pipx bash-completion acl
  python3-dev python3-setuptools python3-wheel python-is-python3 python3-requests python3-yaml
)
readonly NVM_VERSION="v0.40.3"   # per-user Node version manager (github.com/nvm-sh/nvm)

# Answers / state (loaded from $CONF_FILE when it exists)
ADMIN_USER="" SSH_PORTS="" NODE_MAJOR="" INSTALL_DOCKER="" RDP_ENABLED="" OPEN_WEB=""
AUTO_REBOOT="" TRUSTED_IPS="" SETUP_DONE=""
# Internal GitLab, through the developers' SSH tunnels. GITLAB_HOST may list several names
# (any domain, e.g. "gitlab.company.com registry.company.com"); the first is the main one.
# GITLAB_DIRECT=y: when no tunnel works, connect to the domain's public address directly.
GITLAB_HOST="" GITLAB_SSH_PORT="" GITLAB_PORTS="" GITLAB_DIRECT=""
# FORWARDS: other office services (host:port ...) reachable on the server like on your PC,
# for everyone, through any developer's tunnel. FORWARDS_USER: personal ones (user=host:port
# ...), only for that user, through their own tunnel. APPS: desktop apps for every desktop user.
FORWARDS="" FORWARDS_USER="" APPS=""
PW_GENERATED=n
REFRESH_FOR=""
KEYS_OUT=""
RESULTS=()
IN_SETUP=n

# ----------------------------------------------------------------------------
# Output
# ----------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_R=$'\e[31m' C_G=$'\e[32m' C_Y=$'\e[33m' C_B=$'\e[1;34m' C_C=$'\e[36m' C_0=$'\e[0m'
else
  C_R="" C_G="" C_Y="" C_B="" C_C="" C_0=""
fi
log_file() { if [[ -w ${LOG_FILE%/*} ]]; then printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE" 2>/dev/null || true; fi; }
step() { printf '\n%s==> %s%s\n' "$C_B" "$*" "$C_0"; log_file "==> $*"; }
info() { printf '    %s\n' "$*"; log_file "    $*"; }
ok()   { printf '%s[ok]%s %s\n' "$C_G" "$C_0" "$*"; log_file "ok  $*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$*" >&2; log_file "WARN $*"; }
die()  { printf '%s[x]%s %s\n' "$C_R" "$C_0" "$*" >&2; log_file "FAIL $*"; exit 1; }
note() { info "$*"; if [[ -d $STATE_DIR ]]; then printf '%s\n' "$*" >>"$RUN_NOTES"; fi; }   # goes into the final report

on_error() {
  local rc=$? line=$1
  printf '%s[x]%s Failed (exit %s) at line %s: %s\n' "$C_R" "$C_0" "$rc" "$line" "$BASH_COMMAND" >&2
  log_file "FAIL line $line: $BASH_COMMAND (exit $rc)"
  exit "$rc"
}

# run <description> <command...> - command output goes to the log; while it runs a progress
# line is shown every 30 s; on failure the tail of the log is shown and the step stops.
run() { run_soft "$@" || exit 1; }

# run_soft - the same, but returns the failure instead of stopping (to continue with others)
run_soft() {
  local desc=$1 pid waited=0 last; shift
  info "$desc"
  printf '\n$ %s\n' "$*" >>"$LOG_FILE"
  "$@" >>"$LOG_FILE" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    sleep 2
    waited=$((waited + 2))
    if (( waited % 30 == 0 )) && kill -0 "$pid" 2>/dev/null; then
      last=$(tail -n 1 "$LOG_FILE" 2>/dev/null | tr -d '\r' | cut -c1-100 || true)
      if [[ $last == *"lock"* ]]; then
        last="waiting for another apt/dpkg run to finish (usually Ubuntu's automatic updates after first boot)"
      fi
      printf '      ... %dm%02ds  %s\n' $((waited / 60)) $((waited % 60)) "$last"
    fi
  done
  if wait "$pid"; then return 0; fi
  printf '%s[x]%s %s failed. Last lines of %s:\n' "$C_R" "$C_0" "$desc" "$LOG_FILE" >&2
  tail -n 30 "$LOG_FILE" >&2
  return 1
}

# try_step <title> <function> [args...] - runs a setup step in a subshell; a failure is
# recorded for the report and the setup continues with the next step.
try_step() {
  local title=$1 rc; shift
  step "$title"
  trap - ERR; set +e
  ( set -Eeuo pipefail; trap 'on_error $LINENO' ERR; "$@" )
  rc=$?
  set -e; trap 'on_error $LINENO' ERR
  if (( rc == 0 )); then
    RESULTS+=("ok"$'\t'"$title")
  else
    RESULTS+=("FAILED"$'\t'"$title")
    warn "'$title' failed - continuing with the next step (details: $LOG_FILE)."
  fi
  load_config
}
skip_step() { RESULTS+=("skipped"$'\t'"$1 - $2"); warn "Skipped '$1': $2"; }
step_ok() { local r; for r in "${RESULTS[@]}"; do [[ $r == "ok"$'\t'"$1" ]] && return 0; done; return 1; }

apt_get() {
  DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 \
    apt-get -y -q -o DPkg::Lock::Timeout=1800 \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

# ----------------------------------------------------------------------------
# Small helpers
# ----------------------------------------------------------------------------
trim() { local s=$1; s=${s#"${s%%[![:space:]]*}"}; s=${s%"${s##*[![:space:]]}"}; printf '%s' "$s"; }
in_group() { [[ " $(id -nG "$1" 2>/dev/null) " == *" $2 "* ]]; }
# duration_secs <5m|90s|2h|3d|off> - prints seconds (a bare number is minutes, off/never/0 is 0);
# fails on anything else. Also copied into vnc-timeout, so both read durations the same way.
duration_secs() {
  local v=${1,,} n
  case $v in off|never|0) echo 0; return 0 ;; esac
  [[ $v =~ ^([0-9]{1,6})([smhd]?)$ ]] || return 1
  n=$((10#${BASH_REMATCH[1]}))
  case ${BASH_REMATCH[2]} in
    s) echo "$n" ;;
    h) echo $((n * 3600)) ;;
    d) echo $((n * 86400)) ;;
    *) echo $((n * 60)) ;;
  esac
}
home_of() { local e; e=$(getent passwd "$1") || return 1; cut -d: -f6 <<<"$e"; }
is_human_uid() { (( $1 >= 1000 && $1 < 60000 )); }
user_has_password() { local h; h=$(getent shadow "$1" | cut -d: -f2) || return 1; [[ $h == \$* ]]; }   # a real hash ($y$, $6$...)
port_listening() { [[ -n $(ss -Htln "( sport = :$1 )" 2>/dev/null) ]]; }
wait_port() { local i; for i in $(seq 1 20); do if port_listening "$1"; then return 0; fi; sleep 0.5; done; return 1; }
pkg_available() { [[ -n $(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ && $2 != "(none)"') ]]; }
uniq_words() { printf '%s\n' "$@" | awk 'NF && !seen[$0]++' | xargs; }
ssh_main_port() { local a=(); read -ra a <<<"${SSH_PORTS:-22}"; printf '%s' "${a[0]:-22}"; }
server_users() { # admin + developers (members of the SSH group), one per line
  local name uid
  while IFS=: read -r name _ uid _; do
    if is_human_uid "$uid" && in_group "$name" "$SSH_GROUP"; then printf '%s\n' "$name"; fi
  done < <(getent passwd)
}

gen_password() { # gen_password <length> - letters and digits only (safe to type and paste)
  local len=${1:-20} p="" r
  while (( ${#p} < len )); do r=$(openssl rand -base64 48); r=${r//[^A-Za-z0-9]/}; p+=$r; done
  printf '%s' "${p:0:len}"
}

server_ip() {
  local ip
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit }}') || true
  [[ -n $ip ]] || ip=$(hostname -I 2>/dev/null | awk '{print $1}') || true
  printf '%s' "${ip:-<server-ip>}"
}

backup_file() {
  install -d -m 700 "$BACKUP_DIR"
  cp -a "$1" "$BACKUP_DIR/$(basename "$1").$(date +%Y%m%d-%H%M%S)"
}

need_tty() { { : >/dev/tty; } 2>/dev/null || die "This command is interactive: run it from a terminal."; }

# ----------------------------------------------------------------------------
# Prompts (always read from the terminal)
# ----------------------------------------------------------------------------
accept_any() { return 0; }

# prompt <var> <question> [default] [validator]
prompt() {
  local __var=$1 __q=$2 __def=${3-} __check=${4-} __ans
  while :; do
    if [[ -n $__def ]]; then printf '%s?%s %s [%s]: ' "$C_C" "$C_0" "$__q" "$__def" >/dev/tty
    else printf '%s?%s %s: ' "$C_C" "$C_0" "$__q" >/dev/tty; fi
    IFS= read -r __ans </dev/tty || die "No input."
    __ans=$(trim "${__ans//$'\r'/}")
    __ans=${__ans:-$__def}
    if [[ $__ans == "-" ]]; then __ans=""; fi   # "-" clears a default
    if [[ -n $__check ]]; then
      if "$__check" "$__ans"; then break; fi
    elif [[ -n $__ans ]]; then
      break
    fi
  done
  printf -v "$__var" '%s' "$__ans"
}

# prompt_yn <var> <question> <y|n>
prompt_yn() {
  local __var=$1 __q=$2 __def=${3:-n} __ans __hint="y/N"
  [[ $__def == y ]] && __hint="Y/n"
  while :; do
    printf '%s?%s %s [%s]: ' "$C_C" "$C_0" "$__q" "$__hint" >/dev/tty
    IFS= read -r __ans </dev/tty || die "No input."
    __ans=$(trim "${__ans:-$__def}"); __ans=${__ans,,}
    case $__ans in
      y|yes) printf -v "$__var" y; return 0 ;;
      n|no)  printf -v "$__var" n; return 0 ;;
    esac
  done
}

# prompt_password <var> <question> - empty input generates one; sets PW_GENERATED=y|n
prompt_password() {
  local __var=$1 __q=$2 __a __b
  while :; do
    printf '%s?%s %s (min 12 chars, empty = generate one): ' "$C_C" "$C_0" "$__q" >/dev/tty
    IFS= read -rs __a </dev/tty || die "No input."; printf '\n' >/dev/tty
    if [[ -z $__a ]]; then printf -v "$__var" '%s' "$(gen_password 20)"; PW_GENERATED=y; return 0; fi
    if (( ${#__a} < 12 )); then warn "Too short."; continue; fi
    printf '%s?%s Repeat it: ' "$C_C" "$C_0" >/dev/tty
    IFS= read -rs __b </dev/tty || die "No input."; printf '\n' >/dev/tty
    if [[ $__a != "$__b" ]]; then warn "The two entries differ."; continue; fi
    printf -v "$__var" '%s' "$__a"; PW_GENERATED=n; return 0
  done
}

# ----------------------------------------------------------------------------
# Validators (print why on failure)
# ----------------------------------------------------------------------------
valid_username() {
  local u=$1 uid
  if [[ ! $u =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    warn "Use lowercase letters, digits, '-' or '_' (start with a letter, max 32)."; return 1
  fi
  if uid=$(id -u "$u" 2>/dev/null) && ! is_human_uid "$uid"; then warn "'$u' is a system account."; return 1; fi
  return 0
}
valid_port_number() {
  [[ $1 =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )) || { warn "'$1' is not a port (1-65535)."; return 1; }
}
valid_port() { # a port sshd may use: free, or already used by sshd itself
  valid_port_number "$1" || return 1
  local used line
  used=$(ss -Htlnp "( sport = :$((10#$1)) )" 2>/dev/null || true)
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    # sshd itself, systemd's ssh.socket, or our GitLab gateway (it lets go of SSH ports)
    [[ $line == *'"sshd"'* || $line == *'"systemd"'* || $line == *" $GITLAB_IP:"* ]] && continue
    warn "Port $1 is already used by another program."; return 1
  done <<<"$used"
  return 0
}
valid_ssh_ports() {
  local p seen=" "
  [[ -n $1 ]] || { warn "Enter at least one port."; return 1; }
  for p in $1; do
    valid_port "$p" || return 1
    p=$((10#$p))
    [[ $seen != *" $p "* ]] || { warn "Port $p is listed twice."; return 1; }
    seen+="$p "
  done
  return 0
}
valid_port_list_or_empty() { local p; for p in $1; do valid_port_number "$p" || return 1; done; return 0; }
valid_hostname() { [[ $1 =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || { warn "Use letters, digits and '-' (one label, e.g. claude-dev)."; return 1; }; }
valid_gitlab_hosts() {
  local h
  for h in $1; do
    [[ $h =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]] || { warn "'$h' is not a hostname (e.g. gitlab.local or gitlab.company.com)."; return 1; }
  done
  return 0
}
is_private_ipv4() { [[ $1 =~ ^(10\.|127\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.) ]]; }

public_ipv4_of() { # public DNS answer for a name, ignoring /etc/hosts (needs dig)
  local ns="" f out
  command -v dig >/dev/null || return 1
  for f in /run/systemd/resolve/resolv.conf /etc/resolv.conf; do
    [[ -r $f ]] || continue
    ns=$(awk '$1 == "nameserver" && $2 !~ /^127\./ {print $2; exit}' "$f")
    [[ -n $ns ]] && break
  done
  [[ -n $ns ]] || return 1
  out=$(dig +short +time=2 +tries=1 "@$ns" "$1" A 2>/dev/null || true)
  out=$(grep -E '^[0-9]+(\.[0-9]+){3}$' <<<"$out" || true)
  [[ -n $out ]] || return 1
  printf '%s' "${out%%$'\n'*}"
}
valid_timezone() { [[ -n $1 && $1 != *..* && -f /usr/share/zoneinfo/$1 ]] || { warn "Unknown timezone (examples: UTC, Europe/Berlin, Asia/Tehran)."; return 1; }; }
valid_node_major() { [[ $1 =~ ^[0-9]{2}$ ]] && (( $1 >= 20 )) || { warn "Enter a Node.js major version such as 22 or 24."; return 1; }; }
valid_ip_list() {
  local t
  for t in $1; do [[ $t =~ ^[0-9A-Fa-f:.]+(/[0-9]{1,3})?$ ]] || { warn "'$t' is not an IP or CIDR."; return 1; }; done
  return 0
}

# normalize_pubkey <authorized_keys line> - prints "type base64 [comment]" or fails.
# Strips authorized_keys options (e.g. cloud images' command="..." on root's keys).
normalize_pubkey() {
  local line re key tmp fp bits
  line=$(trim "${1//$'\r'/}")
  [[ -n $line && $line != \#* && $line != *"PRIVATE KEY"* ]] || return 1
  re='((sk-)?(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521))(@openssh\.com)?[[:space:]]+[A-Za-z0-9+/]+={0,3}([[:space:]]+[^[:space:]].*)?)$'
  [[ $line =~ $re ]] || return 1
  key=${BASH_REMATCH[1]}
  tmp=$(mktemp)
  printf '%s\n' "$key" >"$tmp"
  if ! fp=$(ssh-keygen -l -f "$tmp" 2>/dev/null); then rm -f "$tmp"; return 1; fi
  rm -f "$tmp"
  bits=${fp%% *}
  if [[ $key == ssh-rsa* ]] && (( bits < 2048 )); then warn "RSA keys must be at least 2048 bits."; return 1; fi
  printf '%s\n' "$key"
}

# resolve_keys <spec> - a pasted public key, or copy:<user> (that user's authorized_keys).
resolve_keys() {
  local spec=$1 line key home out=()
  if [[ $spec == copy:* ]]; then
    home=$(home_of "${spec#copy:}") || { warn "No user '${spec#copy:}'."; return 1; }
    [[ -r $home/.ssh/authorized_keys ]] || { warn "$home/.ssh/authorized_keys not found."; return 1; }
    while IFS= read -r line || [[ -n $line ]]; do
      if key=$(normalize_pubkey "$line"); then out+=("$key"); fi
    done <"$home/.ssh/authorized_keys"
  elif key=$(normalize_pubkey "$spec"); then
    out+=("$key")
  fi
  (( ${#out[@]} > 0 )) || return 1
  printf '%s\n' "${out[@]}"
}

# collect_keys <user> [require-new] - sets KEYS_OUT to key lines, "generate", or "" (keep existing)
collect_keys() {
  local u=$1 require_new=${2:-n} spec has_keys=n home
  if home=$(home_of "$u") && [[ -s $home/.ssh/authorized_keys ]]; then has_keys=y; fi
  local hint="paste a public key, 'generate', or 'copy:<user>'"
  [[ $has_keys == y && $require_new == n ]] && hint+=", empty = keep existing keys"
  while :; do
    prompt spec "SSH key for $u ($hint)" "" accept_any
    if [[ -z $spec ]]; then
      if [[ $has_keys == y && $require_new == n ]]; then KEYS_OUT=""; return 0; fi
      warn "A key is required (password login over SSH is disabled)."; continue
    fi
    if [[ $spec == generate ]]; then KEYS_OUT=generate; return 0; fi
    if KEYS_OUT=$(resolve_keys "$spec"); then return 0; fi
    warn "That is not a valid SSH public key (expected 'ssh-ed25519 AAAA... comment')."
  done
}

# ----------------------------------------------------------------------------
# State
# ----------------------------------------------------------------------------
load_config() {
  if [[ -f $CONF_FILE ]]; then
    # shellcheck source=/dev/null
    . "$CONF_FILE"
  fi
  if [[ -z $SSH_PORTS && -n ${SSH_PORT-} ]]; then SSH_PORTS=$SSH_PORT; fi   # config from 2.0
}

init_state() {
  install -d -m 700 "$STATE_DIR"
  [[ -f $LOG_FILE ]] || install -m 600 /dev/null "$LOG_FILE"
  load_config
}

save_config() {
  local tmp k
  tmp=$(mktemp "$STATE_DIR/.config.XXXXXX")
  {
    printf '# vps-setup %s state - written by the script, edit with care\n' "$SCRIPT_VERSION"
    for k in ADMIN_USER SSH_PORTS NODE_MAJOR INSTALL_DOCKER RDP_ENABLED OPEN_WEB AUTO_REBOOT TRUSTED_IPS \
             GITLAB_HOST GITLAB_SSH_PORT GITLAB_PORTS GITLAB_DIRECT FORWARDS FORWARDS_USER APPS SETUP_DONE; do
      printf '%s=%q\n' "$k" "${!k-}"
    done
  } >"$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$CONF_FILE"
}

begin_run() { install -m 600 /dev/null "$RUN_NOTES"; install -m 600 /dev/null "$RUN_CREDS"; }
end_run() {
  local rc=$?
  # After anything that changed users or services: the report and the user sheets follow.
  if [[ -n $REFRESH_FOR && $SETUP_DONE == y ]]; then
    if ( refresh_files "$REFRESH_FOR" ) >>"$LOG_FILE" 2>&1; then
      if (( rc == 0 )); then info "Updated: $REPORT_FILE and $USERS_DIR/<user>.txt"; fi
    else
      warn "Could not update $REPORT_FILE / $USERS_DIR (see $LOG_FILE)."
    fi
  fi
  rm -f "$RUN_CREDS"
}

note_cred() { # note_cred <user> <what> <value>
  install -d -m 700 "$CRED_DIR"
  local f="$CRED_DIR/$1.txt"
  printf '%s  %-16s %s\n' "$(date '+%F %T')" "$2" "$3" >>"$f"
  chmod 600 "$f"
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$RUN_CREDS"
}

print_credentials() {
  [[ -s $RUN_CREDS ]] || return 0
  step "Credentials created now (also in $CRED_DIR - hand them over privately, then delete that folder)"
  local u w v
  while IFS=$'\t' read -r u w v; do printf '    %-16s %-16s %s\n' "$u" "$w" "$v"; done <"$RUN_CREDS"
}

check_os() {
  local id ver
  id=$(. /etc/os-release && printf '%s' "${ID-}")
  ver=$(. /etc/os-release && printf '%s' "${VERSION_ID-}")
  [[ $id == ubuntu ]] || die "This script supports Ubuntu only (found '$id')."
  case $ver in
    22.04|24.04|26.04) ;;
    *) warn "Ubuntu $ver has not been tested with this script." ;;
  esac
  command -v systemctl >/dev/null || die "systemd is required."
}

install_self() {
  local src
  src=$(readlink -f "${BASH_SOURCE[0]}")
  [[ -f $src ]] || die "Save the script to a file and run it from there (sudo bash vps-setup.sh)."
  if [[ $src != "$INSTALL_PATH" ]]; then
    # world-executable on purpose: without sudo it only explains how to run it - every
    # command that changes something still requires root
    install -m 0755 -o root -g root "$src" "$INSTALL_PATH"
    info "Installed management command: $INSTALL_PATH (use it as: sudo vps-setup ...)"
  fi
  chmod 0755 "$INSTALL_PATH"
  ln -sfn "$INSTALL_PATH" /usr/local/bin/vps-setup   # found even with an unusual sudo secure_path
}

# ----------------------------------------------------------------------------
# Users
# ----------------------------------------------------------------------------
ensure_group() { getent group "$1" >/dev/null || groupadd --system "$1"; }

ensure_user() { # ensure_user <user> <admin|dev>
  local u=$1 role=$2 home
  if id "$u" &>/dev/null; then
    info "User $u exists - updating it."
  else
    useradd --create-home --user-group --shell /bin/bash "$u"
    ok "Created user $u"
  fi
  home=$(home_of "$u")
  [[ -d $home && ! -L $home ]] || die "Home directory of $u ($home) is missing or a symlink."
  chmod 750 "$home"   # other users can't read this user's files or Claude credentials
  # useradd leaves the password field "!" (locked). With UsePAM no, sshd then refuses every
  # login - keys included ("account is locked"). "*" = no password, without locking the account.
  # A password an admin locked on purpose ("!$6$...") is left alone.
  if [[ $(getent shadow "$u" | cut -d: -f2) =~ ^!+\*?$ ]]; then usermod -p '*' "$u"; fi
  usermod -aG "$SSH_GROUP" "$u"
  if [[ $role == admin ]]; then
    usermod -aG sudo "$u"
    if in_group "$u" "$DEV_GROUP"; then gpasswd -d "$u" "$DEV_GROUP" >/dev/null; fi
  else
    usermod -aG "$DEV_GROUP" "$u"
    if in_group "$u" sudo; then gpasswd -d "$u" sudo >/dev/null; warn "Removed $u from the sudo group (developers get no sudo)."; fi
    if sudo -l -U "$u" 2>/dev/null | grep -qE '\(ALL( : ALL)?\) (NOPASSWD: )?ALL'; then
      warn "$u still has full sudo through another file in /etc/sudoers.d - remove it there."
    fi
  fi
  setup_user_env "$u"
}

# Everything written into a home directory is written AS that user (never by root),
# so a symlink planted in a home can't redirect a root write.
setup_user_env() {
  local u=$1 home
  home=$(home_of "$u")
  runuser -u "$u" -- mkdir -p "$home/projects" "$home/.local/bin"
  runuser -u "$u" -- sh -c 'umask 077; mkdir -p "$1/.ssh"; chmod 700 "$1/.ssh"' sh "$home"
  # nvm refuses to work with an npm 'prefix' (an earlier version of this script set one);
  # with nvm, 'npm install -g' already installs into the user's home.
  if runuser -u "$u" -- grep -qsxF "prefix=$home/.npm-global" "$home/.npmrc"; then
    runuser -u "$u" -- sed -i "\\|^prefix=$home/.npm-global\$|d" "$home/.npmrc"
  fi
  runuser -u "$u" -- env HOME="$home" git config --global init.defaultBranch main
  loginctl enable-linger "$u" 2>/dev/null || true   # tmux / Claude keep running after logout
}

add_authorized_keys() { # add_authorized_keys <user> <key>...
  local u=$1 home ak k; shift
  home=$(home_of "$u")
  ak="$home/.ssh/authorized_keys"
  runuser -u "$u" -- sh -c 'umask 077; mkdir -p "$1/.ssh"; chmod 700 "$1/.ssh"; touch "$1/.ssh/authorized_keys"; chmod 600 "$1/.ssh/authorized_keys"' sh "$home"
  for k in "$@"; do
    [[ -n $k ]] || continue
    if ! runuser -u "$u" -- grep -qxF -- "$k" "$ak"; then
      printf '%s\n' "$k" | runuser -u "$u" -- tee -a "$ak" >/dev/null
    fi
  done
}

generate_key_for() { # private key goes to $CRED_DIR only - never left on the server for the user
  local u=$1 tmp
  tmp=$(mktemp -d)
  ssh-keygen -q -t ed25519 -N '' -C "$u@$(hostname -s)" -f "$tmp/key"
  add_authorized_keys "$u" "$(cat "$tmp/key.pub")"
  install -d -m 700 "$CRED_DIR"
  install -m 600 "$tmp/key" "$CRED_DIR/$u.id_ed25519"
  rm -rf "$tmp"
  note_cred "$u" "ssh private key" "$CRED_DIR/$u.id_ed25519"
}

apply_keys() { # apply_keys <user> <key lines | generate | "">
  local keys=()
  case $2 in
    "") ;;
    generate) generate_key_for "$1" ;;
    *) mapfile -t keys <<<"$2"; add_authorized_keys "$1" "${keys[@]}" ;;
  esac
}

set_password() { # set_password <user> <password> <generated:y|n>
  chpasswd <<<"$1:$2"
  if [[ $3 == y ]]; then note_cred "$1" "password" "$2"; fi
}

install_claude_for() { # returns 1 when it could not be installed
  local u=$1 v
  if ! runuser -l "$u" -c 'command -v claude' >/dev/null 2>&1; then
    info "Installing Claude Code for $u (into ~/.local, no root)..."
    printf '\n$ [as %s] claude.ai/install.sh\n' "$u" >>"$LOG_FILE"
    if ! runuser -l "$u" -c 'curl -fsSL https://claude.ai/install.sh | bash' >>"$LOG_FILE" 2>&1 \
       || ! runuser -l "$u" -c 'command -v claude' >/dev/null 2>&1; then
      if ! command -v npm >/dev/null || ! runuser -l "$u" -c 'npm install -g @anthropic-ai/claude-code' >>"$LOG_FILE" 2>&1; then
        warn "Could not install Claude Code for $u. They can run: curl -fsSL https://claude.ai/install.sh | bash"
        return 1
      fi
    fi
  fi
  v=$(runuser -l "$u" -c 'claude --version' 2>/dev/null | head -n1 || true)
  note "Claude Code for $u: ${v:-installed}"
}

# ----------------------------------------------------------------------------
# Developers have no root at all: they install tools without sudo (npm -g, pipx,
# ~/.local/bin) and use their rootless Docker; the admin installs system packages.
# remove_dev_apt cleans up the dev-apt helper an earlier version of this script installed.
# ----------------------------------------------------------------------------
remove_dev_apt() {
  local f
  for f in /etc/sudoers.d/50-vps-setup-devs /usr/local/sbin/dev-apt /etc/vps-setup/dev-apt.deny; do
    if [[ -e $f ]]; then rm -f "$f"; note "Removed $f (developers no longer get any sudo command)."; fi
  done
}

# ----------------------------------------------------------------------------
# System configuration
# ----------------------------------------------------------------------------
migrate_v1() { # clean up what the first version of this script left behind
  local f=/etc/sudoers.d/020-dev-limited u
  if [[ -f $f ]]; then
    backup_file "$f"; rm -f "$f"
    note "Removed $f (old script): its apt/npm/node/pip sudo rules gave every 'dev' user full root."
    if getent group dev >/dev/null; then note "Old 'dev' group members: $(getent group dev | cut -d: -f4) - enrol them with: vps-setup add-user <name>"; fi
  fi
  f=/etc/systemd/system/vncserver@.service
  if [[ -f $f ]] && grep -q 'Remote desktop service (VNC)' "$f"; then
    for u in $(systemctl list-units --all --plain --no-legend 'vncserver@*' 2>/dev/null | awk '{print $1}') \
             $(find /etc/systemd/system -name 'vncserver@*.service' -type l -printf '%f\n' 2>/dev/null); do
      systemctl disable --now "$u" >>"$LOG_FILE" 2>&1 || true
    done
    backup_file "$f"; rm -f "$f"; systemctl daemon-reload
    note "Stopped the old VNC desktops (they listened on TCP, reachable by every user). Re-enable: vps-setup vnc enable <user>"
  fi
  retire_tigervnc
  if command -v ufw >/dev/null; then
    for u in 3389 5901 5902 5903 5904 5905; do ufw delete allow "$u/tcp" >>"$LOG_FILE" 2>&1 || true; done
  fi
  if [[ -f /etc/xrdp/xrdp.ini ]]; then xrdp_bind_localhost; fi
}

# retire_tigervnc [<user>] - stop the desktops of Ubuntu's own tigervncserver@:N units (mapped in
# /etc/tigervnc/vncserver.users) for everyone, or for that user plus the leftovers that can never
# run (mapped to a user who no longer exists, or not mapped at all). They listen on TCP 590N, which
# every user on the server can reach, and a second desktop next to vps-vnc@ breaks single-instance
# apps: Chrome or VS Code started on one desktop only open their windows on the other.
retire_tigervnc() {
  local only=${1-} f=/etc/tigervnc/vncserver.users unit disp name stopped=() retired=()
  local -A owner=()
  if [[ -f $f ]]; then
    while IFS='=' read -r disp name; do
      disp=${disp//[[:space:]]/}; name=${name//[[:space:]]/}
      [[ $disp =~ ^:[0-9]+$ && -n $name ]] && owner[$disp]=$name
    done < <(grep -E '^[[:space:]]*:[0-9]+[[:space:]]*=' "$f" || true)
  fi
  # every unit that is mapped, enabled or running
  for unit in $( { systemctl list-units --all --plain --no-legend 'tigervncserver@*' 2>/dev/null | awk '{print $1}'
                   find /etc/systemd/system -name 'tigervncserver@*.service' -type l -printf '%f\n' 2>/dev/null
                   for disp in "${!owner[@]}"; do echo "tigervncserver@$disp.service"; done; } | sort -u ); do
    disp=${unit#tigervncserver@}; disp=${disp%.service}
    name=${owner[$disp]-}
    if [[ -n $only && -n $name && $name != "$only" ]] && id "$name" &>/dev/null; then continue; fi
    [[ $disp =~ ^:[0-9]+$ ]] && retired+=("$disp")
    if systemctl is-enabled --quiet "$unit" 2>/dev/null || systemctl is-active --quiet "$unit" 2>/dev/null; then
      systemctl disable --now "$unit" >>"$LOG_FILE" 2>&1 || true
      stopped+=("$disp${owner[$disp]:+ (${owner[$disp]})}")
    fi
  done
  if [[ -f $f && ${#retired[@]} -gt 0 ]]; then
    local re="^[[:space:]]*($(IFS='|'; echo "${retired[*]}"))[[:space:]]*="
    if grep -qE "$re" "$f"; then
      backup_file "$f"
      sed -i -E "/$re/s/^(.*)$/# \\1   # retired by vps-setup - use: vps-setup vnc enable <user>/" "$f"
    fi
  fi
  if (( ${#stopped[@]} > 0 )); then
    note "Stopped the old TigerVNC desktops ${stopped[*]}: they listened on TCP, reachable by every user,"
    note "  and made Chrome/VS Code open on the wrong desktop. Per user instead: vps-setup vnc enable <user>"
  fi
}

apply_hostname_timezone() {
  [[ $(hostname) == "$NEW_HOSTNAME" ]] || hostnamectl set-hostname "$NEW_HOSTNAME"
  if grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
    sed -i -E "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1 $NEW_HOSTNAME/" /etc/hosts
  else
    printf '127.0.1.1 %s\n' "$NEW_HOSTNAME" >>/etc/hosts
  fi
  # cloud-init must not reset the hostname or rewrite /etc/hosts (gitlab.local lives there)
  if [[ -d /etc/cloud/cloud.cfg.d ]]; then printf 'preserve_hostname: true\nmanage_etc_hosts: false\n' >/etc/cloud/cloud.cfg.d/99-vps-setup.cfg; fi
  timedatectl set-timezone "$TIMEZONE"
  timedatectl set-ntp true >>"$LOG_FILE" 2>&1 || true
  note "Hostname $NEW_HOSTNAME, timezone $TIMEZONE"
}

apply_system_tuning() {
  cat >/etc/sysctl.d/90-vps-setup.conf <<'EOF'
# Managed by vps-setup
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.tcp_syncookies = 1
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
# VS Code watches every file of every open project, for every user
fs.inotify.max_user_watches = 1048576
fs.inotify.max_user_instances = 1024
vm.swappiness = 10
EOF
  sysctl --system >>"$LOG_FILE" 2>&1 || warn "Some sysctl settings were not accepted (see log)."

  install -d /etc/systemd/journald.conf.d
  printf '[Journal]\nSystemMaxUse=1G\n' >/etc/systemd/journald.conf.d/90-vps-setup.conf
  systemctl restart systemd-journald

  ensure_swap

  cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
  cat >/etc/apt/apt.conf.d/52vps-setup-unattended <<EOF
// Managed by vps-setup
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "$([[ $AUTO_REBOOT == y ]] && echo true || echo false)";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
EOF
  systemctl enable --now unattended-upgrades >>"$LOG_FILE" 2>&1 || true
  if [[ -d /etc/needrestart ]]; then
    install -d /etc/needrestart/conf.d
    printf "# Managed by vps-setup: restart services without asking\n\$nrconf{restart} = 'a';\n" >/etc/needrestart/conf.d/90-vps-setup.conf
  fi
  ok "Kernel/network hardening, journald cap, security auto-updates"
}

# ----------------------------------------------------------------------------
# Fair sharing between users - no fixed limits
#   CPU and disk I/O: equal weights per user. Alone, a user can use 100%; when several
#   are busy at the same time, each gets an equal part, adjusted continuously.
#   Memory: the kernel has no weights for memory, so vps-fairshare.timer gives each
#   ACTIVE user a protected part (MemoryLow = 80% of RAM / active users) every 30 s.
#   Under memory pressure, users above their part are reclaimed/swapped first.
#   All users together stay below 95% of RAM, so sshd and the system always keep room.
# ----------------------------------------------------------------------------
render_fairshare() {
  cat <<'EOF'
#!/bin/bash
# fairshare - managed by vps-setup; run every 30 s by vps-fairshare.timer.
# Gives every ACTIVE user (one running anything besides its systemd user manager) an
# equal protected part of the RAM: MemoryLow = 80% of RAM / active users. Idle users get
# no protection, so one active user is protected for everything.
#   fairshare            apply      fairshare --dry-run    only show the numbers
set -euo pipefail
shopt -s nullglob
dry=n; [[ ${1-} == --dry-run ]] && dry=y
cg=/sys/fs/cgroup/user.slice
[[ -d $cg ]] || { echo "fairshare: no cgroup v2 user.slice" >&2; exit 0; }
total=$(awk '/^MemTotal:/ {print $2 * 1024}' /proc/meminfo)
uids=() active=()
for d in "$cg"/user-*.slice; do
  uid=${d##*/user-}; uid=${uid%.slice}
  [[ $uid =~ ^[0-9]+$ ]] && (( uid >= 1000 && uid < 60000 )) || continue
  uids+=("$uid")
  procs=$(ps -u "$uid" -o comm= 2>/dev/null || true)
  # an idle rootless Docker daemon doesn't make a user "active" - running containers do
  if [[ -n $procs ]] && grep -qvxE 'systemd|\(sd-pam\)|dbus-daemon|dockerd|containerd|rootlesskit|exe|slirp4netns' <<<"$procs"; then active+=("$uid"); fi
done
n=${#active[@]}
share=0; (( n > 0 )) && share=$(( total * 80 / 100 / n ))
for uid in "${uids[@]}"; do
  want=0; [[ " ${active[*]} " == *" $uid "* ]] && want=$share
  d="$cg/user-$uid.slice"
  cur=$(cat "$d/memory.low" 2>/dev/null || echo 0); [[ $cur =~ ^[0-9]+$ ]] || cur=0
  used=$(cat "$d/memory.current" 2>/dev/null || echo 0)
  if [[ $dry == y ]]; then
    printf '%-16s %-7s used %6d MB   protected %6d MB\n' "$(getent passwd "$uid" | cut -d: -f1)" \
      "$([[ $want -gt 0 ]] && echo active || echo idle)" $(( used / 1048576 )) $(( want / 1048576 ))
    continue
  fi
  diff=$(( cur > want ? cur - want : want - cur ))
  if (( diff > 64 * 1048576 || (want == 0 && cur != 0) )); then
    # a user may log out between the scan and here - keep going with the others
    systemctl set-property --runtime "user-$uid.slice" MemoryLow="$want" 2>/dev/null || true
  fi
done
EOF
}

apply_fair_share() {
  [[ -f /sys/fs/cgroup/cgroup.controllers ]] || die "This VPS has no cgroup v2 (old kernel/container) - fair sharing is not possible here."
  install -d /etc/systemd/system/user-.slice.d /etc/systemd/system/user.slice.d
  cat >/etc/systemd/system/user-.slice.d/90-vps-setup.conf <<'EOF'
# Managed by vps-setup: every user has the same weight. Weights only matter when the
# server is busy - an idle server lets one user use 100%.
[Slice]
CPUWeight=100
IOWeight=100
EOF
  cat >/etc/systemd/system/user.slice.d/90-vps-setup.conf <<'EOF'
# Managed by vps-setup: all users together - room is always left for sshd and the system,
# and the users' memory is protected from system services (shared out by vps-fairshare).
[Slice]
MemoryMax=95%
MemoryLow=80%
EOF
  install -d -m 755 "$LIB_DIR"
  render_fairshare >"$LIB_DIR/fairshare"; chmod 755 "$LIB_DIR/fairshare"
  cat >/etc/systemd/system/vps-fairshare.service <<EOF
# Managed by vps-setup
[Unit]
Description=Share memory protection equally between active users

[Service]
Type=oneshot
ExecStart=$LIB_DIR/fairshare
EOF
  cat >/etc/systemd/system/vps-fairshare.timer <<'EOF'
# Managed by vps-setup
[Unit]
Description=Re-balance memory protection between active users every 30 s

[Timer]
OnBootSec=30s
OnUnitActiveSec=30s
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now vps-fairshare.timer >>"$LOG_FILE" 2>&1
  systemctl start vps-fairshare.service
  note "Fair sharing (no fixed limits): any user may use ALL free CPU and RAM. Only when users"
  note "  compete at the same moment does each get an equal part, and unused parts go to whoever"
  note "  needs them. Memory: each active user's protected part is re-balanced every 30 s;"
  note "  all users together stay below 95% of RAM so sshd always has room."
  local sched
  sched=$(cat /sys/block/[vsx]d[a-z]/queue/scheduler /sys/block/nvme*/queue/scheduler 2>/dev/null || true)
  if [[ $sched != *"[bfq]"* ]]; then
    note "  (disk: equal disk weights need the BFQ I/O scheduler; this VPS's disks don't use it, so disk sharing is best-effort)"
  fi
}

ensure_swap() {
  if [[ -n $(swapon --noheadings --show 2>/dev/null) ]]; then info "Swap already active."; return 0; fi
  if [[ -e /swapfile ]]; then warn "/swapfile exists but is not active - leaving it alone."; return 0; fi
  local mem_mb size_mb avail_mb
  mem_mb=$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)
  size_mb=$(( mem_mb < 2048 ? 2048 : (mem_mb > 4096 ? 4096 : mem_mb) ))
  avail_mb=$(df -Pm / | awk 'NR == 2 {print $4}')
  if (( avail_mb < size_mb + 4096 )); then warn "Not enough free disk for a ${size_mb} MB swap file - skipped."; return 0; fi
  if ! { fallocate -l "${size_mb}M" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count="$size_mb" status=none; }; then
    rm -f /swapfile; warn "Could not create /swapfile - skipped."; return 0
  fi
  chmod 600 /swapfile
  mkswap /swapfile >>"$LOG_FILE" 2>&1
  if ! swapon /swapfile 2>>"$LOG_FILE"; then rm -f /swapfile; warn "This VPS does not allow swap - skipped."; return 0; fi
  grep -qE '^/swapfile[[:space:]]' /etc/fstab || printf '/swapfile none swap sw 0 0\n' >>/etc/fstab
  note "Created a ${size_mb} MB swap file."
}

# ----------------------------------------------------------------------------
# Memory guard - what acts when the RAM runs out (fair sharing only decides who goes first)
#   zswap: a page leaving RAM is first compressed in RAM (about 3:1), so far less goes to the
#     swap file and it comes back without disk I/O.
#   systemd-oomd: when one user's memory pressure stays high (the desktop freezes, everything
#     waits on swap) or swap is nearly full, it ends that user's heaviest unit - one app, a tmux
#     session, or the user's whole VNC desktop (its apps run inside vps-vnc@<user>; a fresh one
#     starts) - instead of letting the whole server crawl. Never sshd or system services.
# ----------------------------------------------------------------------------
render_zswap() {
  cat <<'EOF'
#!/bin/bash
# zswap - managed by vps-setup; run at boot by vps-zswap.service.
p=/sys/module/zswap/parameters
[[ -d $p ]] || { echo "zswap: not in this kernel - skipped" >&2; exit 0; }
for z in zsmalloc z3fold zbud; do echo "$z" >"$p/zpool" 2>/dev/null && break; done
for c in zstd lz4 lzo; do echo "$c" >"$p/compressor" 2>/dev/null && break; done
echo 20 >"$p/max_pool_percent"
echo Y >"$p/enabled"
echo "zswap on: $(cat "$p/compressor")/$(cat "$p/zpool"), up to $(cat "$p/max_pool_percent")% of RAM"
EOF
}

apply_memory_guard() {
  install -d -m 755 "$LIB_DIR"
  render_zswap >"$LIB_DIR/zswap"; chmod 755 "$LIB_DIR/zswap"
  cat >/etc/systemd/system/vps-zswap.service <<EOF
# Managed by vps-setup
[Unit]
Description=Compressed RAM cache in front of the swap file (zswap)
DefaultDependencies=no
After=local-fs.target
Before=swap.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$LIB_DIR/zswap

[Install]
WantedBy=sysinit.target
EOF
  systemctl daemon-reload
  systemctl enable vps-zswap.service >>"$LOG_FILE" 2>&1
  if systemctl restart vps-zswap.service >>"$LOG_FILE" 2>&1; then
    note "zswap: swapped-out memory is compressed in RAM first (less swap file, less disk I/O)."
  else
    warn "zswap could not be switched on (see $LOG_FILE) - the swap file still works as before."
  fi

  if ! command -v oomctl >/dev/null && pkg_available systemd-oomd; then
    run_soft "Installing systemd-oomd" apt_get install systemd-oomd || true
  fi
  if ! command -v oomctl >/dev/null; then
    warn "systemd-oomd is not available here - a full RAM still ends in a slow server and the kernel's OOM killer."
    return 0
  fi
  install -d /etc/systemd/oomd.conf.d /etc/systemd/system/user-.slice.d /etc/systemd/system/user.slice.d \
             /etc/systemd/system/-.slice.d /etc/systemd/system/ssh.service.d
  cat >/etc/systemd/oomd.conf.d/90-vps-setup.conf <<'EOF'
# Managed by vps-setup
[OOM]
SwapUsedLimit=90%
DefaultMemoryPressureLimit=60%
DefaultMemoryPressureDurationSec=30s
EOF
  cat >/etc/systemd/system/user-.slice.d/91-vps-setup-oomd.conf <<'EOF'
# Managed by vps-setup: a user whose apps wait on memory 60% of the time for 30 s loses the
# unit (an app scope, or their whole VNC desktop service) reclaiming the most - not the other
# users, not the server.
[Slice]
ManagedOOMMemoryPressure=kill
ManagedOOMMemoryPressureLimit=60%
EOF
  cat >/etc/systemd/system/user.slice.d/91-vps-setup-oomd.conf <<'EOF'
# Managed by vps-setup: swap above SwapUsedLimit - the user unit using the most swap ends.
[Slice]
ManagedOOMSwap=kill
EOF
  # Ubuntu's package watches the root slice for swap, which would make system services such as
  # sshd candidates - only users' apps are (above).
  cat >/etc/systemd/system/-.slice.d/10-oomd-root-slice-defaults.conf <<'EOF'
# Managed by vps-setup: replaces the package's default - see user.slice.d/91-vps-setup-oomd.conf
[Slice]
ManagedOOMSwap=auto
EOF
  printf '# Managed by vps-setup: never end sshd (and the sessions in it) to free memory\n[Service]\nManagedOOMPreference=omit\n' \
    >/etc/systemd/system/ssh.service.d/90-vps-setup-oomd.conf
  systemctl daemon-reload
  if systemctl enable --now systemd-oomd.service >>"$LOG_FILE" 2>&1 && systemctl restart systemd-oomd.service >>"$LOG_FILE" 2>&1; then
    note "OOM guard (systemd-oomd): when a user's apps thrash or swap is 90% full, that user's heaviest"
    note "  app or whole VNC desktop is ended (journalctl -u systemd-oomd) - never sshd or system services."
  else
    warn "systemd-oomd did not start (see $LOG_FILE)."
  fi
}

cmd_memory() {
  case ${1-apply} in
    apply) apply_memory_guard; ok "Memory guard applied." ;;
    status) ;;
    *) die "usage: vps-setup memory [apply|status]" ;;
  esac
  local p=/sys/module/zswap/parameters
  free -h
  swapon --show
  if [[ -r $p/enabled ]]; then
    info "zswap: enabled=$(cat "$p/enabled") $(cat "$p/compressor")/$(cat "$p/zpool") max $(cat "$p/max_pool_percent")% of RAM"
  fi
  if command -v oomctl >/dev/null && systemctl is-active --quiet systemd-oomd; then
    oomctl 2>/dev/null | grep -E 'Path:|Limit|Pressure Limit|Swap Used' | head -20 || true
  else
    info "systemd-oomd: not running"
  fi
}

apply_shell_defaults() {
  cat >/etc/profile.d/90-vps-setup.sh <<'EOF'
# Managed by vps-setup: tool locations - everything per-user lives in the home, no sudo needed
add_path() { case ":$PATH:" in *":$1:"*) ;; *) [ -d "$1" ] && PATH="$1:$PATH" ;; esac; }
add_path /usr/local/go/bin          # Go (system-wide)
add_path "$HOME/go/bin"             # go install
add_path "$HOME/.npm-global/bin"    # npm -g from an earlier setup
add_path "$HOME/.bun/bin"           # bun
add_path "$HOME/.local/bin"         # pipx, uv, Claude Code, your own binaries
unset -f add_path
export PATH
# Terminals that support 24-bit colour say so in COLORTERM, which SSH does not pass on by
# default. VS Code's terminal on the server (and tmux, see /etc/tmux.conf) always has it.
if [ -z "${COLORTERM-}" ] && [ "${TERM_PROGRAM-}" = vscode ]; then export COLORTERM=truecolor; fi
[ -d "$HOME/.bun" ] && export BUN_INSTALL="$HOME/.bun"
# nvm: the user's default Node in every login shell (VS Code, tmux, Claude Code)
if [ -n "$BASH_VERSION" ] && [ -s "$HOME/.nvm/nvm.sh" ]; then
  export NVM_DIR="$HOME/.nvm"
  . "$NVM_DIR/nvm.sh"
fi
EOF
  if [[ ! -f /etc/tmux.conf ]] || grep -q 'vps-setup' /etc/tmux.conf; then
    cat >/etc/tmux.conf <<'EOF'
# Managed by vps-setup
set -g mouse on
set -g history-limit 100000
set -g default-terminal "tmux-256color"
set -g escape-time 10
set -g set-clipboard on
# Full 24-bit colour (Claude Code, editors) when the terminal you connect from has it
# (VS Code, Windows Terminal, the desktop terminal). Without this tmux turns every
# colour into the nearest of 256, and Claude Code looks washed out.
set -ga update-environment COLORTERM
if-shell 'case "$COLORTERM" in truecolor|24bit) true ;; *) false ;; esac' 'set -as terminal-features ",*:RGB"'
EOF
  fi
  cat >/usr/local/bin/claude-session <<'EOF'
#!/bin/sh
# claude-session [name] - start or re-attach a persistent tmux session.
# Claude keeps working after you disconnect or turn off your computer.
# Detach: Ctrl-b then d.   List sessions: tmux ls
exec tmux new-session -A -s "${1:-claude}"
EOF
  chmod 755 /usr/local/bin/claude-session
  cat >/etc/motd <<'EOF'

  Claude Code dev server (managed by vps-setup)
    claude-session            persistent tmux session - Claude keeps running when you disconnect
    claude                    Claude Code (first run: log in with your own account)
    Installed for you: node/npm (nvm), bun, python/pip/pipx/uv, go, docker (your own)
    npm i -g | pipx install | uv | go install | nvm install <ver>    all without root
    Need a system package (apt)? Ask the admin.
    Internal GitLab           works here like on your PC while your SSH connection is open
    Office services           e.g. http://192.168.2.212:8100 - same, once the admin adds them
                              (sudo vps-setup forward add ...)
    Remote desktop (RDP/VNC), desktop apps (VS Code, VLC, ...): ask the admin

EOF
}

render_fail2ban() { # render_fail2ban <ports csv>
  cat <<EOF
# Managed by vps-setup
[DEFAULT]
bantime = 1h
bantime.increment = true
bantime.maxtime = 1w
findtime = 10m
maxretry = 5
ignoreip = 127.0.0.1/8 ::1 $TRUSTED_IPS

[sshd]
enabled = true
port = $1
backend = systemd
journalmatch = _SYSTEMD_UNIT=ssh.service + _COMM=sshd + _COMM=sshd-session + _COMM=sshd-auth
maxretry = 4
EOF
}

apply_fail2ban() { # apply_fail2ban <port>...
  local ports f=/etc/fail2ban/jail.d/zz-vps-setup.local
  ports=$(uniq_words "$@" | tr ' ' ',')
  render_fail2ban "${ports:-22}" >"$f"
  if fail2ban-client -t >>"$LOG_FILE" 2>&1; then
    systemctl enable fail2ban >>"$LOG_FILE" 2>&1
    systemctl restart fail2ban
  else
    rm -f "$f"; die "fail2ban rejected the generated jail (see log) - fail2ban left on its defaults."
  fi
}

apply_firewall() { # apply_firewall <ssh port>...
  local p
  if [[ ${UFW_RESET:-n} == y ]]; then ufw --force reset >>"$LOG_FILE" 2>&1; fi
  ufw default deny incoming >>"$LOG_FILE"
  ufw default allow outgoing >>"$LOG_FILE"
  for p in "$@"; do ufw allow "$p/tcp" comment 'SSH' >>"$LOG_FILE"; done
  if [[ $OPEN_WEB == y ]]; then
    ufw allow 80/tcp comment 'HTTP' >>"$LOG_FILE"; ufw allow 443/tcp comment 'HTTPS' >>"$LOG_FILE"
  else
    ufw delete allow 80/tcp >>"$LOG_FILE" 2>&1 || true; ufw delete allow 443/tcp >>"$LOG_FILE" 2>&1 || true
  fi
  ufw --force enable >>"$LOG_FILE"
  note "Firewall: incoming blocked except SSH ($*)$([[ $OPEN_WEB == y ]] && echo ', 80, 443'). VNC/RDP/GitLab are never opened."
}

# ----------------------------------------------------------------------------
# Node.js, Docker
# ----------------------------------------------------------------------------
add_apt_key() { # add_apt_key <url> <keyring path> - stored dearmored
  local tmp; tmp=$(mktemp)
  run "Downloading signing key $1" curl -fsSL -o "$tmp" "$1"
  install -d -m 755 /etc/apt/keyrings
  gpg --batch --yes --dearmor -o "$2" "$tmp"
  chmod 644 "$2"; rm -f "$tmp"
}

install_node() {
  local have=""
  if command -v node >/dev/null; then have=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || true); fi
  if [[ $have != "$NODE_MAJOR" ]]; then
    add_apt_key https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key /etc/apt/keyrings/nodesource.gpg
    printf 'deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_%s.x nodistro main\n' "$NODE_MAJOR" \
      >/etc/apt/sources.list.d/nodesource.list
    printf 'Package: nodejs\nPin: origin deb.nodesource.com\nPin-Priority: 600\n' >/etc/apt/preferences.d/nodesource
    run "Refreshing package lists" apt_get update
    run "Installing Node.js $NODE_MAJOR" apt_get install nodejs
  fi
  note "Node.js $(node --version)"
}

# Go: the latest official release, checksum-verified, in /usr/local/go for everyone.
install_go() {
  local out ver arch file want tmp
  arch=$(dpkg --print-architecture)
  out=$(curl -fsSL --max-time 30 'https://go.dev/VERSION?m=text') || die "Could not reach go.dev."
  ver=${out%%$'\n'*}
  [[ $ver =~ ^go[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "Unexpected answer from go.dev: $ver"
  if [[ -x /usr/local/go/bin/go && $(/usr/local/go/bin/go version | awk '{print $3}') == "$ver" ]]; then
    note "Go $ver already installed (/usr/local/go)."
    return 0
  fi
  file="$ver.linux-$arch.tar.gz"
  out=$(curl -fsSL --max-time 60 'https://go.dev/dl/?mode=json') || die "Could not read Go's checksums."
  want=$(python3 -c 'import json,sys
d = json.load(sys.stdin)
print(next(f["sha256"] for r in d for f in r["files"] if f["filename"] == sys.argv[1]))' "$file" <<<"$out") \
    || die "No checksum published for $file."
  tmp=$(mktemp -d)
  run "Downloading $file" curl -fsSL -o "$tmp/$file" "https://go.dev/dl/$file"
  printf '%s  %s\n' "$want" "$tmp/$file" | sha256sum -c --quiet - || { rm -rf "$tmp"; die "Checksum mismatch for $file - not installed."; }
  rm -rf /usr/local/go
  tar -C /usr/local -xzf "$tmp/$file"
  rm -rf "$tmp"
  note "Go $(/usr/local/go/bin/go version | awk '{print $3}') in /usr/local/go (go install puts tools in ~/go/bin, no root)."
}

# Per user, all inside their home: nvm + their default Node (npm -g works without root),
# bun, and uv. Each tool is tried even when another one fails.
install_user_tools_for() {
  local u=$1 home failed=() v
  home=$(home_of "$u")
  if [[ ! -s $home/.nvm/nvm.sh ]]; then
    run_soft "nvm for $u" runuser -l "$u" -c "curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh | bash" || failed+=(nvm)
  fi
  if [[ -s $home/.nvm/nvm.sh ]]; then
    run_soft "Node $NODE_MAJOR for $u (nvm default)" runuser -l "$u" -c \
      ". \"\$HOME/.nvm/nvm.sh\" && nvm install $NODE_MAJOR && nvm alias default $NODE_MAJOR" || failed+=("node $NODE_MAJOR")
  fi
  if [[ ! -x $home/.bun/bin/bun ]]; then
    run_soft "bun for $u" runuser -l "$u" -c 'curl -fsSL https://bun.sh/install | bash' || failed+=(bun)
  fi
  if [[ ! -x $home/.local/bin/uv ]]; then
    run_soft "uv for $u" runuser -l "$u" -c 'pipx install uv' || failed+=(uv)
  fi
  v=$(runuser -l "$u" -c 'printf "node %s, npm %s, bun %s, %s" "$(node -v 2>/dev/null)" "$(npm -v 2>/dev/null)" "$(bun -v 2>/dev/null)" "$(uv --version 2>/dev/null)"' 2>/dev/null || true)
  note "Tools for $u: $v"
  (( ${#failed[@]} == 0 )) || { warn "$u: could not install ${failed[*]}"; return 1; }
}

step_user_tools() { # tries every user, fails at the end if any failed
  local u failed=()
  for u in "$@"; do install_user_tools_for "$u" || failed+=("$u"); done
  (( ${#failed[@]} == 0 )) || die "Some per-user tools could not be installed for: ${failed[*]} (details above)"
}

step_claude() { # tries every user, fails at the end if any failed
  local u failed=()
  for u in "$@"; do install_claude_for "$u" || failed+=("$u"); done
  (( ${#failed[@]} == 0 )) || die "Claude Code could not be installed for: ${failed[*]}"
}

install_docker() {
  local codename arch
  codename=$(. /etc/os-release && printf '%s' "$VERSION_CODENAME")
  arch=$(dpkg --print-architecture)
  if curl -fsI "https://download.docker.com/linux/ubuntu/dists/$codename/Release" >/dev/null 2>&1; then
    install -d -m 755 /etc/apt/keyrings
    run "Downloading Docker's signing key" curl -fsSL -o /etc/apt/keyrings/docker.asc https://download.docker.com/linux/ubuntu/gpg
    chmod 644 /etc/apt/keyrings/docker.asc
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu %s stable\n' "$arch" "$codename" \
      >/etc/apt/sources.list.d/docker.list
    run "Refreshing package lists" apt_get update
    run "Installing Docker CE" apt_get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  else
    warn "Docker's repository has no '$codename' release yet - using Ubuntu's docker.io."
    local pkgs=(docker.io)
    if pkg_available docker-compose-v2; then pkgs+=(docker-compose-v2); fi
    run "Installing Docker (Ubuntu)" apt_get install "${pkgs[@]}"
  fi
  if [[ ! -f /etc/docker/daemon.json ]]; then
    install -d /etc/docker
    # Published ports bind to localhost by default: Docker bypasses UFW, so "-p 8080:80"
    # would otherwise be open to the whole internet.
    cat >/etc/docker/daemon.json <<'EOF'
{
  "ip": "127.0.0.1",
  "log-driver": "local"
}
EOF
  fi
  systemctl enable docker >>"$LOG_FILE" 2>&1
  systemctl restart docker
  usermod -aG docker "$ADMIN_USER"
  note "Docker $(docker --version 2>/dev/null | awk '{print $3}' | tr -d ,): $ADMIN_USER uses the system Docker (docker group = root)."
  docker_rootless_prepare
}

# ----------------------------------------------------------------------------
# Rootless Docker: every developer gets a private Docker daemon running as themselves.
# No root, nobody sees anyone else's containers, published ports stay behind UFW, and
# the containers count towards the user's fair share (they run in the user's slice).
# ----------------------------------------------------------------------------
docker_rootless_prepare() {
  local pkgs=(uidmap dbus-user-session slirp4netns)
  if pkg_available docker-ce-rootless-extras; then pkgs+=(docker-ce-rootless-extras); fi
  run "Installing rootless Docker support" apt_get install "${pkgs[@]}"
  command -v dockerd-rootless-setuptool.sh >/dev/null \
    || die "dockerd-rootless-setuptool.sh is missing (Docker's repository was not available) - developers can't get Docker."
  # Ubuntu 24.04+ restricts unprivileged user namespaces with AppArmor; rootlesskit needs them.
  if [[ $(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0) == 1 && -x /usr/bin/rootlesskit ]]; then
    cat >/etc/apparmor.d/usr.bin.rootlesskit <<'EOF'
# Managed by vps-setup: lets rootless Docker create its user namespace
abi <abi/4.0>,
include <tunables/global>

/usr/bin/rootlesskit flags=(unconfined) {
  userns,

  include if exists <local/usr.bin.rootlesskit>
}
EOF
    apparmor_parser -r /etc/apparmor.d/usr.bin.rootlesskit
  fi
  # Containers may get their own CPU/memory limits (docker run --cpus / --memory).
  install -d /etc/systemd/system/user@.service.d
  printf '# Managed by vps-setup\n[Service]\nDelegate=cpu cpuset io memory pids\n' >/etc/systemd/system/user@.service.d/90-vps-setup-delegate.conf
  systemctl daemon-reload
  # Users outside the docker group talk to their own daemon (VS Code and docker CLI read this).
  cat >/etc/profile.d/91-vps-setup-docker.sh <<'EOF'
# Managed by vps-setup: developers use their own rootless Docker
if [ -n "$XDG_RUNTIME_DIR" ] && [ -S "$XDG_RUNTIME_DIR/docker.sock" ]; then
  case " $(id -nG) " in *" docker "*) ;; *) export DOCKER_HOST="unix://$XDG_RUNTIME_DIR/docker.sock" ;; esac
fi
EOF
}

ensure_subids() { # 65536 subordinate uids/gids per user (needed for rootless containers)
  local u=$1 f start opt
  for f in /etc/subuid /etc/subgid; do
    touch "$f"
    grep -q "^$u:" "$f" && continue
    start=$(awk -F: 'BEGIN { m = 100000 } { e = $2 + $3; if (e > m) m = e } END { print m }' "$f")
    opt=--add-subuids; [[ $f == /etc/subgid ]] && opt=--add-subgids
    usermod "$opt" "$start-$((start + 65535))" "$u"
  done
}

docker_rootless_for() { # docker_rootless_for <user>
  local u=$1 uid home i
  uid=$(id -u "$u"); home=$(home_of "$u")
  command -v dockerd-rootless-setuptool.sh >/dev/null || die "Rootless Docker is not installed (run the setup with Docker enabled)."
  ensure_subids "$u"
  loginctl enable-linger "$u" 2>/dev/null || true
  systemctl start "user@$uid.service"
  for i in $(seq 1 20); do
    [[ -S /run/user/$uid/bus ]] && break
    systemctl --user -M "$u@" start dbus.socket >/dev/null 2>&1 || true
    sleep 0.5
  done
  [[ -S /run/user/$uid/bus ]] || die "The user session of $u did not start (needed for rootless Docker)."
  if ! systemctl --user -M "$u@" is-active --quiet docker.service 2>/dev/null; then
    run "Setting up rootless Docker for $u" runuser -u "$u" -- env -i -C "$home" \
      HOME="$home" USER="$u" LOGNAME="$u" PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin \
      XDG_RUNTIME_DIR="/run/user/$uid" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
      dockerd-rootless-setuptool.sh install
  fi
  for i in $(seq 1 30); do [[ -S /run/user/$uid/docker.sock ]] && break; sleep 0.5; done
  [[ -S /run/user/$uid/docker.sock ]] || die "Rootless Docker for $u did not start (journalctl --user -M $u@ -u docker)."
  note "Docker for $u: private rootless Docker (docker / docker compose work as usual, no root)."
}

step_docker_users() { # tries every user, fails at the end if any failed
  local u failed=()
  for u in "$@"; do
    if ! ( docker_rootless_for "$u" ); then failed+=("$u"); fi
  done
  (( ${#failed[@]} == 0 )) || die "Rootless Docker could not be set up for: ${failed[*]}"
}

# ----------------------------------------------------------------------------
# Internal GitLab, reachable on the server like on your PC
#
#   Each developer's PC forwards  ~/.ssh/gitlab-<port>.sock  ->  gitlab.local:<port>
#   (RemoteForward in their ssh config; the socket is 0600, created by sshd as them).
#   On the server, gitlab.local resolves to 127.77.0.1, where vps-gitlab-gw listens on
#   the GitLab ports and carries each connection through the connecting user's own
#   tunnel first, then any other developer's (newest first). A closed tunnel, or one
#   that can't reach GitLab, is skipped - GitLab stays reachable while anyone is on.
# ----------------------------------------------------------------------------
gitlab_ports() { uniq_words "$GITLAB_SSH_PORT" $GITLAB_PORTS; }
gitlab_primary() { local a=(); read -ra a <<<"$GITLAB_HOST"; printf '%s' "${a[0]-}"; }

render_gitlab_gw() {
  cat <<'EOF'
#!/usr/bin/env python3
"""gitlab-gw - managed by vps-setup.

Makes the internal GitLab reachable on this server as if it were local: its hostname(s)
resolve to LISTEN_IP (/etc/hosts) and this gateway listens there on each GitLab port,
and on RUN_DIR/<port>.sock. Every connection is carried through a developer's own SSH
RemoteForward (~/.ssh/gitlab-<port>.sock): the connecting user's own tunnel first, then
everyone else's, newest first, and finally - with --direct HOST - straight to HOST's
public address (looked up in public DNS, not /etc/hosts). A route that is closed, or
open but unable to reach GitLab, is skipped and the next one is used.

usage: gitlab-gw [--direct HOST] [--no-tcp PORT,...] [--home DIR]... LISTEN_IP RUN_DIR PORT [PORT...]
       gitlab-gw --transparent PORT --forward IP:PORT=NAME[@UID,...]... [--home DIR]...
       --no-tcp: ports served on RUN_DIR/<port>.sock only - never on TCP (sshd's ports:
                 holding LISTEN_IP:22 would stop sshd from opening port 22)
       --home:   limit the tunnel search to these home directories (default: all users)
       --transparent: other office services. NAT rules (vps-setup's fwd-nat) send this
                 server's connections to each IP:PORT to 127.0.0.1:PORT; the original
                 destination picks the tunnel ~/.ssh/fwd-NAME-PORT.sock. Nothing is bound
                 on the service's own port, so the same port stays free for local programs.
                 @UID,...: a personal forward - only for those users, and only through
                 each one's OWN tunnel (without it: for everyone, through anyone's tunnel).
"""
import argparse
import os
import pwd
import select
import socket
import stat
import struct
import sys
import threading
import time

PARSER = argparse.ArgumentParser(description="vps-setup GitLab gateway")
PARSER.add_argument("--direct", metavar="HOST")
PARSER.add_argument("--no-tcp", default="")
PARSER.add_argument("--sock-prefix", default="gitlab-")
PARSER.add_argument("--home", action="append", default=[])
PARSER.add_argument("--transparent", type=int, metavar="PORT")
PARSER.add_argument("--forward", action="append", default=[], metavar="IP:PORT=NAME[@UID,...]")
PARSER.add_argument("listen_ip", nargs="?")
PARSER.add_argument("run_dir", nargs="?")
PARSER.add_argument("ports", nargs="*", type=int)
ARGS = PARSER.parse_args()
LISTEN_IP, RUN_DIR, PORTS = ARGS.listen_ip, ARGS.run_dir, ARGS.ports
NO_TCP = {int(p) for p in ARGS.no_tcp.split(",") if p.strip()}
FORWARDS = {}
for spec in ARGS.forward:
    target, _, rest = spec.partition("=")
    fwd_name, _, owners = rest.partition("@")
    fwd_ip, _, fwd_port = target.rpartition(":")
    # (name, None) = for everyone; (name, {uid, ...}) = personal
    FORWARDS[(fwd_ip, int(fwd_port))] = (fwd_name, {int(u) for u in owners.split(",") if u} or None)
if ARGS.transparent is None and not (LISTEN_IP and RUN_DIR and PORTS):
    PARSER.error("LISTEN_IP RUN_DIR PORT... are required (or --transparent)")
PROBE_SECONDS = 3.0
SLOTS = threading.BoundedSemaphore(256)


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def homes():
    if ARGS.home:
        for home in ARGS.home:
            try:
                yield os.stat(home).st_uid, home
            except OSError:
                pass
        return
    for entry in pwd.getpwall():
        if 1000 <= entry.pw_uid < 60000:
            yield entry.pw_uid, entry.pw_dir


def tunnels(sock_name, uid, own_only=False):
    own, others = [], []
    for home_uid, home in homes():
        if own_only and home_uid != uid:
            continue
        path = os.path.join(home, ".ssh", sock_name)
        try:
            st = os.stat(path)
        except OSError:
            continue
        # sshd creates the socket as the user: ignore anything else placed there
        if not stat.S_ISSOCK(st.st_mode) or st.st_uid != home_uid:
            continue
        (own if home_uid == uid else others).append((st.st_mtime, path))
    own.sort(reverse=True)
    others.sort(reverse=True)
    return [p for _, p in own] + [p for _, p in others]


def upstream_dns_servers():
    for path in ("/run/systemd/resolve/resolv.conf", "/etc/resolv.conf"):
        try:
            with open(path) as conf:
                servers = [line.split()[1] for line in conf
                           if line.startswith("nameserver") and len(line.split()) > 1]
        except OSError:
            continue
        servers = [s for s in servers if not s.startswith("127.") and s != "::1"]
        if servers:
            return servers
    return []


def skip_name(data, i):
    while True:
        length = data[i]
        if length == 0:
            return i + 1
        if length & 0xC0 == 0xC0:
            return i + 2
        i += length + 1


def public_ipv4(name):
    """A records for name from the upstream DNS servers (bypasses /etc/hosts)."""
    qid = os.urandom(2)
    qname = b"".join(bytes([len(p)]) + p.encode() for p in name.rstrip(".").split(".")) + b"\0"
    query = qid + b"\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00" + qname + b"\x00\x01\x00\x01"
    for server in upstream_dns_servers():
        family = socket.AF_INET6 if ":" in server else socket.AF_INET
        with socket.socket(family, socket.SOCK_DGRAM) as udp:
            udp.settimeout(2)
            try:
                udp.sendto(query, (server, 53))
                data = udp.recv(4096)
            except OSError:
                continue
        if data[:2] != qid or len(data) < 12:
            continue
        answers = int.from_bytes(data[6:8], "big")
        i = skip_name(data, 12) + 4
        found = []
        for _ in range(answers):
            i = skip_name(data, i)
            rtype = int.from_bytes(data[i:i + 2], "big")
            rdlen = int.from_bytes(data[i + 8:i + 10], "big")
            i += 10
            if rtype == 1 and rdlen == 4:
                found.append(socket.inet_ntoa(data[i:i + 4]))
            i += rdlen
        if found:
            return found
    return []


DIRECT_CACHE = {"at": 0.0, "ips": []}


def direct_ips():
    # re-resolve every 5 min; after a failed lookup, retry after 30 s
    max_age = 300 if DIRECT_CACHE["ips"] else 30
    if ARGS.direct and time.time() - DIRECT_CACHE["at"] > max_age:
        DIRECT_CACHE["ips"] = public_ipv4(ARGS.direct)
        DIRECT_CACHE["at"] = time.time()
    return DIRECT_CACHE["ips"]


def routes(sock_name, uid, direct_port, own_only=False):
    """(label, connect) pairs in the order they are tried."""
    for path in tunnels(sock_name, uid, own_only):
        def via_tunnel(path=path):
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                sock.connect(path)
            except OSError:
                sock.close()
                raise
            return sock
        yield path, via_tunnel
    if direct_port is None:
        return
    for ip in direct_ips():
        yield ("direct %s:%d" % (ip, direct_port),
               (lambda ip=ip: socket.create_connection((ip, direct_port), timeout=5)))


def original_dst(conn):
    """Where a NAT-redirected connection was going (SO_ORIGINAL_DST), or None."""
    try:
        raw = conn.getsockopt(socket.SOL_IP, 80, 16)
    except OSError:
        return None
    return socket.inet_ntoa(raw[4:8]), struct.unpack("!H", raw[2:4])[0]


def tcp_peer_uid(conn):
    """uid of the local process that opened this TCP connection (from /proc/net/tcp)."""
    try:
        host, port = conn.getpeername()[:2]
        want = "%s:%04X" % (socket.inet_aton(host)[::-1].hex().upper(), port)
        with open("/proc/net/tcp") as table:
            next(table)
            for line in table:
                fields = line.split()
                if fields[1] == want:
                    return int(fields[7])
    except (OSError, ValueError, StopIteration):
        pass
    return -1


def unix_peer_uid(conn):
    try:
        creds = conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
        return struct.unpack("3i", creds)[1]
    except OSError:
        return -1


def relay(src, dst):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        try:
            dst.shutdown(socket.SHUT_WR)
        except OSError:
            pass


def handle(client, sock_name, uid, what, direct_port, own_only=False):
    try:
        early = b""
        if select.select([client], [], [], 0.3)[0]:
            early = client.recv(65536)
            if not early:
                return
        for path, connect in routes(sock_name, uid, direct_port, own_only):
            upstream = None
            try:
                upstream = connect()
                upstream.settimeout(None)
                if early:
                    upstream.sendall(early)
                if select.select([upstream], [], [], PROBE_SECONDS)[0]:
                    first = upstream.recv(65536)
                    if not first:
                        raise ConnectionError("tunnel open but %s not reachable through it" % what)
                    client.sendall(first)
            except OSError as err:
                if upstream is not None:
                    upstream.close()
                log("%s uid %d: skipping %s (%s)" % (what, uid, path, err))
                continue
            log("%s uid %d: via %s" % (what, uid, path))
            back = threading.Thread(target=relay, args=(upstream, client), daemon=True)
            back.start()
            relay(client, upstream)
            back.join()
            upstream.close()
            return
        log("%s uid %d: no route (%s%s)"
            % (what, uid, "this user's own tunnel is not open" if own_only else "no developer tunnel",
               ", direct failed" if direct_port is not None and ARGS.direct else ""))
    finally:
        client.close()
        SLOTS.release()


def serve(listener, port, peer_uid):
    while True:
        conn, _ = listener.accept()
        SLOTS.acquire()
        threading.Thread(target=handle, daemon=True, args=(
            conn, "%s%d.sock" % (ARGS.sock_prefix, port), peer_uid(conn), "GitLab port %d" % port, port)).start()


def serve_transparent(listener):
    while True:
        conn, _ = listener.accept()
        dst = original_dst(conn)
        uid = tcp_peer_uid(conn)
        entry = FORWARDS.get(dst) if dst else None
        # only redirected connections from programs on this server (and, for a personal
        # forward, only from its users - the NAT rules already match on the user too)
        if entry is None or uid < 0 or (entry[1] is not None and uid not in entry[1]):
            log("refused a connection to %s from uid %d (not an office service for this user, or not local)" % (dst, uid))
            conn.close()
            continue
        name, owners = entry
        SLOTS.acquire()
        threading.Thread(target=handle, daemon=True, args=(
            conn, "fwd-%s-%d.sock" % (name, dst[1]), uid, "%s:%d" % (name, dst[1]), None,
            owners is not None)).start()


def main_transparent():
    tcp = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    tcp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    tcp.bind(("127.0.0.1", ARGS.transparent))
    tcp.listen(128)
    for (ip, port), (name, owners) in sorted(FORWARDS.items()):
        log("office service %s:%d (%s) via ~/.ssh/fwd-%s-%d.sock, %s" % (
            name, port, ip, name, port,
            "for everyone" if owners is None else "personal: uid " + ",".join(map(str, sorted(owners)))))
    serve_transparent(tcp)


def main():
    if ARGS.transparent is not None:
        main_transparent()
        return
    os.makedirs(RUN_DIR, exist_ok=True)
    servers = []
    for port in PORTS:
        if port in NO_TCP:
            log("port %d is an SSH port of this server - only on %s/%d.sock" % (port, RUN_DIR, port))
        else:
            tcp = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            tcp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                tcp.bind((LISTEN_IP, port))
                tcp.listen(64)
                servers.append((tcp, port, tcp_peer_uid))
                log("listening on %s:%d" % (LISTEN_IP, port))
            except OSError as err:
                tcp.close()
                log("cannot listen on %s:%d (%s) - continuing with the other ports" % (LISTEN_IP, port, err.strerror))
        path = os.path.join(RUN_DIR, "%d.sock" % port)
        unix = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            if os.path.lexists(path):
                os.unlink(path)
            unix.bind(path)
            os.chmod(path, 0o666)
            unix.listen(64)
            servers.append((unix, port, unix_peer_uid))
            log("listening on %s" % path)
        except OSError as err:
            unix.close()
            log("cannot listen on %s (%s)" % (path, err.strerror))
    if not servers:
        log("nothing to listen on")
        sys.exit(1)
    threads = [threading.Thread(target=serve, args=s, daemon=True) for s in servers]
    for t in threads:
        t.start()
    for t in threads:
        t.join()


if __name__ == "__main__":
    main()
EOF
}

render_gitlab_unit() { # render_gitlab_unit [extra SSH ports to keep off TCP]...
  local no_tcp
  no_tcp=$(uniq_words $SSH_PORTS $(current_ssh_ports) "$@" | tr ' ' ',')
  cat <<EOF
# Managed by vps-setup
[Unit]
Description=Internal GitLab gateway ($GITLAB_HOST through the developers' SSH tunnels)
# sshd first: the gateway must never hold a port sshd needs
After=network-online.target ssh.service
Wants=network-online.target

[Service]
ExecStart=/usr/bin/python3 -I $GITLAB_GW $([[ $GITLAB_DIRECT == y ]] && printf -- '--direct %s ' "$(gitlab_primary)")--no-tcp ${no_tcp:-22} $GITLAB_IP $GITLAB_RUN_DIR $(gitlab_ports)
# Unprivileged throwaway user; may only open the users' tunnel sockets and bind low ports.
DynamicUser=yes
AmbientCapabilities=CAP_DAC_OVERRIDE CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_DAC_OVERRIDE CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
RuntimeDirectory=vps-gitlab
RuntimeDirectoryMode=0755
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
RestrictNamespaces=yes
LockPersonality=yes
SystemCallArchitectures=native
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
}

render_gitlab_ssh_client() {
  cat <<EOF
# Managed by vps-setup: git over SSH to the internal GitLab, for every user on this server.
# Carried by vps-gitlab-gw through the developers' SSH tunnels.
Host $GITLAB_HOST
    User git
    ProxyCommand nc -U $GITLAB_RUN_DIR/$GITLAB_SSH_PORT.sock
    HostKeyAlias $(gitlab_primary)
    StrictHostKeyChecking accept-new
    UserKnownHostsFile ~/.ssh/known_hosts_gitlab
EOF
}

gitlab_hosts_entry() { # every GitLab name -> the gateway (overrides public DNS on this server)
  local h re backed=n
  sed -i '/# vps-setup gitlab$/d' /etc/hosts
  for h in $GITLAB_HOST; do
    re=${h//./\\.}
    if grep -qE "^[^#]*[[:space:]]$re([[:space:]]|\$)" /etc/hosts; then
      [[ $backed == y ]] || { backup_file /etc/hosts; backed=y; }
      sed -i -E "s/^([^#]*[[:space:]]$re([[:space:]]|\$).*)/# disabled by vps-setup: \1/" /etc/hosts
      note "/etc/hosts already mapped $h - that line was commented out."
    fi
  done
  printf '%s %s  # vps-setup gitlab\n' "$GITLAB_IP" "$GITLAB_HOST" >>/etc/hosts
}

write_gateway_program() { # shared by the GitLab gateway and the office-services gateway
  install -d -m 755 "$LIB_DIR"
  render_gitlab_gw >"$GITLAB_GW.new"; chmod 755 "$GITLAB_GW.new"; mv -f "$GITLAB_GW.new" "$GITLAB_GW"
}

gitlab_apply() {
  local p tcp=() sock_only=()
  [[ -n $GITLAB_HOST && -n $GITLAB_SSH_PORT ]] || die "No GitLab configured (GITLAB_HOST / GITLAB_SSH_PORT)."
  write_gateway_program
  render_gitlab_unit >"/etc/systemd/system/$GITLAB_UNIT"
  render_gitlab_ssh_client >"$GITLAB_SSH_CLIENT_CONF"; chmod 644 "$GITLAB_SSH_CLIENT_CONF"
  gitlab_hosts_entry
  systemctl daemon-reload
  systemctl enable "$GITLAB_UNIT" >>"$LOG_FILE" 2>&1
  systemctl restart "$GITLAB_UNIT"
  sleep 1
  if ! systemctl is-active --quiet "$GITLAB_UNIT"; then
    journalctl -u "$GITLAB_UNIT" -n 15 --no-pager >&2 || true
    die "The GitLab gateway did not start (see above)."
  fi
  for p in $(gitlab_ports); do
    if [[ -n $(ss -Htln "( src $GITLAB_IP and sport = :$p )" 2>/dev/null) ]]; then tcp+=("$p"); else sock_only+=("$p"); fi
  done
  note "GitLab: $GITLAB_HOST -> $GITLAB_IP on this server; ports ready: ${tcp[*]:-(none)}"
  note "GitLab: git@$(gitlab_primary) works for every user (SSH port $GITLAB_SSH_PORT, through $GITLAB_RUN_DIR)."
  if [[ $GITLAB_DIRECT == y ]]; then note "GitLab: with no developer tunnel up, connections go directly to $(gitlab_primary)'s public address."; fi
  if (( ${#sock_only[@]} > 0 )); then
    note "GitLab: port(s) ${sock_only[*]} are already taken on this server (e.g. by sshd) - continuing with the others; git over SSH is unaffected."
  fi
}

# Called before sshd is restarted with new ports: the gateway lets go of them first.
gitlab_keep_off_ports() {
  [[ -n $GITLAB_HOST && -f /etc/systemd/system/$GITLAB_UNIT ]] || return 0
  render_gitlab_unit "$@" >"/etc/systemd/system/$GITLAB_UNIT"
  systemctl daemon-reload
  systemctl restart "$GITLAB_UNIT" || warn "The GitLab gateway did not restart (journalctl -u $GITLAB_UNIT)."
}

gitlab_disable() {
  systemctl disable --now "$GITLAB_UNIT" >>"$LOG_FILE" 2>&1 || true
  rm -f "/etc/systemd/system/$GITLAB_UNIT" "$GITLAB_SSH_CLIENT_CONF"
  sed -i '/# vps-setup gitlab$/d' /etc/hosts
  systemctl daemon-reload
  GITLAB_HOST="" GITLAB_SSH_PORT="" GITLAB_PORTS="" GITLAB_DIRECT=""; save_config
  ok "GitLab gateway removed."
}

gitlab_tunnels() { # which users currently have a tunnel socket (stale ones included)
  local u home p out=()
  for u in $(server_users); do
    home=$(home_of "$u")
    for p in $(gitlab_ports); do if [[ -S $home/.ssh/gitlab-$p.sock ]]; then out+=("$u:$p"); fi; done
  done
  printf '%s' "${out[*]:-(none)}"
}

# ----------------------------------------------------------------------------
# Other office services (vps-setup forward add 192.168.2.212:8100), like GitLab
#
#   Each developer's PC forwards  ~/.ssh/fwd-<host>-<port>.sock  ->  <host>:<port>.
#   On the server, NAT rules send connections to <host>:<port> (an office IP as it is,
#   a hostname via /etc/hosts -> 127.77.1.<n>) to vps-fwd-gw on 127.0.0.1:47070, which
#   carries them through the connecting user's own tunnel first, then anyone else's.
#   So http://192.168.2.212:8100/docs works on the server as on the PC (shell, Docker,
#   the desktop's browser), and nothing listens on 8100 here - it stays free.
# ----------------------------------------------------------------------------
FWD_LENIENT=n   # y: parse without the network checks (removing an entry)

fwd_parse() { # fwd_parse <host:port | URL> - prints host:port
  local s=${1,,} scheme="" host port a b c d
  if [[ $s == *://* ]]; then scheme=${s%%://*}; s=${s#*://}; fi
  s=${s%%/*}; s=${s%%\?*}; s=${s##*@}
  if [[ $s == *:* ]]; then
    host=${s%:*}; port=${s##*:}
  else
    host=$s
    case $scheme in
      http) port=80 ;; https) port=443 ;;
      *) warn "'$1': give the port too, e.g. $s:8100"; return 1 ;;
    esac
  fi
  if ! [[ $port =~ ^[0-9]{1,5}$ ]] || (( 10#$port < 1 || 10#$port > 65535 )); then warn "'$1': bad port '$port'."; return 1; fi
  port=$((10#$port))
  if [[ $host =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    IFS=. read -r a b c d <<<"$host"
    a=$((10#$a)) b=$((10#$b)) c=$((10#$c)) d=$((10#$d))
    if (( a > 255 || b > 255 || c > 255 || d > 255 )); then warn "'$host' is not an IPv4 address."; return 1; fi
    host="$a.$b.$c.$d"
    if [[ $FWD_LENIENT != y ]]; then fwd_ip_ok "$host" || return 1; fi
  elif [[ $host =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$ ]] && (( ${#host} <= 50 )); then
    if [[ $FWD_LENIENT != y && " $GITLAB_HOST " == *" $host "* ]]; then
      warn "$host is the GitLab host - it is reachable already (vps-setup gitlab)."; return 1
    fi
  else
    warn "'$1': not a hostname (at most 50 characters) or an IPv4 address."; return 1
  fi
  printf '%s:%s' "$host" "$port"
}

fwd_match() { # fwd_match <spec> <host:port>... - the entries a remove request means
  local spec=$1 n="" host e found=n
  shift
  host=${spec,,}; host=${host#*://}; host=${host%%/*}; host=${host%%\?*}; host=${host##*@}
  if [[ $host == *:* ]]; then
    n=$(FWD_LENIENT=y fwd_parse "$spec" 2>/dev/null) || return 0   # an explicit port: exactly that
  else
    n=$(FWD_LENIENT=y fwd_parse "$spec" 2>/dev/null) || n=""       # URL: its default port first
  fi
  for e in "$@"; do if [[ -n $n && $e == "$n" ]]; then printf '%s\n' "$e"; found=y; fi; done
  [[ $found == n && $host != *:* ]] || return 0
  for e in "$@"; do if [[ ${e%:*} == "$host" ]]; then printf '%s\n' "$e"; fi; done   # no port: every port of that host
}

fwd_ip_ok() { # an office address: private, and not on this server's own network
  local a b r
  IFS=. read -r a b _ <<<"$1"
  if ! (( a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168) || (a == 100 && b >= 64 && b <= 127) )); then
    warn "$1 is not a private (office) address - the server reaches public addresses by itself."; return 1
  fi
  r=$(ip -4 route get "$1" 2>/dev/null | head -n 1 || true)
  if [[ $r == local* || ( -n $r && $r != *" via "* ) ]]; then
    warn "$1 is on this server's own network ($r) - forwarding it would cut the server off from it."; return 1
  fi
  return 0
}

valid_forward_list() { local s; for s in $1; do fwd_parse "$s" >/dev/null || return 1; done; return 0; }
fwd_normalize() { local s out=(); for s in $1; do out+=("$(fwd_parse "$s")"); done; uniq_words "${out[@]}"; }
fwd_targets() { # every forwarded host:port, for everyone or personal
  local e per=()
  for e in $FORWARDS_USER; do per+=("${e#*=}"); done
  uniq_words $FORWARDS "${per[@]}"
}
fwd_for_user() { # what <user> gets: the forwards for everyone + their own
  local e own=()
  for e in $FORWARDS_USER; do if [[ ${e%%=*} == "$1" ]]; then own+=("${e#*=}"); fi; done
  uniq_words $FORWARDS "${own[@]}"
}
fwd_scope_of() { # "all" for everyone, else the uids (comma-separated) whose own it is
  local e uids=() IFS
  if [[ " $FORWARDS " == *" $1 "* ]]; then printf 'all'; return 0; fi
  for e in $FORWARDS_USER; do
    if [[ ${e#*=} == "$1" ]] && id -u "${e%%=*}" &>/dev/null; then uids+=("$(id -u "${e%%=*}")"); fi
  done
  IFS=,; printf '%s' "${uids[*]}"
}
fwd_owner_names() { # fwd_owner_names <host:port> - "everyone", or the users
  local e names=()
  if [[ " $FORWARDS " == *" $1 "* ]]; then printf 'everyone'; return 0; fi
  for e in $FORWARDS_USER; do if [[ ${e#*=} == "$1" ]]; then names+=("${e%%=*}"); fi; done
  printf '%s' "${names[*]:-(nobody)}"
}
fwd_hosts() { local s; for s in $(fwd_targets); do printf '%s\n' "${s%:*}"; done | awk '!seen[$0]++'; }
fwd_is_ip() { [[ $1 =~ ^[0-9.]+$ ]]; }

fwd_ip_of() { # the address this server uses for a forwarded host
  local h n=0
  if fwd_is_ip "$1"; then printf '%s' "$1"; return 0; fi
  for h in $(fwd_hosts); do
    fwd_is_ip "$h" && continue
    n=$((n + 1))
    if [[ $h == "$1" ]]; then printf '%s.%d' "$FWD_NAME_NET" "$n"; return 0; fi
  done
  return 1
}

render_fwd_nat() {
  local s
  cat <<EOF
#!/bin/sh
# Managed by vps-setup: this server's own connections to the office services go to the
# forward gateway on 127.0.0.1:$FWD_GW_PORT. Run by $FWD_UNIT (start: apply, stop: clear).
set -e
case "\${1-}" in
  apply)
    iptables -w -t nat -N VPS_FWD 2>/dev/null || iptables -w -t nat -F VPS_FWD
    iptables -w -t nat -C OUTPUT -j VPS_FWD 2>/dev/null || iptables -w -t nat -I OUTPUT 1 -j VPS_FWD
EOF
  local scope uid
  for s in $(fwd_targets); do
    scope=$(fwd_scope_of "$s")
    if [[ $scope == all ]]; then
      printf '    iptables -w -t nat -A VPS_FWD -d %s/32 -p tcp --dport %s -j REDIRECT --to-ports %s\n' \
        "$(fwd_ip_of "${s%:*}")" "${s##*:}" "$FWD_GW_PORT"
    else
      # personal: only that user's own programs (their shell, VS Code, Docker, desktop)
      for uid in ${scope//,/ }; do
        printf '    iptables -w -t nat -A VPS_FWD -d %s/32 -p tcp --dport %s -m owner --uid-owner %s -j REDIRECT --to-ports %s\n' \
          "$(fwd_ip_of "${s%:*}")" "${s##*:}" "$uid" "$FWD_GW_PORT"
      done
    fi
  done
  cat <<'EOF'
    ;;
  clear)
    iptables -w -t nat -F VPS_FWD 2>/dev/null || true
    ;;
  remove)
    iptables -w -t nat -D OUTPUT -j VPS_FWD 2>/dev/null || true
    iptables -w -t nat -F VPS_FWD 2>/dev/null || true
    iptables -w -t nat -X VPS_FWD 2>/dev/null || true
    ;;
  *) echo "usage: fwd-nat apply|clear|remove" >&2; exit 2 ;;
esac
EOF
}

render_fwd_unit() {
  local s args="" scope
  for s in $(fwd_targets); do
    scope=$(fwd_scope_of "$s")
    case $scope in
      all) args+=" --forward $(fwd_ip_of "${s%:*}"):${s##*:}=${s%:*}" ;;
      "") ;;   # its users are gone
      *) args+=" --forward $(fwd_ip_of "${s%:*}"):${s##*:}=${s%:*}@$scope" ;;
    esac
  done
  cat <<EOF
# Managed by vps-setup
[Unit]
Description=Office services through the developers' SSH tunnels (vps-setup forward)
After=network-online.target
Wants=network-online.target

[Service]
# '+': the NAT rules are set with full privileges; the gateway itself runs unprivileged.
ExecStartPre=+$FWD_NAT apply
ExecStart=/usr/bin/python3 -I $GITLAB_GW --transparent $FWD_GW_PORT$args
ExecStopPost=+$FWD_NAT clear
DynamicUser=yes
AmbientCapabilities=CAP_DAC_OVERRIDE
CapabilityBoundingSet=CAP_DAC_OVERRIDE
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
RestrictNamespaces=yes
LockPersonality=yes
SystemCallArchitectures=native
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
}

fwd_hosts_entry() { # office hostnames -> 127.77.1.<n> on this server
  local h re backed=n
  sed -i '/# vps-setup forward$/d' /etc/hosts
  for h in $(fwd_hosts); do
    fwd_is_ip "$h" && continue
    re=${h//./\\.}
    if grep -qE "^[^#]*[[:space:]]$re([[:space:]]|\$)" /etc/hosts; then
      [[ $backed == y ]] || { backup_file /etc/hosts; backed=y; }
      sed -i -E "s/^([^#]*[[:space:]]$re([[:space:]]|\$).*)/# disabled by vps-setup: \1/" /etc/hosts
      note "/etc/hosts already mapped $h - that line was commented out."
    fi
    printf '%s %s  # vps-setup forward\n' "$(fwd_ip_of "$h")" "$h" >>/etc/hosts
  done
}

fwd_apply() {
  if [[ -z $(fwd_targets) ]]; then fwd_disable; return 0; fi
  write_gateway_program
  render_fwd_nat >"$FWD_NAT.new"; chmod 755 "$FWD_NAT.new"; mv -f "$FWD_NAT.new" "$FWD_NAT"
  render_fwd_unit >"/etc/systemd/system/$FWD_UNIT"
  fwd_hosts_entry
  systemctl daemon-reload
  systemctl enable "$FWD_UNIT" >>"$LOG_FILE" 2>&1
  systemctl restart "$FWD_UNIT"
  sleep 1
  if ! systemctl is-active --quiet "$FWD_UNIT"; then
    journalctl -u "$FWD_UNIT" -n 15 --no-pager >&2 || true
    die "The office-services gateway did not start (see above)."
  fi
  iptables -w -t nat -S VPS_FWD 2>/dev/null | grep -q REDIRECT || die "The NAT rules for the office services are missing (iptables -t nat -S VPS_FWD)."
  note "Office services for everyone (while any developer is connected): ${FORWARDS:-(none)}"
  if [[ -n $FORWARDS_USER ]]; then note "Personal office services (while that user is connected): $FORWARDS_USER"; fi
}

fwd_disable() {
  systemctl disable --now "$FWD_UNIT" >>"$LOG_FILE" 2>&1 || true
  if [[ -x $FWD_NAT ]]; then "$FWD_NAT" remove >>"$LOG_FILE" 2>&1 || true; fi
  rm -f "/etc/systemd/system/$FWD_UNIT" "$FWD_NAT"
  sed -i '/# vps-setup forward$/d' /etc/hosts
  systemctl daemon-reload
}

fwd_tunnel_users() { # fwd_tunnel_users <host:port> - users whose tunnel socket is there now
  local u home out=()
  for u in $(server_users); do
    home=$(home_of "$u")
    if [[ -S $home/.ssh/fwd-${1%:*}-${1##*:}.sock ]]; then out+=("$u"); fi
  done
  printf '%s' "${out[*]:-(nobody connected)}"
}

fwd_list() {
  local s
  if [[ -z $(fwd_targets) ]]; then
    info "No office services. For everyone: sudo vps-setup forward add 192.168.2.212:8100"
    info "                     One user only: sudo vps-setup forward add 192.168.2.212:8100 --user ali"
    return 0
  fi
  if systemctl is-active --quiet "$FWD_UNIT"; then ok "Gateway running ($FWD_UNIT)"; else warn "Gateway NOT running: sudo vps-setup forward apply"; fi
  printf '    %-30s %-18s %-14s %s\n' SERVICE FOR "HERE AS" "TUNNEL OPEN NOW"
  for s in $(fwd_targets); do
    printf '    %-30s %-18s %-14s %s\n' "$s" "$(fwd_owner_names "$s")" "$(fwd_ip_of "${s%:*}")" "$(fwd_tunnel_users "$s")"
  done
}

cmd_forward() {
  local action=${1-} s n user="" specs=() added=() e
  if (( $# > 0 )); then shift; fi
  while (( $# > 0 )); do
    case $1 in
      --user|-u) user=${2-}; shift || true ;;
      --user=*) user=${1#--user=} ;;
      -*) die "Unknown option $1" ;;
      *) specs+=("$1") ;;
    esac
    shift
  done
  if [[ -n $user ]]; then
    id "$user" &>/dev/null && in_group "$user" "$SSH_GROUP" || die "'$user' is not a server user."
  fi
  case $action in
    add)
      (( ${#specs[@]} > 0 )) || die "usage: vps-setup forward add <host:port | URL>... [--user <name>]   e.g. http://192.168.2.212:8100/docs"
      for s in "${specs[@]}"; do n=$(fwd_parse "$s") || exit 1; added+=("$n"); done
      if [[ -z $user ]]; then
        FORWARDS=$(uniq_words $FORWARDS "${added[@]}")
        # now for everyone: personal copies of the same service are not needed any more
        for n in "${added[@]}"; do FORWARDS_USER=$(printf '%s\n' $FORWARDS_USER | awk -v t="$n" '{ i = index($0, "="); if (substr($0, i + 1) != t) print }' | xargs); done
      else
        for n in "${added[@]}"; do
          if [[ " $FORWARDS " == *" $n "* ]]; then warn "$n is already there for everyone (including $user)."; continue; fi
          FORWARDS_USER=$(uniq_words $FORWARDS_USER "$user=$n")
        done
      fi
      save_config
      fwd_apply
      ok "Office services - for everyone: ${FORWARDS:-(none)}; personal: ${FORWARDS_USER:-(none)}"
      info "${user:-Every developer} adds these lines under the server's Host in ~/.ssh/config and reconnects"
      info "(the full, updated block is in $USERS_DIR/${user:-<user>}.txt):"
      for n in "${added[@]}"; do info "    RemoteForward $(if [[ -n $user ]]; then home_of "$user"; else printf '/home/<user>'; fi)/.ssh/fwd-${n%:*}-${n##*:}.sock $n"; done
      ;;
    remove)
      if (( ${#specs[@]} == 0 )); then
        [[ -n $user ]] || die "usage: vps-setup forward remove <host:port | URL>... [--user <name>]   (or --user <name> alone: all of theirs)"
        FORWARDS_USER=$(printf '%s\n' $FORWARDS_USER | awk -v p="$user=" 'index($0, p) != 1' | xargs)
      fi
      local pool=() matched who
      for s in "${specs[@]}"; do
        pool=()
        if [[ -n $user ]]; then
          for e in $FORWARDS_USER; do if [[ ${e%%=*} == "$user" ]]; then pool+=("${e#*=}"); fi; done
        else
          pool=($FORWARDS)
        fi
        matched=$(fwd_match "$s" "${pool[@]}")
        if [[ -z $matched ]]; then
          if [[ -z $user ]]; then
            who=""
            for e in $FORWARDS_USER; do
              if [[ -n $(fwd_match "$s" "${e#*=}") ]]; then who+=" ${e%%=*}"; fi
            done
            if [[ -n $who ]]; then die "'$s' is a personal forward of:$who - remove it with --user <name>."; fi
          fi
          die "No ${user:+personal }forward ${user:+of $user }matches '$s'. Now: ${pool[*]:-(none)}   (sudo vps-setup forward list)"
        fi
        for n in $matched; do
          if [[ -n $user ]]; then
            FORWARDS_USER=$(printf '%s\n' $FORWARDS_USER | awk -v x="$user=$n" '$0 != x' | xargs)
          else
            FORWARDS=$(printf '%s\n' $FORWARDS | awk -v x="$n" '$0 != x' | xargs)
          fi
          info "Removing $n${user:+ (personal, $user)}"
        done
      done
      save_config
      fwd_apply
      ok "Office services - for everyone: ${FORWARDS:-(none)}; personal: ${FORWARDS_USER:-(none)}"
      ;;
    apply) fwd_apply; fwd_list ;;
    list|"") fwd_list ;;
    *) die "usage: vps-setup forward add|remove <host:port | URL>... [--user <name>]  |  forward list|apply" ;;
  esac
}

# ----------------------------------------------------------------------------
# Client side: the ~/.ssh/config block for a user's own computer
# ----------------------------------------------------------------------------
cmd_client_config() {
  local u=${1-} home ports=() p
  [[ -n $u ]] && id "$u" &>/dev/null || die "usage: vps-setup client-config <user>"
  home=$(home_of "$u")
  read -ra ports <<<"${SSH_PORTS:-22}"
  cat <<EOF
# ---- ~/.ssh/config on $u's computer --------------------------------------
Host $(hostname -s)
    HostName $(server_ip)
    Port ${ports[0]}
    User $u
    # The private key that matches the public key the admin added
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    # git on the server signs in to GitLab with the key on THIS computer
    # (load it first with: ssh-add) - no private key is stored on the server
    ForwardAgent yes
    ServerAliveInterval 15
    ServerAliveCountMax 4
    # Tells the server your terminal has 24-bit colour (Claude Code looks right)
    SendEnv COLORTERM
EOF
  if (( ${#ports[@]} > 1 )); then
    cat <<EOF
    # The server listens on several ports: if one is blocked on your network, the next
    # is tried (needs ncat - part of nmap; on Windows use a single 'Port' instead).
    ProxyCommand sh -c 'for p in ${ports[*]}; do ncat --wait 8 %h \$p && exit 0; done; exit 1'
    # The same through your HTTP proxy:
    # ProxyCommand sh -c 'for p in ${ports[*]}; do ncat --proxy 127.0.0.1:2080 --proxy-type http --wait 8 %h \$p && exit 0; done; exit 1'
EOF
  else
    printf '    # Only if your network needs a proxy to reach the server:\n'
    printf '    # ProxyCommand ncat --proxy 127.0.0.1:2080 --proxy-type http %%h %%p\n'
  fi
  if [[ -n $GITLAB_HOST ]]; then
    printf '    # Server -> your network: the internal GitLab, while this connection is open\n'
    for p in $(gitlab_ports); do printf '    RemoteForward %s/.ssh/gitlab-%s.sock %s:%s\n' "$home" "$p" "$(gitlab_primary)" "$p"; done
  fi
  local s mine
  mine=$(fwd_for_user "$u")
  if [[ -n $mine ]]; then
    printf '    # Server -> your network: office services (e.g. http://%s on the server)\n' "${mine%% *}"
    for s in $mine; do printf '    RemoteForward %s/.ssh/fwd-%s-%s.sock %s\n' "$home" "${s%:*}" "${s##*:}" "$s"; done
  fi
  if systemctl is-enabled --quiet "vps-vnc@$u.service" 2>/dev/null; then
    printf '    # Your VNC desktop: while connected, point a VNC viewer at localhost:5901\n'
    printf '    # (viewer quality "High" / full colour - "auto" or "low" shows 256 colours)\n'
    printf '    LocalForward 5901 %s/.vnc/vnc.sock\n' "$home"
  fi
  if [[ $RDP_ENABLED == y ]]; then
    printf '    # RDP desktop: while connected, open Remote Desktop to localhost:13389\n'
    printf '    LocalForward 13389 127.0.0.1:%s\n' "$RDP_LOCAL_PORT"
  fi
  printf '# ---------------------------------------------------------------------------\n'
}

# ----------------------------------------------------------------------------
# SSH hardening with automatic rollback
# ----------------------------------------------------------------------------
# With socket activation (Ubuntu 24.04+) sshd only runs while someone connects, so its
# privilege-separation directory may not exist yet - and 'sshd -t/-T' refuse to run
# without it. systemd creates it the same way when it starts sshd.
sshd_cmd() { [[ -d /run/sshd ]] || install -d -m 0755 /run/sshd; sshd "$@"; }
sshd_effective() { sshd_cmd -T; }
sshd_check() { sshd_cmd -t; }
ssh_dropin() { printf '%s' "$SSH_DIR/sshd_config.d/$SSH_DROPIN_NAME"; }
ssh_socket_enabled() { systemctl is-enabled --quiet ssh.socket 2>/dev/null; }

render_ssh_dropin() { # render_ssh_dropin <port>...
  local p
  cat <<EOF
# Managed by vps-setup - rewritten on every run. Change ports: sudo vps-setup ssh --ports "22 9011"
# sshd keeps the FIRST value it reads and this file sorts first in sshd_config.d,
# so these settings win over 50-cloud-init.conf and any other drop-in.
# Several ports: if one can't be opened, sshd keeps serving the others.
EOF
  for p in "$@"; do printf 'Port %s\n' "$p"; done
  cat <<EOF
PermitRootLogin no
PubkeyAuthentication yes
AuthenticationMethods publickey
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
# PAM puts every login into its user's own slice (pam_systemd): fair sharing, vps-setup usage
# and loginctl see SSH and VS Code sessions only then. Passwords stay off (the lines above).
UsePAM yes
AllowGroups $SSH_GROUP
MaxAuthTries 4
LoginGraceTime 30
ClientAliveInterval 120
ClientAliveCountMax 3
# Local forwards: VS Code Remote-SSH and the RDP/VNC tunnels. Remote forwards: each user's
# tunnel back to the internal GitLab. GatewayPorts no = remote forwards bind to loopback
# only, never to the public interface. Forwarded sockets are created 0600, and a stale
# one from a dropped connection is replaced on reconnect.
AllowTcpForwarding yes
AllowStreamLocalForwarding yes
StreamLocalBindMask 0177
StreamLocalBindUnlink yes
GatewayPorts no
PermitTunnel no
X11Forwarding no
# Lets developers use their own SSH key for git (GitLab/GitHub) from the server.
AllowAgentForwarding yes
# The client's "my terminal has 24-bit colour" (SendEnv COLORTERM in client-config).
AcceptEnv COLORTERM
PermitUserEnvironment no
UseDNS no
EOF
}

current_ssh_ports() {
  {
    sshd_cmd -T 2>/dev/null | awk '$1 == "port" {print $2}' || true
    ss -Htlnp 2>/dev/null | awk '/"sshd"/ {n = split($4, a, ":"); print a[n]}' || true
    if ssh_socket_enabled; then systemctl show ssh.socket -p Listen --value 2>/dev/null | grep -oE ':[0-9]+ ' | tr -d ': ' || true; fi
  } | grep -E '^[0-9]+$' | sort -un || true
}

ssh_ensure_include() {
  local cfg="$SSH_DIR/sshd_config"
  if ! grep -qE "^[[:space:]]*Include[[:space:]]+$SSH_DIR/sshd_config\.d/\*\.conf" "$cfg"; then
    sed -i "1i Include $SSH_DIR/sshd_config.d/*.conf" "$cfg"
    info "Added the sshd_config.d Include line to $cfg."
  fi
}

# Port/ListenAddress/AllowUsers/AllowGroups ADD UP across files instead of first-wins,
# so a leftover line elsewhere would open another port or lock our users out.
ssh_neutralize_conflicts() {
  local f changed=()
  for f in "$SSH_DIR/sshd_config" "$SSH_DIR"/sshd_config.d/*.conf; do
    [[ -f $f && $f != "$(ssh_dropin)" ]] || continue
    if grep -qiE '^[[:space:]]*(Port|ListenAddress|AllowUsers|AllowGroups)[[:space:]]' "$f"; then
      sed -i -E 's/^([[:space:]]*)(Port|ListenAddress|AllowUsers|AllowGroups)([[:space:]])/\1# disabled by vps-setup: \2\3/I' "$f"
      changed+=("$f")
    fi
  done
  if (( ${#changed[@]} > 0 )); then info "Disabled conflicting Port/ListenAddress/AllowUsers/AllowGroups lines in: ${changed[*]}"; fi
}

ssh_verify() { # ssh_verify <port>... - checks the EFFECTIVE config, not just our file
  local want_ports eff ports want line p okp problems=()
  want_ports=$(printf '%s\n' "$@" | sort -un | xargs)
  if ! eff=$(sshd_effective 2>&1); then warn "sshd -T failed: $eff"; return 1; fi
  ports=$(awk '$1 == "port" {print $2}' <<<"$eff" | sort -un | xargs)
  [[ $ports == "$want_ports" ]] || problems+=("sshd would listen on port(s) '$ports' instead of '$want_ports'")
  while read -r line; do
    [[ -n $line ]] || continue
    okp=n; for p in "$@"; do [[ $line == *":$p" ]] && okp=y; done
    [[ $okp == y ]] || problems+=("listen address $line is not on one of the ports $want_ports")
  done < <(awk '$1 == "listenaddress" {print $2}' <<<"$eff")
  for want in "permitrootlogin no" "passwordauthentication no" "kbdinteractiveauthentication no" \
              "pubkeyauthentication yes" "authenticationmethods publickey" "gatewayports no" "usepam yes" \
              "allowtcpforwarding yes" "streamlocalbindunlink yes"; do
    grep -qxF "$want" <<<"$eff" || problems+=("expected '$want', effective: '$(grep -E "^${want%% *} " <<<"$eff" || echo unset)'")
  done
  grep -qE "^allowgroups( .*)? $SSH_GROUP( |\$)" <<<"$eff" || problems+=("AllowGroups does not include $SSH_GROUP")
  if [[ -n $(ssh_stale_listeners) ]]; then problems+=("an old sshd (pid $(ssh_stale_listeners | xargs)) still holds a port with its old configuration - run: sudo vps-setup ssh"); fi
  if grep -qE '^allowusers ' <<<"$eff"; then problems+=("an AllowUsers line is still active"); fi
  if (( ${#problems[@]} > 0 )); then
    for line in "${problems[@]}"; do warn "sshd: $line"; done
    return 1
  fi
  return 0
}

ssh_snapshot() {
  local f
  rm -rf "$ROLLBACK_DIR"
  install -d -m 700 "$ROLLBACK_DIR"
  tar -C "$SSH_DIR" -cpf "$ROLLBACK_DIR/ssh.tar" sshd_config sshd_config.d
  if ssh_socket_enabled; then echo socket; else echo service; fi >"$ROLLBACK_DIR/mode"
  for f in /etc/systemd/system/ssh.service.d/00-socket.conf /etc/systemd/system/ssh.socket.d/addresses.conf; do
    if [[ -f $f ]]; then cp -p "$f" "$ROLLBACK_DIR/$(basename "$(dirname "$f")")--$(basename "$f")"; fi
  done
}

ssh_restore_files() {
  [[ -f $ROLLBACK_DIR/ssh.tar ]] || { warn "No SSH snapshot to restore."; return 1; }
  rm -rf "$SSH_DIR/sshd_config.d"
  tar -C "$SSH_DIR" -xpf "$ROLLBACK_DIR/ssh.tar"
}

ssh_restore() { # restore the snapshot and run sshd the way it ran before
  local f d
  ssh_restore_files || return 1
  for f in "$ROLLBACK_DIR"/*--*.conf; do
    [[ -f $f ]] || continue
    d=$(basename "$f"); d=${d%%--*}
    install -d "/etc/systemd/system/$d"
    cp -p "$f" "/etc/systemd/system/$d/$(basename "$f" | sed 's/.*--//')"
  done
  systemctl daemon-reload
  if [[ $(cat "$ROLLBACK_DIR/mode" 2>/dev/null) == socket ]]; then
    systemctl stop ssh.service || true
    systemctl disable ssh.service >/dev/null 2>&1 || true
    systemctl enable --now ssh.socket
  else
    systemctl restart ssh.service
    ssh_kill_stale_listeners
  fi
  rm -f "$ROLLBACK_DIR/applied_at"
  if [[ -f $ROLLBACK_DIR/old_ports ]]; then apply_fail2ban $(cat "$ROLLBACK_DIR/old_ports") || true; fi
  log_file "SSH configuration rolled back"
}

# sshd listeners that are not ssh.service's current main process. ssh.service has
# KillMode=process, so a restart only replaces the main sshd: a listener left over from an
# earlier start (e.g. the package upgrade during setup) keeps its port with the OLD
# configuration - root login, no AllowGroups. Found with server-setup on a test server.
ssh_stale_listeners() {
  local main pid
  main=$(systemctl show ssh.service -p MainPID --value 2>/dev/null)
  for pid in $(ss -Htlnp 2>/dev/null | grep '"sshd"' | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u); do
    [[ $pid != "$main" ]] && printf '%s\n' "$pid"
  done
  return 0
}
ssh_kill_stale_listeners() {
  local pids
  pids=$(ssh_stale_listeners | xargs)
  [[ -n $pids ]] || return 0
  warn "Stopping sshd listener(s) left over from an earlier start (old configuration): $pids"
  kill -TERM $pids 2>/dev/null || true
  sleep 1
  kill -KILL $pids 2>/dev/null || true
  systemctl restart ssh.service
}

ssh_use_service_mode() {
  local f
  if ssh_socket_enabled || systemctl is-active --quiet ssh.socket; then
    info "Switching sshd from socket activation to a normal service (so its Port settings are authoritative)."
    systemctl disable --now ssh.socket >>"$LOG_FILE" 2>&1
    for f in /etc/systemd/system/ssh.service.d/00-socket.conf /etc/systemd/system/ssh.socket.d/addresses.conf; do rm -f "$f"; done
    systemctl daemon-reload
  fi
  systemctl enable ssh.service >>"$LOG_FILE" 2>&1
  systemctl restart ssh.service
  ssh_kill_stale_listeners
}

schedule_rollback() {
  systemctl stop "$ROLLBACK_UNIT.timer" "$ROLLBACK_UNIT.service" >/dev/null 2>&1 || true
  systemctl reset-failed "$ROLLBACK_UNIT.timer" "$ROLLBACK_UNIT.service" >/dev/null 2>&1 || true
  systemd-run --quiet --unit="$ROLLBACK_UNIT" --on-active="${ROLLBACK_MINUTES}min" "$INSTALL_PATH" _ssh-rollback
}
cancel_rollback() { systemctl stop "$ROLLBACK_UNIT.timer" >/dev/null 2>&1 || true; }
ssh_change_pending() { [[ -f $ROLLBACK_DIR/applied_at ]]; }

# A public-key login by the admin through the NEW sshd (not from the server itself) proves
# the change works - then it is kept automatically.
ssh_login_seen() {
  local since out hits
  since=$(cat "$ROLLBACK_DIR/applied_at" 2>/dev/null) || return 1
  out=$(journalctl -q --no-pager -o cat -u ssh.service --since "@$since" 2>/dev/null || true)
  hits=$(grep -E "^Accepted publickey for $ADMIN_USER from " <<<"$out" | grep -vE ' from (127\.|::1 )' || true)
  [[ -n $hits ]]
}

ssh_finalize() { # keep the new SSH setup: close the old ports, update fail2ban, save
  local new=() old=() p
  cancel_rollback
  mapfile -t new < <(awk '/^Port / {print $2}' "$(ssh_dropin)")
  if [[ -f $ROLLBACK_DIR/old_ports ]]; then mapfile -t old <"$ROLLBACK_DIR/old_ports"; fi
  for p in "${old[@]}"; do
    if [[ " ${new[*]} " != *" $p "* ]]; then ufw delete allow "$p/tcp" >>"$LOG_FILE" 2>&1 || true; fi
  done
  apply_fail2ban "${new[@]}"
  SSH_PORTS="${new[*]}"; save_config
  rm -f "$ROLLBACK_DIR/applied_at"
  log_file "SSH change confirmed (ports ${new[*]})"
}

ssh_wait_for_login() {
  local ip ports=("$@") ans deadline left keyopt=""
  ip=$(server_ip)
  [[ -f $CRED_DIR/$ADMIN_USER.id_ed25519 ]] && keyopt="-i <saved private key> "
  printf '\n%s' "$C_Y"
  printf '  ---------------------------------------------------------------------------\n'
  printf '   SSH is now key-only, root login off, ports %s, group %s only.\n' "${ports[*]}" "$SSH_GROUP"
  printf '   KEEP THIS TERMINAL OPEN. From your computer, log in as %s on any of them:\n\n' "$ADMIN_USER"
  printf '       ssh %s-p %s %s@%s\n\n' "$keyopt" "${ports[0]}" "$ADMIN_USER" "$ip"
  printf '   The setup continues by itself as soon as that login arrives.\n'
  printf '   Your provider'"'"'s cloud firewall (if any) must allow these TCP ports.\n'
  printf '   No login within %s minutes -> SSH is rolled back automatically.\n' "$ROLLBACK_MINUTES"
  printf '  ---------------------------------------------------------------------------%s\n' "$C_0"
  if [[ -n $keyopt ]]; then
    printf '\n  Private key for %s (save it on your computer, chmod 600):\n\n' "$ADMIN_USER"
    cat "$CRED_DIR/$ADMIN_USER.id_ed25519"
  fi
  printf "  Waiting for the login... (type 'skip' to stop waiting - it is still kept as soon as\n"
  printf "  %s logs in; 'no' rolls back now)\n" "$ADMIN_USER"
  deadline=$(( $(date +%s) + ROLLBACK_MINUTES * 60 - 20 ))
  while left=$(( deadline - $(date +%s) )); (( left > 0 )); do
    if ssh_login_seen; then ssh_finalize; note "SSH: login by $ADMIN_USER confirmed - hardening kept on ports ${ports[*]}."; return 0; fi
    if IFS= read -r -t 5 ans </dev/tty; then
      case $(trim "${ans,,}") in
        skip) note "SSH: not confirmed yet - kept automatically once $ADMIN_USER logs in, else rolled back after $ROLLBACK_MINUTES min."; return 0 ;;
        no)   cancel_rollback; ssh_restore; die "Rolled back on request - SSH runs as before." ;;
      esac
    fi
  done
  if ssh_login_seen; then ssh_finalize; note "SSH: login by $ADMIN_USER confirmed - hardening kept."; return 0; fi
  cancel_rollback; ssh_restore
  die "No login by $ADMIN_USER through the new SSH setup - rolled back. Fix it, then run: sudo vps-setup ssh"
}

ssh_apply() { # ssh_apply <port>...
  local ports=("$@") old_ports=() p up=() down=()
  mapfile -t old_ports < <(current_ssh_ports)

  if [[ -f $(ssh_dropin) ]] && cmp -s <(render_ssh_dropin "${ports[@]}") "$(ssh_dropin)" \
     && ! ssh_socket_enabled && ! ssh_change_pending && ssh_verify "${ports[@]}" >/dev/null 2>&1; then
    for p in "${ports[@]}"; do if port_listening "$p"; then up+=("$p"); fi; done
    if (( ${#up[@]} > 0 )); then note "SSH: already hardened, listening on ${up[*]} - unchanged."; return 0; fi
  fi

  for p in "${ports[@]}"; do ufw allow "$p/tcp" comment 'SSH' >>"$LOG_FILE"; done
  ssh_snapshot
  printf '%s\n' "${old_ports[@]}" >"$ROLLBACK_DIR/old_ports"
  ssh_ensure_include
  ssh_neutralize_conflicts
  render_ssh_dropin "${ports[@]}" >"$(ssh_dropin).new"
  chmod 644 "$(ssh_dropin).new"
  mv -f "$(ssh_dropin).new" "$(ssh_dropin)"
  if ! sshd_check >>"$LOG_FILE" 2>&1 || ! ssh_verify "${ports[@]}"; then
    ssh_restore_files
    die "The SSH configuration did not validate - nothing was changed (see the messages above)."
  fi

  schedule_rollback
  gitlab_keep_off_ports "${ports[@]}" "${old_ports[@]}"
  ssh_use_service_mode
  date +%s >"$ROLLBACK_DIR/applied_at"
  for p in "${ports[@]}"; do if wait_port "$p"; then up+=("$p"); else down+=("$p"); fi; done
  if (( ${#up[@]} == 0 )); then
    cancel_rollback; ssh_restore
    die "sshd could not open any of the ports ${ports[*]} - rolled back to the previous SSH setup."
  fi
  if (( ${#down[@]} > 0 )); then
    note "SSH: port(s) ${down[*]} could not be opened on the server - continuing with ${up[*]} (see: journalctl -u ssh)."
  fi
  note "SSH listening on: ${up[*]}"
  apply_fail2ban "${ports[@]}" "${old_ports[@]}"
  ssh_wait_for_login "${up[@]}"
}

# ----------------------------------------------------------------------------
# Remote desktop (RDP and VNC are only reachable through an SSH tunnel)
# ----------------------------------------------------------------------------
install_desktop_base() {
  if ! command -v startxfce4 >/dev/null; then
    run "Installing the XFCE desktop (takes a few minutes)" apt_get install xfce4 xfce4-goodies xfce4-terminal dbus-x11
  fi
  # A server boots to text mode: no display manager on the console.
  systemctl set-default multi-user.target >>"$LOG_FILE" 2>&1
  local dm
  for dm in lightdm gdm3 sddm; do systemctl disable --now "$dm" >>"$LOG_FILE" 2>&1 || true; done
  if [[ -x /usr/bin/xfce4-session ]]; then update-alternatives --set x-session-manager /usr/bin/xfce4-session >>"$LOG_FILE" 2>&1 || true; fi
  # Without these, XFCE falls back to a bare GTK theme with missing icons and poor fonts.
  local look=() p
  for p in greybird-gtk-theme elementary-xfce-icon-theme fonts-noto-core fonts-noto-color-emoji \
           fonts-vazirmatn fonts-jetbrains-mono fonts-dejavu-core; do
    if pkg_available "$p"; then look+=("$p"); fi
  done
  run "Installing the desktop theme, icons and fonts" apt_get install "${look[@]}"
  apply_desktop_defaults
  install_browser
  # Stops the "authentication required to create a color managed device" popups.
  local actions="org.freedesktop.color-manager.create-device org.freedesktop.color-manager.create-profile org.freedesktop.color-manager.delete-device org.freedesktop.color-manager.delete-profile org.freedesktop.color-manager.modify-device org.freedesktop.color-manager.modify-profile"
  if [[ -d /etc/polkit-1/rules.d ]]; then
    {
      printf '// Managed by vps-setup\npolkit.addRule(function (action, subject) {\n'
      printf '  var ids = ["%s"];\n' "${actions// /\", \"}"
      printf '  if (ids.indexOf(action.id) >= 0 && subject.isInGroup("%s")) {\n    return polkit.Result.YES;\n  }\n});\n' "$SSH_GROUP"
    } >/etc/polkit-1/rules.d/45-vps-setup-colord.rules
  fi
  if [[ -d /etc/polkit-1/localauthority ]]; then
    install -d /etc/polkit-1/localauthority/50-local.d
    printf '[vps-setup colord]\nIdentity=unix-group:%s\nAction=%s\nResultAny=no\nResultInactive=no\nResultActive=yes\n' \
      "$SSH_GROUP" "${actions// /;}" >/etc/polkit-1/localauthority/50-local.d/45-vps-setup-colord.pkla
  fi
}

# Desktop defaults for every user, in their own XDG config dir (no package file is changed):
# the Greybird look, no window compositing (it makes a remote desktop slow and smeared),
# the standard panel without the first-login "which panel?" question, a readable terminal.
# A user's own changes still win. Used by the VNC sessions and (through Xsession.d) RDP.
apply_desktop_defaults() {
  local d="$DESKTOP_XDG/xfce4/xfconf/xfce-perchannel-xml" mono="Monospace 11"
  if fc-list 2>/dev/null | grep -qi 'JetBrains Mono'; then mono="JetBrains Mono 11"; fi
  install -d -m 755 "$d" "$DESKTOP_XDG/xfce4/terminal"
  cat >"$d/xfwm4.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!-- Managed by vps-setup -->
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="theme" type="string" value="Greybird"/>
    <property name="use_compositing" type="bool" value="false"/>
    <property name="title_font" type="string" value="Sans Bold 10"/>
  </property>
</channel>
EOF
  if [[ -f /etc/xdg/xfce4/panel/default.xml ]]; then
    install -m 644 /etc/xdg/xfce4/panel/default.xml "$d/xfce4-panel.xml"
  fi
  cat >"$d/xfce4-terminal.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!-- Managed by vps-setup -->
<channel name="xfce4-terminal" version="1.0">
  <property name="font-use-system" type="bool" value="false"/>
  <property name="font-name" type="string" value="$mono"/>
  <property name="misc-default-geometry" type="string" value="120x34"/>
  <property name="scrolling-lines" type="uint" value="100000"/>
</channel>
EOF
  printf '# Managed by vps-setup (xfce4-terminal before 1.1)\n[Configuration]\nFontName=%s\nMiscDefaultGeometry=120x34\nScrollingLines=100000\n' \
    "$mono" >"$DESKTOP_XDG/xfce4/terminal/terminalrc"
  [[ -d /etc/X11/Xsession.d ]] || return 0
  cat >/etc/X11/Xsession.d/55vps-setup-desktop <<EOF
# Managed by vps-setup: desktop defaults for RDP sessions (VNC sets the same itself)
case ":\${XDG_CONFIG_DIRS:-/etc/xdg}:" in *":$DESKTOP_XDG:"*) ;; *) XDG_CONFIG_DIRS="$DESKTOP_XDG:\${XDG_CONFIG_DIRS:-/etc/xdg}"; export XDG_CONFIG_DIRS ;; esac
EOF
}

# A browser for the desktops (installed once, with the first VNC/RDP desktop).
# Google Chrome on amd64 - a normal package that updates with apt (Ubuntu's own Firefox and
# Chromium are snaps, which are heavy and unreliable in remote desktops). Chrome has no
# arm64 build, so ARM servers get GNOME Web instead.
install_chrome() {
  local tmp
  [[ $(dpkg --print-architecture) == amd64 ]] || die "Google Chrome has no build for $(dpkg --print-architecture) - use firefox."
  if command -v google-chrome-stable >/dev/null; then return 0; fi
  tmp=$(mktemp -d)
  chmod 755 "$tmp"   # apt's download user must be able to read the local .deb
  run "Downloading Google Chrome" curl -fsSL -o "$tmp/google-chrome-stable_current_amd64.deb" \
    https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
  # the package adds Google's signed apt repository itself, so Chrome updates with apt
  run "Installing Google Chrome" apt_get install "$tmp/google-chrome-stable_current_amd64.deb"
  rm -rf "$tmp"
  note "Google Chrome $(google-chrome-stable --version 2>/dev/null | awk '{print $NF}') (updates with apt)."
}

install_browser() {
  if command -v google-chrome-stable >/dev/null || command -v epiphany-browser >/dev/null; then return 0; fi
  if [[ $(dpkg --print-architecture) == amd64 ]]; then
    install_chrome
    update-alternatives --set x-www-browser /usr/bin/google-chrome-stable >>"$LOG_FILE" 2>&1 || true
    APPS=$(uniq_words $APPS chrome); save_config
  else
    run "Installing GNOME Web (browser)" apt_get install epiphany-browser
    update-alternatives --set x-www-browser /usr/bin/epiphany-browser >>"$LOG_FILE" 2>&1 || true
    note "Browser for the desktops: GNOME Web (Chrome has no build for $(dpkg --print-architecture))."
  fi
}

xrdp_bind_localhost() {
  # [Globals] port: tcp://.:3389 means 127.0.0.1 only (xrdp.ini syntax)
  sed -i -E "/^\[Globals\]/,/^\[/ s|^port=.*|port=tcp://.:$RDP_LOCAL_PORT|" /etc/xrdp/xrdp.ini
  if [[ -f /etc/xrdp/sesman.ini ]]; then sed -i -E 's|^ListenAddress=.*|ListenAddress=127.0.0.1|' /etc/xrdp/sesman.ini; fi
  if systemctl is-active --quiet xrdp; then systemctl restart xrdp; fi
}

rdp_listening_safely() { # every xrdp listener must be loopback
  local addrs a
  addrs=$(ss -Htln "( sport = :$RDP_LOCAL_PORT )" 2>/dev/null | awk '{print $4}')
  [[ -n $addrs ]] || return 1
  for a in $addrs; do [[ $a == 127.0.0.1:* || $a == "[::1]:"* ]] || return 1; done
  return 0
}

tunnel_hint_rdp() { # tunnel_hint_rdp <user>
  info "RDP for $1: on your computer run"
  info "    ssh -N -L 13389:127.0.0.1:$RDP_LOCAL_PORT $(hostname -s)      (the Host from client-config)"
  info "  then open Remote Desktop to  localhost:13389  and log in with your Linux username + password."
}

cmd_rdp() {
  local action=${1-}
  case $action in
    enable)
      install_desktop_base
      run "Installing xrdp" apt_get install xrdp xorgxrdp
      xrdp_bind_localhost
      adduser xrdp ssl-cert >>"$LOG_FILE" 2>&1 || true
      systemctl enable xrdp >>"$LOG_FILE" 2>&1
      systemctl restart xrdp
      sleep 2
      if ! rdp_listening_safely; then
        systemctl disable --now xrdp >>"$LOG_FILE" 2>&1 || true
        die "xrdp is not listening on 127.0.0.1 only - it was stopped. Check /etc/xrdp/xrdp.ini [Globals] port=."
      fi
      RDP_ENABLED=y; save_config
      note "RDP enabled on 127.0.0.1:$RDP_LOCAL_PORT (only through an SSH tunnel)."
      local u nopw=()
      for u in $(server_users); do if ! user_has_password "$u"; then nopw+=("$u"); fi; done
      if (( ${#nopw[@]} > 0 )); then warn "RDP needs a password. Without one: ${nopw[*]} - set it with: sudo vps-setup password <user>"; fi
      tunnel_hint_rdp "<user>"
      ;;
    disable)
      systemctl disable --now xrdp xrdp-sesman >>"$LOG_FILE" 2>&1 || true
      RDP_ENABLED=n; save_config
      ok "RDP disabled."
      ;;
    *) die "usage: vps-setup rdp enable|disable" ;;
  esac
}

render_vnc_session() {
  sed -e "s|@DESKTOP_XDG@|$DESKTOP_XDG|g" -e "s|@VNC_TIMEOUT_CMD@|$VNC_TIMEOUT_CMD|g" <<'EOF'
#!/bin/bash
# vnc-session - managed by vps-setup; started by vps-vnc@<user>.service as that user.
# The desktop listens ONLY on ~/.vnc/vnc.sock (mode 0600) - no TCP port - so nobody else
# on the server can reach it. Connect from your computer through SSH:
#   ssh -N -L 5901:/home/<you>/.vnc/vnc.sock <server>   then a VNC viewer on localhost:5901
# Resolution: put e.g. 2560x1440 into ~/.vnc/geometry and restart the desktop.
# After you disconnect, the desktop closes with every app opened in it once the time set by
# `vnc-timeout` has passed (5m, 2h, 3d, off); a fresh desktop then waits for your next connection.
set -euo pipefail
uid=$(id -u)
(( uid >= 1000 )) || { echo "vnc-session: refusing to run as a system user" >&2; exit 1; }
display=$(( 50 + uid - 1000 ))
vnc_dir="$HOME/.vnc"
sock="$vnc_dir/vnc.sock"
geometry=1920x1080
if [[ -r $vnc_dir/geometry ]]; then geometry=$(tr -cd '0-9x' <"$vnc_dir/geometry"); fi
[[ $geometry =~ ^[0-9]{3,5}x[0-9]{3,5}$ ]] || geometry=1920x1080
[[ -s $vnc_dir/passwd ]] || { echo "vnc-session: $vnc_dir/passwd is missing" >&2; exit 1; }

lock="/tmp/.X$display-lock"
if [[ -e $lock ]]; then
  pid=$(tr -cd '0-9' <"$lock" 2>/dev/null || true)
  if [[ -z $pid ]] || ! kill -0 "$pid" 2>/dev/null; then rm -f "$lock" "/tmp/.X11-unix/X$display" 2>/dev/null || true; fi
fi
rm -f "$sock"

if [[ -d /run/user/$uid ]]; then export XDG_RUNTIME_DIR="/run/user/$uid"; fi

# The X display itself needs a cookie: without one the X server lets in EVERY local user
# (/tmp/.X11-unix/X<n> is world-writable and the abstract socket has no permissions at
# all), who could then watch, keylog and type into this desktop. A fresh one every start.
xauth_file="$vnc_dir/Xauthority"
rm -f "$xauth_file"
( umask 077; : >"$xauth_file" )
xauth -q -f "$xauth_file" add ":$display" . "$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
export XAUTHORITY="$xauth_file"

Xtigervnc ":$display" -auth "$xauth_file" -rfbunixpath "$sock" -rfbunixmode 0600 -rfbport -1 -localhost -nolisten tcp \
  -SecurityTypes VncAuth -PasswordFile "$vnc_dir/passwd" \
  -geometry "$geometry" -depth 24 -desktop "$USER@$(hostname -s)" -AlwaysShared &
xvnc=$!
session=""
# sweep <signal> - signal every process of this user that was started in this desktop. Apps
# that stayed in this service are ended by systemd anyway; this also reaches the ones that
# moved out of it (e.g. into a systemd --user scope). Prints how many it found.
sweep() {
  local p n=0
  for p in /proc/[0-9]*; do
    [[ -O $p && ${p#/proc/} != "$$" ]] || continue
    if grep -qxzF "VPS_VNC_DESKTOP=:$display" "$p/environ" 2>/dev/null; then
      kill -s "$1" "${p#/proc/}" 2>/dev/null && n=$((n + 1))
    fi
  done
  echo "$n"
}
cleanup() {
  if [[ -n $session ]]; then kill "$session" 2>/dev/null || true; fi
  kill "$xvnc" 2>/dev/null || true
  if [[ $(sweep TERM) != 0 ]]; then sleep 3; sweep KILL >/dev/null; fi
  kill $(jobs -p) 2>/dev/null || true
  wait 2>/dev/null || true
  rm -f "$sock"
}
trap cleanup EXIT
trap 'exit 0' TERM INT

for _ in $(seq 1 50); do
  [[ -S $sock ]] && break
  kill -0 "$xvnc" 2>/dev/null || { echo "vnc-session: Xtigervnc exited" >&2; exit 1; }
  sleep 0.2
done
[[ -S $sock ]] || { echo "vnc-session: Xtigervnc did not create $sock" >&2; exit 1; }

export DISPLAY=":$display"
# vps-setup's desktop defaults (theme, no compositing, panel); your own settings still win
export XDG_CONFIG_DIRS="@DESKTOP_XDG@:${XDG_CONFIG_DIRS:-/etc/xdg}"
unset SESSION_MANAGER DBUS_SESSION_BUS_ADDRESS
# every app started in this desktop inherits VPS_VNC_DESKTOP (see sweep) - this script does not
VPS_VNC_DESKTOP=":$display" dbus-launch --exit-with-session startxfce4 &
session=$!

# Close the desktop once no viewer has been connected for the user's vnc-timeout. It is read
# again every 10 s, so a change applies without a restart. Counting starts only after a viewer
# was connected, so a fresh desktop waits for its user however long that takes.
seen=n
last=$SECONDS
while kill -0 "$xvnc" 2>/dev/null && kill -0 "$session" 2>/dev/null; do
  if [[ -n $(ss -xH state connected src "$sock" 2>/dev/null) ]]; then
    seen=y; last=$SECONDS
  elif [[ $seen == y ]]; then
    limit=$(@VNC_TIMEOUT_CMD@ --seconds 2>/dev/null || echo 0)
    [[ $limit =~ ^[0-9]+$ ]] || limit=0
    if (( limit > 0 && SECONDS - last >= limit )); then
      echo "vnc-session: no viewer for $(( SECONDS - last )) s (vnc-timeout: $limit s) - closing the desktop and its apps"
      exit 0
    fi
  fi
  sleep 10 &
  wait $! || true
done
EOF
}

render_vnc_unit() {
  cat <<EOF
# Managed by vps-setup
[Unit]
Description=VNC desktop for %i (unix socket only - reach it through SSH)
After=network.target systemd-user-sessions.service

[Service]
Type=simple
User=%i
WorkingDirectory=~
ExecStart=$VNC_SESSION
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
}

# vnc-timeout - the user-facing command (no sudo) behind the desktop's disconnect timeout.
render_vnc_timeout() {
  cat <<EOF
#!/bin/bash
# vnc-timeout - managed by vps-setup. How long your VNC desktop stays open after you disconnect.
# Then it closes together with every app you opened in it, and a fresh desktop waits for you.
#   vnc-timeout                     show the current setting
#   vnc-timeout 30m | 2h | 3d | off set your own (a bare number is minutes; applies within 10 s)
#   vnc-timeout default             use the server default again
set -euo pipefail
$(declare -f duration_secs)
own="\$HOME/.vnc/disconnect-timeout"
default_file="$VNC_TIMEOUT_DEFAULT"
EOF
  cat <<'EOF'
effective() { # prints "<duration> <source>"
  local f v
  for f in "$own" "$default_file"; do
    [[ -r $f ]] || continue
    v=$(tr -d '[:space:]' <"$f")
    if duration_secs "$v" >/dev/null 2>&1; then
      if [[ $f == "$own" ]]; then echo "$v yours"; else echo "$v server-default"; fi
      return 0
    fi
  done
  echo "5m server-default"
}
describe() {
  if [[ $(duration_secs "$1") == 0 ]]; then echo "VNC desktop: stays open after you disconnect ($2)"
  else echo "VNC desktop: closes $1 after you disconnect, with every app in it ($2)"; fi
}
case ${1-} in
  "") read -r v src < <(effective); describe "$v" "$src" ;;
  --seconds) read -r v _ < <(effective); duration_secs "$v" ;;
  default) rm -f "$own"; read -r v src < <(effective); describe "$v" "$src" ;;
  -h|--help) sed -n '2,7s/^# \{0,1\}//p' "$0" ;;
  *)
    v=${1,,}
    duration_secs "$v" >/dev/null || { echo "vnc-timeout: '$1' is not a duration - e.g. 30m, 2h, 3d, 90s or off" >&2; exit 2; }
    mkdir -p "$HOME/.vnc"
    printf '%s\n' "$v" >"$own"
    describe "$v" "yours - applies within 10 s"
    ;;
esac
EOF
}

install_vnc_timeout() {
  install -d -m 755 "$LIB_DIR"
  render_vnc_timeout >"$VNC_TIMEOUT_CMD"; chmod 755 "$VNC_TIMEOUT_CMD"
  [[ -s $VNC_TIMEOUT_DEFAULT ]] || printf '5m\n' >"$VNC_TIMEOUT_DEFAULT"
  chmod 644 "$VNC_TIMEOUT_DEFAULT"
}

# vps-setup vnc timeout <duration> [<user>] - without a user: the server default
vnc_set_timeout() {
  local dur=${1-} u=${2-} home what
  [[ -n $dur ]] && duration_secs "$dur" >/dev/null \
    || die "usage: vps-setup vnc timeout <30m|2h|3d|90s|off> [<user>]   (without a user: the server default)"
  dur=${dur,,}
  install_vnc_timeout
  what="closes $dur after its user disconnects"
  [[ $(duration_secs "$dur") == 0 ]] && what="stays open after its user disconnects"
  if [[ -z $u ]]; then
    printf '%s\n' "$dur" >"$VNC_TIMEOUT_DEFAULT"
    ok "Server default: a VNC desktop $what. Users who set their own (vnc-timeout) keep theirs."
  else
    id "$u" &>/dev/null || die "No user '$u'."
    home=$(home_of "$u")
    runuser -u "$u" -- sh -c 'umask 077; mkdir -p "$1/.vnc"; printf "%s\n" "$2" >"$1/.vnc/disconnect-timeout"' sh "$home" "$dur"
    ok "VNC for $u: the desktop $what (applies within 10 s; $u can change it: vnc-timeout)."
  fi
}

cmd_vnc() {
  local action=${1-} u="" home pw="" a new_pw=n reset_look=n
  if (( $# > 0 )); then shift; fi
  if [[ $action == timeout ]]; then vnc_set_timeout "$@"; return 0; fi
  for a in "$@"; do
    case $a in
      --new-password) new_pw=y ;;
      --reset-look) reset_look=y ;;
      -*) die "Unknown option $a" ;;
      *) u=$a ;;
    esac
  done
  [[ $action == enable || $action == disable ]] && [[ -n $u ]] || die "usage: vps-setup vnc enable|disable <user> [--new-password] [--reset-look]  |  vnc timeout <30m|2h|3d|off> [<user>]"
  id "$u" &>/dev/null || die "No user '$u'."
  if [[ $action == disable ]]; then
    systemctl disable --now "vps-vnc@$u.service" >>"$LOG_FILE" 2>&1 || true
    rm -rf "/etc/systemd/system/vps-vnc@$u.service.d"; systemctl daemon-reload
    ok "VNC desktop for $u disabled."
    return 0
  fi
  in_group "$u" "$SSH_GROUP" || die "$u is not a server user (not in $SSH_GROUP)."
  # The desktop's screen lock asks for the Linux password - give one to users who have none.
  if ! user_has_password "$u"; then set_password "$u" "$(gen_password 16)" y; fi
  install_desktop_base
  local pkgs=(tigervnc-standalone-server)
  if pkg_available tigervnc-tools; then pkgs+=(tigervnc-tools); fi
  run "Installing TigerVNC" apt_get install "${pkgs[@]}"
  install -d -m 755 "$LIB_DIR"
  install_vnc_timeout
  render_vnc_session >"$VNC_SESSION"; chmod 755 "$VNC_SESSION"
  render_vnc_unit >"$VNC_UNIT_FILE"
  retire_tigervnc "$u"   # one desktop per user - see retire_tigervnc
  # The desktop runs in the user's own slice, so it counts towards their fair share.
  install -d "/etc/systemd/system/vps-vnc@$u.service.d"
  printf '# Managed by vps-setup\n[Service]\nSlice=user-%s.slice\n' "$(id -u "$u")" >"/etc/systemd/system/vps-vnc@$u.service.d/10-slice.conf"
  systemctl daemon-reload
  home=$(home_of "$u")
  runuser -u "$u" -- sh -c 'umask 077; mkdir -p "$1/.vnc"; chmod 700 "$1/.vnc"' sh "$home"
  # Re-enabling (e.g. after an update) keeps the password the user already has.
  if [[ $new_pw == y || ! -s $home/.vnc/passwd ]]; then
    pw=$(gen_password 8)   # VNC passwords are limited to 8 characters
    printf '%s\n' "$pw" | vncpasswd -f | runuser -u "$u" -- sh -c 'umask 077; cat >"$1/.vnc/passwd"' sh "$home"
  fi
  if [[ $reset_look == y && -d $home/.config/xfce4 ]]; then
    # their desktop settings from before move aside, so the defaults apply on the next start
    runuser -u "$u" -- mv "$home/.config/xfce4" "$home/.config/xfce4.before-$(date +%Y%m%d-%H%M%S)"
    note "VNC for $u: the old desktop settings were moved to ~/.config/xfce4.before-* (defaults apply now)."
  fi
  systemctl enable "vps-vnc@$u.service" >>"$LOG_FILE" 2>&1
  systemctl restart "vps-vnc@$u.service"
  local i
  for i in $(seq 1 30); do [[ -S $home/.vnc/vnc.sock ]] && break; sleep 0.5; done
  if [[ ! -S $home/.vnc/vnc.sock ]]; then
    journalctl -u "vps-vnc@$u.service" -n 20 --no-pager >&2 || true
    die "The VNC desktop for $u did not start (see above)."
  fi
  if [[ -n $pw ]]; then note_cred "$u" "vnc password" "$pw"; else note "VNC for $u: password unchanged (a new one: sudo vps-setup vnc enable $u --new-password)."; fi
  note "VNC for $u: ssh -N -L 5901:$home/.vnc/vnc.sock $(hostname -s)   then a VNC viewer on localhost:5901"
  note "VNC viewer: set picture quality to High / full colour - on Auto or Low it shows only 256 colours."
  note "VNC for $u: $(runuser -u "$u" -- "$VNC_TIMEOUT_CMD" 2>/dev/null || echo "closes after the server default once disconnected") - change it: vnc-timeout 2h"
  if [[ $IN_SETUP != y ]]; then print_credentials; fi
}

# ----------------------------------------------------------------------------
# Desktop apps (system-wide: every desktop user gets them; installing needs root, so
# the admin does it - developers ask, e.g. "ali needs VS Code on his VNC desktop")
# ----------------------------------------------------------------------------
readonly APP_CATALOG="vscode|Visual Studio Code (Microsoft's apt repository)
chrome|Google Chrome (amd64; Google's apt repository)
firefox|Firefox (Mozilla's apt repository - not the snap)
vlc|VLC media player
gimp|GIMP image editor
inkscape|Inkscape vector graphics
libreoffice|LibreOffice office suite
meld|Meld diff and merge tool
filezilla|FileZilla FTP/SFTP client"

app_canonical() { # app_canonical <name> - catalog name for the usual aliases
  case ${1,,} in
    code|vs-code|visual-studio-code) printf 'vscode' ;;
    google-chrome|google-chrome-stable) printf 'chrome' ;;
    *) printf '%s' "${1,,}" ;;
  esac
}

app_package() { # the apt package behind a catalog name
  case $1 in vscode) printf 'code' ;; chrome) printf 'google-chrome-stable' ;; *) printf '%s' "$1" ;; esac
}

pkg_installed() { [[ $(dpkg-query -W -f='${Status}' "$1" 2>/dev/null) == "install ok installed" ]]; }

app_installed() {
  local pkg; pkg=$(app_package "$1")
  pkg_installed "$pkg" || return 1
  # Ubuntu's firefox package is only a wrapper that installs the snap
  if [[ $1 == firefox && $(dpkg-query -W -f='${Version}' firefox 2>/dev/null) == *snap* ]]; then return 1; fi
  return 0
}

install_vscode() {
  local tmp arch
  arch=$(dpkg --print-architecture)
  if ! pkg_installed code; then
    tmp=$(mktemp)
    run "Downloading Microsoft's signing key" curl -fsSL -o "$tmp" https://packages.microsoft.com/keys/microsoft.asc
    gpg --batch --yes --dearmor -o /usr/share/keyrings/microsoft.gpg "$tmp"
    chmod 644 /usr/share/keyrings/microsoft.gpg; rm -f "$tmp"
    # the same file and keyring the code package manages itself, so they never conflict
    if [[ ! -f /etc/apt/sources.list.d/vscode.sources && ! -f /etc/apt/sources.list.d/vscode.list ]]; then
      printf 'Types: deb\nURIs: https://packages.microsoft.com/repos/code\nSuites: stable\nComponents: main\nArchitectures: %s\nSigned-By: /usr/share/keyrings/microsoft.gpg\n' \
        "$arch" >/etc/apt/sources.list.d/vscode.sources
    fi
    echo 'code code/add-microsoft-repo boolean false' | debconf-set-selections
    run "Refreshing package lists" apt_get update
    run "Installing Visual Studio Code" apt_get install code
  fi
  note "VS Code $(dpkg-query -W -f='${Version}' code 2>/dev/null | cut -d- -f1): desktop menu -> Development (updates with apt)."
}

install_firefox() {
  if ! app_installed firefox; then
    install -d -m 755 /etc/apt/keyrings
    run "Downloading Mozilla's signing key" curl -fsSL -o /etc/apt/keyrings/packages.mozilla.org.asc \
      https://packages.mozilla.org/apt/repo-signing-key.gpg
    chmod 644 /etc/apt/keyrings/packages.mozilla.org.asc
    printf 'deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main\n' \
      >/etc/apt/sources.list.d/mozilla.list
    # Mozilla's package wins over Ubuntu's snap wrapper
    printf 'Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n' >/etc/apt/preferences.d/mozilla
    run "Refreshing package lists" apt_get update
    run "Installing Firefox" apt_get install firefox
    app_installed firefox || die "Firefox came from the snap wrapper, not Mozilla's repository."
  fi
  note "Firefox $(dpkg-query -W -f='${Version}' firefox 2>/dev/null) from Mozilla (updates with apt)."
}

install_app() { # install_app <catalog name or apt package>
  local a; a=$(app_canonical "$1")
  case $a in
    vscode) install_vscode ;;
    chrome) install_chrome ;;
    firefox) install_firefox ;;
    chromium|chromium-browser) die "Ubuntu's Chromium is a snap - install 'chrome' (or 'firefox') instead." ;;
    dbeaver|postman) die "$a has no apt package on Ubuntu - developers install it in their home (e.g. the .tar.gz from its website)." ;;
    *)
      [[ $a =~ ^[a-z0-9][a-z0-9+.-]+$ ]] || die "'$1' is not an app or package name."
      pkg_available "$a" || die "No app or package '$a' (see: sudo vps-setup apps list)."
      if apt-cache depends "$a" 2>/dev/null | grep -qE '^ *(Pre)?Depends: snapd$'; then
        die "Ubuntu ships '$a' only as a snap - not installed (snaps don't work well on this server)."
      fi
      run "Installing $a" apt_get install "$a"
      note "Installed $a."
      ;;
  esac
}

apps_install() { # apps_install <app>... - tries all, fails at the end if any failed
  local a c failed=()
  (( $# > 0 )) || return 0
  if ! command -v startxfce4 >/dev/null; then
    warn "No desktop on this server yet - the apps are installed now and appear once one is enabled (vnc/rdp enable)."
  fi
  for a in "$@"; do
    c=$(app_canonical "$a")
    if ( install_app "$c" ); then APPS=$(uniq_words $APPS "$c"); else failed+=("$a"); fi
  done
  save_config
  (( ${#failed[@]} == 0 )) || die "Could not install: ${failed[*]} (details above and in $LOG_FILE)"
}

apps_list() {
  local name desc state a
  printf '    %-14s %-10s %s\n' APP STATE ""
  while IFS='|' read -r name desc; do
    state=-; if app_installed "$name"; then state=installed; fi
    printf '    %-14s %-10s %s\n' "$name" "$state" "$desc"
  done <<<"$APP_CATALOG"
  for a in $APPS; do   # other packages installed with vps-setup
    [[ -n $(awk -F'|' -v x="$a" '$1 == x' <<<"$APP_CATALOG") ]] && continue
    state="removed"; if app_installed "$a"; then state=installed; fi
    printf '    %-14s %-10s %s\n' "$a" "$state" "(Ubuntu package)"
  done
  info "Any other Ubuntu package works too: sudo vps-setup apps install <package>"
}

app_forget_repo() { # app_forget_repo <app> - the vendor apt repository goes with the app
  case $1 in
    vscode) rm -f /etc/apt/sources.list.d/vscode.sources /etc/apt/sources.list.d/vscode.list /usr/share/keyrings/microsoft.gpg ;;
    chrome) rm -f /etc/apt/sources.list.d/google-chrome.sources /etc/apt/sources.list.d/google-chrome.list ;;
    firefox) rm -f /etc/apt/sources.list.d/mozilla.list /etc/apt/preferences.d/mozilla /etc/apt/keyrings/packages.mozilla.org.asc ;;
  esac
}

apps_remove() { # apps_remove <app>... - checks every name first, then removes
  local a c pkg todo=() unknown=() gone=()
  for a in "$@"; do
    c=$(app_canonical "$a"); pkg=$(app_package "$c")
    if app_installed "$c" || pkg_installed "$pkg"; then todo+=("$c")
    elif [[ " $APPS " == *" $c "* ]]; then gone+=("$c")          # removed by hand earlier
    else unknown+=("$a"); fi
  done
  if (( ${#unknown[@]} > 0 )); then
    die "Not installed: ${unknown[*]}. Installed now: $(for c in $(awk -F'|' '{print $1}' <<<"$APP_CATALOG") $APPS; do app_installed "$c" && printf '%s ' "$c"; done | xargs -n1 | awk '!s[$0]++' | xargs)"
  fi
  for c in "${todo[@]}"; do
    pkg=$(app_package "$c")
    # purge: also drops system-wide leftovers such as Chrome's daily repository job;
    # every user's own settings (in their home) stay
    run "Removing $c" apt_get purge "$pkg"
    app_forget_repo "$c"
    APPS=$(printf '%s\n' $APPS | awk -v x="$c" '$0 != x' | xargs)
    note "Removed $c (users' own settings in their homes are kept)."
  done
  for c in "${gone[@]}"; do
    APPS=$(printf '%s\n' $APPS | awk -v x="$c" '$0 != x' | xargs)
    info "$c was already removed - dropped from the list."
  done
  save_config
  if command -v startxfce4 >/dev/null && ! command -v google-chrome-stable >/dev/null \
     && ! command -v firefox >/dev/null && ! command -v epiphany-browser >/dev/null; then
    warn "The desktops have no web browser now - install one: sudo vps-setup apps install chrome"
  fi
}

cmd_apps() {
  local action=${1-} a c pkg
  if (( $# > 0 )); then shift; fi
  case $action in
    install|add)
      (( $# > 0 )) || die "usage: vps-setup apps install <app>...   (sudo vps-setup apps list)"
      apps_install "$@"
      ok "Installed for every desktop user: $*. They appear in the desktop menu."
      ;;
    remove|uninstall)
      (( $# > 0 )) || die "usage: vps-setup apps remove <app>...   (sudo vps-setup apps list)"
      apps_remove "$@"
      ok "Done. Apps now: ${APPS:-(none)}"
      ;;
    list|"") apps_list ;;
    *) die "usage: vps-setup apps install|remove <app>...  |  apps list" ;;
  esac
}

# ----------------------------------------------------------------------------
# Setup
# ----------------------------------------------------------------------------
valid_app_list() {
  local a c
  for a in $1; do
    c=$(app_canonical "$a")
    case $c in chromium|chromium-browser|dbeaver|postman) warn "'$a' can't be installed with apt here (see: vps-setup apps list)."; return 1 ;; esac
    if [[ -z $(awk -F'|' -v x="$c" '$1 == x' <<<"$APP_CATALOG") ]] && ! pkg_available "$c"; then
      warn "No app or package '$a'."; return 1
    fi
  done
  return 0
}

valid_vnc_users() {
  local u
  for u in $1; do
    [[ $u == "$ADMIN_USER" || " ${DEV_USERS[*]} " == *" $u "* ]] || { warn "'$u' is not one of the users above."; return 1; }
  done
  return 0
}

collect_answers() {
  local name existing others=() uid
  step "1/6  Admin account (full sudo)"
  info "The admin has full sudo. Developers have no root at all. Everyone gets, in their own home:"
  info "nvm + Node, npm, bun, pip/pipx/uv, Go - and installs more without root (npm -g, pipx,"
  info "go install, nvm install). System packages (apt): ask the admin, or apt inside Docker."
  prompt ADMIN_USER "Admin username" "${ADMIN_USER:-${SUDO_USER:-}}" valid_username
  collect_keys "$ADMIN_USER"; ADMIN_KEYS=$KEYS_OUT
  ADMIN_PASSWORD=""; ADMIN_PW_GENERATED=n
  local replace=y
  if user_has_password "$ADMIN_USER"; then prompt_yn replace "$ADMIN_USER already has a password. Replace it?" n; fi
  if [[ $replace == y ]]; then prompt_password ADMIN_PASSWORD "Password for $ADMIN_USER (used for sudo)"; ADMIN_PW_GENERATED=$PW_GENERATED; fi

  step "2/6  Developer accounts (no sudo; VS Code Remote-SSH + Claude Code)"
  DEV_USERS=(); declare -gA DEV_KEYS=()
  while :; do
    prompt name "Developer username (empty = done)" "" accept_any
    [[ -n $name ]] || break
    valid_username "$name" || continue
    if [[ $name == "$ADMIN_USER" || " ${DEV_USERS[*]} " == *" $name "* ]]; then warn "Already listed."; continue; fi
    collect_keys "$name"
    DEV_USERS+=("$name"); DEV_KEYS[$name]=$KEYS_OUT
  done

  step "3/6  SSH"
  existing=$(current_ssh_ports | xargs)
  info "Several ports are allowed: if one is blocked on a network, clients use the next one."
  prompt SSH_PORTS "SSH ports (space-separated)" "${SSH_PORTS:-${existing:-22}}" valid_ssh_ports
  SSH_PORTS=$(for p in $SSH_PORTS; do echo $((10#$p)); done | xargs)
  prompt TRUSTED_IPS "IPs/CIDRs fail2ban must never ban, e.g. your office (space-separated, empty = none)" "${TRUSTED_IPS:-}" valid_ip_list

  step "4/6  Server"
  prompt NEW_HOSTNAME "Hostname" "$(hostname -s)" valid_hostname
  prompt TIMEZONE "Timezone" "$(timedatectl show -p Timezone --value 2>/dev/null || echo UTC)" valid_timezone
  prompt_yn OPEN_WEB "Open ports 80/443 to the internet (only if this server hosts a website)?" "${OPEN_WEB:-n}"
  prompt_yn AUTO_REBOOT "Reboot automatically at 04:00 when a security update needs it (stops running sessions)?" "${AUTO_REBOOT:-n}"
  UFW_RESET=n
  local rules allowed
  allowed=$(printf '%s|' $SSH_PORTS 22 80 443); allowed=${allowed%|}
  rules=$(ufw show added 2>/dev/null | grep '^ufw ' | grep -vE "allow ($allowed)/tcp" || true)
  if [[ -n $rules ]]; then
    warn "The firewall already has other rules:"; printf '        %s\n' "$rules" >&2
    prompt_yn UFW_RESET "Remove them and keep only what this setup needs?" y
  fi

  step "5/6  Tools and internal GitLab"
  prompt NODE_MAJOR "Node.js major version" "${NODE_MAJOR:-24}" valid_node_major
  prompt_yn INSTALL_DOCKER "Install Docker? (admin: system Docker; every developer: their own rootless Docker - no root)" "${INSTALL_DOCKER:-n}"
  info "Internal GitLab: reached through the developers' SSH connections; on the server it then"
  info "works like on your PC (git@<host>:..., https://<host>). Any domain works - a local one"
  info "(gitlab.local) or a global one (gitlab.company.com). '-' clears a value."
  prompt GITLAB_HOST "GitLab hostname(s) as your PCs know them, main one first (empty = none)" "${GITLAB_HOST:-}" valid_gitlab_hosts
  if [[ -n $GITLAB_HOST ]]; then
    prompt GITLAB_SSH_PORT "GitLab SSH port (inside your network)" "${GITLAB_SSH_PORT:-22}" valid_port_number
    prompt GITLAB_PORTS "Other GitLab ports to reach (web 80/443, registry...; space-separated, empty = none)" "${GITLAB_PORTS:-80 443}" valid_port_list_or_empty
    GITLAB_SSH_PORT=$((10#$GITLAB_SSH_PORT))
    local pub; pub=$(public_ipv4_of "$(gitlab_primary)" || true)
    if [[ -n $pub ]] && ! is_private_ipv4 "$pub"; then
      info "$(gitlab_primary) also resolves on the internet ($pub)."
      prompt_yn GITLAB_DIRECT "When no developer tunnel is up, connect to $pub directly?" "${GITLAB_DIRECT:-y}"
    else
      [[ -n $pub ]] && info "$(gitlab_primary) resolves to a private address ($pub) - only reachable through the tunnels."
      GITLAB_DIRECT=n
    fi
  else
    GITLAB_SSH_PORT="" GITLAB_PORTS="" GITLAB_DIRECT=""
  fi
  info "Other office services (a backend, its API docs, a database...) work on the server the same"
  info "way, e.g. http://192.168.2.212:8100/docs. Later: sudo vps-setup forward add <host:port>."
  prompt FORWARDS "Office services to reach (host:port or URL, space-separated, empty = none)" "${FORWARDS:-}" valid_forward_list
  FORWARDS=$(fwd_normalize "$FORWARDS")

  step "6/6  Remote desktop (optional - VS Code Remote-SSH needs none; can be enabled later)"
  prompt_yn RDP_ENABLED "Enable RDP for all users now (reached through an SSH tunnel)?" "${RDP_ENABLED:-n}"
  VNC_USERS=""
  prompt VNC_USERS "Users who get a personal VNC desktop now (space-separated, empty = none)" "" valid_vnc_users
  NEW_APPS=""
  info "Desktop apps for everyone with a desktop: $(awk -F'|' '{printf "%s ", $1}' <<<"$APP_CATALOG")(or any apt package)."
  prompt NEW_APPS "Desktop apps to install (space-separated, empty = none; later: vps-setup apps install)" "" valid_app_list

  step "Plan"
  info "Admin (sudo):        $ADMIN_USER"
  info "Developers:          ${DEV_USERS[*]:-(none)}"
  info "SSH:                 ports $SSH_PORTS, keys only, no root login, group $SSH_GROUP only"
  info "Firewall:            SSH$([[ $OPEN_WEB == y ]] && echo ' + 80/443') inbound, everything else blocked"
  info "Node.js:             $NODE_MAJOR   Docker: $INSTALL_DOCKER   Auto-reboot: $AUTO_REBOOT"
  info "Hostname/timezone:   $NEW_HOSTNAME / $TIMEZONE"
  if [[ -n $GITLAB_HOST ]]; then
    info "Internal GitLab:     $GITLAB_HOST - ports $(gitlab_ports), through the users' SSH connections"
  else
    info "Internal GitLab:     (none)"
  fi
  info "Office services:     ${FORWARDS:-(none)}"
  info "RDP: $RDP_ENABLED   VNC users: ${VNC_USERS:-(none)}   Desktop apps: ${NEW_APPS:-(none)}"
  while IFS=: read -r name _ uid _; do
    is_human_uid "$uid" || continue
    [[ $name == "$ADMIN_USER" || " ${DEV_USERS[*]} " == *" $name "* ]] && continue
    in_group "$name" "$SSH_GROUP" && continue
    others+=("$name")
  done < <(getent passwd)
  if (( ${#others[@]} > 0 )); then warn "These existing accounts will NOT be able to log in over SSH: ${others[*]} (add later: vps-setup add-user <name>)"; fi
}

step_packages() {
  ensure_swap   # first: a small VPS can run out of memory during the upgrade below
  migrate_v1
  # finish an upgrade that was interrupted earlier (dropped connection, reboot)
  run "Checking for an interrupted earlier upgrade" env DEBIAN_FRONTEND=noninteractive dpkg --configure -a
  run "Refreshing package lists" apt_get update
  run "Repairing broken dependencies (if any)" apt_get -f install
  run "Upgrading installed packages" apt_get dist-upgrade
  run "Installing base tools" apt_get install "${BASE_PKGS[@]}"
  apply_hostname_timezone
}

step_users() {
  local u
  ensure_group "$SSH_GROUP"; ensure_group "$DEV_GROUP"
  ensure_user "$ADMIN_USER" admin
  apply_keys "$ADMIN_USER" "$ADMIN_KEYS"
  if [[ -n $ADMIN_PASSWORD ]]; then set_password "$ADMIN_USER" "$ADMIN_PASSWORD" "$ADMIN_PW_GENERATED"; fi
  user_has_password "$ADMIN_USER" || die "$ADMIN_USER needs a password for sudo."
  for u in "${DEV_USERS[@]}"; do ensure_user "$u" dev; apply_keys "$u" "${DEV_KEYS[$u]}"; done
  note "Users: admin $ADMIN_USER; developers ${DEV_USERS[*]:-(none)}"
}

step_firewall() { local p; apply_firewall $(uniq_words $(current_ssh_ports) $SSH_PORTS); }
step_fail2ban() { apply_fail2ban $(current_ssh_ports) $SSH_PORTS; note "fail2ban guards SSH ports: $(uniq_words $(current_ssh_ports) $SSH_PORTS)"; }

step_rdp() {
  local u
  for u in "$ADMIN_USER" "${DEV_USERS[@]}"; do
    if ! user_has_password "$u"; then set_password "$u" "$(gen_password 16)" y; fi
  done
  cmd_rdp enable
}

users_table() { # one row per human account: what it has right now
  local name uid role pw keys vnc cl dk home
  printf '%-16s %-6s %-5s %-9s %-5s %-8s %-7s %s\n' USER ROLE SSH PASSWORD KEYS VNC CLAUDE DOCKER
  while IFS=: read -r name _ uid _ _ home _; do
    is_human_uid "$uid" || continue
    role=-; if in_group "$name" sudo; then role=admin; elif in_group "$name" "$DEV_GROUP"; then role=dev; fi
    pw=none; if user_has_password "$name"; then pw=set; fi
    keys=$(grep -cE '^(sk-)?(ssh-|ecdsa-)' "$home/.ssh/authorized_keys" 2>/dev/null || true)
    vnc=$(systemctl is-active "vps-vnc@$name.service" 2>/dev/null || true)
    cl=no; if [[ -x $home/.local/bin/claude || -x $home/.npm-global/bin/claude ]]; then cl=yes; fi
    dk=-
    if in_group "$name" docker; then dk=system
    elif [[ -S /run/user/$uid/docker.sock ]]; then dk=rootless
    elif [[ -f $home/.config/systemd/user/docker.service ]]; then dk=stopped; fi
    printf '%-16s %-6s %-5s %-9s %-5s %-8s %-7s %s\n' "$name" "$role" "$(in_group "$name" "$SSH_GROUP" && echo yes || echo no)" "$pw" "${keys:-0}" "${vnc:-inactive}" "$cl" "$dk"
  done < <(getent passwd)
}

services_summary() {
  local vnc
  vnc=$(systemctl list-units --plain --no-legend 'vps-vnc@*' 2>/dev/null | awk '{sub(/^vps-vnc@/, "", $1); sub(/\.service$/, "", $1); printf "%s ", $1}')
  printf 'SSH ports:          %s\n' "${SSH_PORTS:-22}"
  printf 'Internal GitLab:    %s\n' "${GITLAB_HOST:-(none)}${GITLAB_HOST:+ - ports $(gitlab_ports)}"
  printf 'Office services:    %s\n' "${FORWARDS:-(none)}"
  printf 'Personal services:  %s\n' "${FORWARDS_USER:-(none)}"
  printf 'RDP:                %s\n' "$([[ $RDP_ENABLED == y ]] && echo 'on (127.0.0.1:3389, SSH tunnel only)' || echo off)"
  printf 'VNC desktops:       %s\n' "${vnc:-(none)}"
  printf 'Desktop apps:       %s\n' "${APPS:-(none)}"
  printf 'Docker:             %s\n' "$([[ $INSTALL_DOCKER == y ]] && echo 'yes (admin: system, developers: rootless)' || echo no)"
}

connect_help() {
  printf 'Connect from each computer (VS Code: Remote-SSH -> Connect to Host -> %s):\n' "$(hostname -s)"
  printf '  - First time on the server, every user runs: claude   (log in with your own account)\n'
  printf '  - Long tasks: claude-session (tmux) - Claude keeps working after you disconnect;\n'
  printf '    run claude-session again to re-attach.\n'
  if [[ -n $GITLAB_HOST ]]; then
    printf '  - On the server: git clone git@%s:<group>/<project>.git, https://%s, ... work as on\n' "$(gitlab_primary)" "$(gitlab_primary)"
    printf '    your PC while at least one developer is connected with the config below%s.\n' \
      "$([[ $GITLAB_DIRECT == y ]] && echo ' (or directly, when nobody is)')"
  fi
  if [[ -n $FORWARDS ]]; then
    printf '  - Office services work on the server the same way: %s\n' "$FORWARDS"
  fi
  printf '  - Desktops on request: sudo vps-setup rdp enable | sudo vps-setup vnc enable <user>\n'
  printf '    VNC viewer: picture quality High / full colour (Auto or Low = 256 colours).\n'
  printf '  - Desktop apps: sudo vps-setup apps install vscode vlc ...  (list: sudo vps-setup apps list)\n'
  printf '  - Manage: sudo vps-setup help   |   status: sudo vps-setup status\n'
}

write_report() { # write_report [what changed] - the whole report, from the current state
  local u
  {
    printf 'vps-setup %s - %s, updated %s' "$SCRIPT_VERSION" "$(hostname -s)" "$(date '+%F %T')"
    if [[ -n ${1-} ]]; then printf ' (after: %s)' "$1"; fi
    printf '\n'
    if [[ -s $LAST_SETUP ]]; then printf '\n'; cat "$LAST_SETUP"; fi
    printf '\nUsers now:\n'; users_table | sed 's/^/  /'
    printf '\nServices now:\n'; services_summary | sed 's/^/  /'
    printf '\n'; connect_help
    printf '\nEach user has a sheet with their own config: %s/<user>.txt\n' "$USERS_DIR"
    for u in $(server_users); do printf '\n'; cmd_client_config "$u"; done
    if [[ -f /var/run/reboot-required ]]; then printf '\nA reboot is required to finish the updates: sudo reboot\n'; fi
  } >"$REPORT_FILE.new"
  chmod 600 "$REPORT_FILE.new"; mv -f "$REPORT_FILE.new" "$REPORT_FILE"
}

latest_creds() { # latest_creds <user> - the newest value of each credential vps-setup made
  local f="$CRED_DIR/$1.txt"
  [[ -s $f ]] || return 0
  # lines: "YYYY-MM-DD HH:MM:SS  <what, 16 wide> <value>"
  awk '{ w = substr($0, 22, 16); sub(/ +$/, "", w); v = substr($0, 39)
         if (!(w in seen)) order[++n] = w; seen[w] = 1; val[w] = v; at[w] = substr($0, 1, 19) }
       END { for (i = 1; i <= n; i++) printf "  %-16s %s   (%s)\n", order[i], val[order[i]], at[order[i]] }' "$f"
}

write_user_sheet() { # write_user_sheet <user> - everything one user needs, root only
  local u=$1 home uid role=developer creds
  home=$(home_of "$u"); uid=$(id -u "$u")
  if in_group "$u" sudo; then role="admin (sudo)"; fi
  creds=$(latest_creds "$u")
  {
    printf '%s on %s - updated %s\n' "$u" "$(hostname -s)" "$(date '+%F %T')"
    printf 'Hand this to %s privately (it can hold passwords), then delete the credentials\n' "$u"
    printf 'part from %s once they have changed them.\n\n' "$CRED_DIR"
    printf 'Account:          %s, %s, home %s\n' "$u" "$role" "$home"
    printf 'Linux password:   %s\n' "$(user_has_password "$u" && echo 'set (sudo, RDP, the desktop lock screen - never SSH)' || echo none)"
    printf 'SSH keys:         %s\n' "$(grep -cE '^(sk-)?(ssh-|ecdsa-)' "$home/.ssh/authorized_keys" 2>/dev/null || echo 0)"
    printf 'VNC desktop:      %s\n' "$(systemctl is-enabled --quiet "vps-vnc@$u.service" 2>/dev/null && echo 'yes - VNC viewer on localhost:5901 while connected' || echo no)"
    printf 'RDP desktop:      %s\n' "$([[ $RDP_ENABLED == y ]] && echo 'yes - Remote Desktop to localhost:13389 while connected' || echo no)"
    printf 'Docker:           %s\n' "$(if in_group "$u" docker; then echo system; elif [[ -f $home/.config/systemd/user/docker.service || -S /run/user/$uid/docker.sock ]]; then echo 'rootless (your own)'; else echo no; fi)"
    printf 'Desktop apps:     %s\n' "${APPS:-(none)}"
    printf 'Office services:  %s\n' "$(fwd_for_user "$u" | sed 's/^$/(none)/')"
    if [[ -n $creds ]]; then printf '\nCredentials made by vps-setup (newest of each):\n%s\n' "$creds"; fi
    printf '\n'; connect_help
    printf '\n'; cmd_client_config "$u"
  } >"$USERS_DIR/$u.txt.new"
  chmod 600 "$USERS_DIR/$u.txt.new"; mv -f "$USERS_DIR/$u.txt.new" "$USERS_DIR/$u.txt"
}

refresh_files() { # refresh_files [what changed] - the report and every user sheet
  local u f users
  write_report "${1-}"
  install -d -m 700 "$USERS_DIR"
  users=" $(server_users | xargs) "
  for u in $users; do write_user_sheet "$u"; done
  for f in "$USERS_DIR"/*.txt; do
    [[ -e $f ]] || continue
    u=${f##*/}; u=${u%.txt}
    if [[ $users != *" $u "* ]]; then rm -f "$f"; fi   # removed users
  done
}

print_report() {
  local row s t failed=0 color
  {
    printf 'Last full setup: %s\n' "$(date '+%F %T')"
    printf '\nSteps:\n'
    for row in "${RESULTS[@]}"; do IFS=$'\t' read -r s t <<<"$row"; printf '  %-8s %s\n' "${s^^}" "$t"; done
    if [[ -s $RUN_NOTES ]]; then printf '\nDetails:\n'; sed 's/^/  - /' "$RUN_NOTES"; fi
  } >"$LAST_SETUP"
  chmod 600 "$LAST_SETUP"
  refresh_files "setup"

  step "Result"
  for row in "${RESULTS[@]}"; do
    IFS=$'\t' read -r s t <<<"$row"
    case $s in ok) color=$C_G ;; FAILED) color=$C_R; failed=$((failed + 1)) ;; *) color=$C_Y ;; esac
    printf '    %s%-8s%s %s\n' "$color" "${s^^}" "$C_0" "$t"
  done
  sed -n '/^\(Details\|Connect\)/,$p' "$REPORT_FILE" | sed '1s/^/\n/'
  print_credentials
  printf '\n'
  info "This report (without credentials): $REPORT_FILE     Full log: $LOG_FILE"
  info "One sheet per user (their config + any new passwords; root only): $USERS_DIR/<user>.txt"
  if (( failed > 0 )); then
    warn "$failed step(s) failed - fix the cause and run 'sudo vps-setup setup' again (it is safe to re-run)."
    exit 1
  fi
}

# Over SSH, a dropped connection kills a setup running in that session - possibly in the
# middle of a package upgrade. Inside tmux it keeps running; reconnect and re-attach.
maybe_use_tmux() {
  local use src cmd
  if [[ -n ${TMUX-} || -n ${STY-} ]] || ! command -v tmux >/dev/null; then return 0; fi
  info "If your SSH connection drops, a setup running directly in it is stopped half-way."
  prompt_yn use "Run the setup inside tmux so it keeps going if the connection drops?" y
  [[ $use == y ]] || return 0
  src=$(readlink -f "${BASH_SOURCE[0]}")
  cmd="bash $(printf '%q' "$src") setup; printf '\nSetup finished - the report is in $REPORT_FILE. Press Enter to close. '; read -r _"
  info "Starting tmux session 'vps-setup'. If you get disconnected, log in again and run:"
  info "    sudo tmux attach -t vps-setup"
  sleep 3
  exec 9>&-   # don't hand the run lock to tmux
  exec tmux new-session -A -s vps-setup "$cmd"
}

cmd_setup() {
  need_tty
  check_os
  maybe_use_tmux
  install_self
  printf '\n%sClaude Code dev server setup - vps-setup %s%s\n' "$C_B" "$SCRIPT_VERSION" "$C_0"
  info "Ubuntu $(. /etc/os-release && printf '%s' "$VERSION_ID"), $(nproc) CPU, $(awk '/^MemTotal:/ {printf "%.1f GB RAM", $2/1048576}' /proc/meminfo)"
  if [[ $SETUP_DONE == y ]]; then
    local again; prompt_yn again "This server is already set up (admin: $ADMIN_USER). Run the setup again and update everything in place?" n
    [[ $again == y ]] || exit 0
  fi
  collect_answers
  local go; prompt_yn go "Apply this now? (every step runs; failures are reported at the end)" y
  [[ $go == y ]] || die "Aborted - nothing was changed."
  log_file "setup started by ${SUDO_USER:-root}"
  IN_SETUP=y
  save_config

  local u
  try_step "Packages and base tools" step_packages
  try_step "Users and SSH keys" step_users
  try_step "Remove the old dev-apt helper (if present)" remove_dev_apt
  try_step "Shell defaults, tmux, claude-session" apply_shell_defaults
  try_step "System hardening and tuning" apply_system_tuning
  try_step "Fair resource sharing between users" apply_fair_share
  try_step "Memory guard (zswap, systemd-oomd)" apply_memory_guard
  try_step "Firewall" step_firewall
  try_step "fail2ban" step_fail2ban
  try_step "Node.js $NODE_MAJOR (system)" install_node
  try_step "Go (latest, system-wide)" install_go
  if step_ok "Users and SSH keys"; then
    try_step "Tools for every user (nvm + Node $NODE_MAJOR, bun, uv)" step_user_tools "$ADMIN_USER" "${DEV_USERS[@]}"
    try_step "Claude Code for every user" step_claude "$ADMIN_USER" "${DEV_USERS[@]}"
  else
    skip_step "Tools and Claude Code for every user" "the users step failed"
  fi
  if [[ $INSTALL_DOCKER == y ]]; then
    try_step "Docker" install_docker
    if (( ${#DEV_USERS[@]} > 0 )); then
      if step_ok "Docker" && step_ok "Users and SSH keys"; then
        try_step "Docker for developers (rootless, one per user)" step_docker_users "${DEV_USERS[@]}"
      else
        skip_step "Docker for developers" "the Docker or users step failed"
      fi
    fi
  fi
  if [[ -n $GITLAB_HOST ]]; then try_step "Internal GitLab ($GITLAB_HOST)" gitlab_apply
  elif systemctl list-unit-files "$GITLAB_UNIT" >/dev/null 2>&1 && [[ -f /etc/systemd/system/$GITLAB_UNIT ]]; then
    try_step "Remove internal GitLab gateway" gitlab_disable
  fi
  if [[ -n $(fwd_targets) ]]; then try_step "Office services (${FORWARDS:-personal only})" fwd_apply
  elif [[ -f /etc/systemd/system/$FWD_UNIT ]]; then try_step "Remove the office-services gateway" fwd_disable
  fi
  if [[ $RDP_ENABLED == y ]]; then try_step "RDP desktop" step_rdp; fi
  for u in $VNC_USERS; do try_step "VNC desktop for $u" cmd_vnc enable "$u"; done
  if [[ -n $NEW_APPS ]]; then try_step "Desktop apps ($NEW_APPS)" apps_install $NEW_APPS; fi

  if step_ok "Users and SSH keys" && step_ok "Firewall"; then
    try_step "SSH hardening (ports $SSH_PORTS, auto-rollback)" ssh_apply $SSH_PORTS
  else
    skip_step "SSH hardening" "users or firewall step failed - SSH left unchanged so you can't be locked out"
  fi
  SETUP_DONE=y; save_config
  print_report
}

# ----------------------------------------------------------------------------
# Other commands
# ----------------------------------------------------------------------------
cmd_add_user() {
  need_tty
  local u="" role=dev pw="" gen=n vnc="" apps="" apps_set=n fwds="" fwds_set=n n
  while (( $# > 0 )); do
    case $1 in
      --admin) role=admin ;;
      --vnc) vnc=y ;;
      --apps) apps=${2-}; apps_set=y; shift || true ;;
      --apps=*) apps=${1#--apps=}; apps_set=y ;;
      --forward) fwds=${2-}; fwds_set=y; shift || true ;;
      --forward=*) fwds=${1#--forward=}; fwds_set=y ;;
      -*) die "Unknown option $1" ;;
      *) u=$1 ;;
    esac
    shift
  done
  [[ -n $u ]] || prompt u "Username" "" valid_username
  valid_username "$u" || exit 1
  if [[ $apps_set == y ]]; then valid_app_list "$apps" || exit 1
  else prompt apps "Desktop apps to install (e.g. vscode vlc; empty = none; list: vps-setup apps list)" "" valid_app_list
  fi
  [[ -n $vnc ]] || prompt_yn vnc "A personal VNC desktop for $u?" n
  if [[ $fwds_set == y ]]; then valid_forward_list "$fwds" || exit 1
  else prompt fwds "Office services only for $u (host:port or URL; empty = none; for everyone: vps-setup forward add)" "" valid_forward_list
  fi
  ensure_group "$SSH_GROUP"; ensure_group "$DEV_GROUP"
  collect_keys "$u"
  local keys=$KEYS_OUT
  if [[ $role == admin ]] && ! user_has_password "$u"; then prompt_password pw "Password for $u (used for sudo)"; gen=$PW_GENERATED; fi
  ensure_user "$u" "$role"
  apply_keys "$u" "$keys"
  if [[ -n $pw ]]; then set_password "$u" "$pw" "$gen"; fi
  if [[ $RDP_ENABLED == y ]] && ! user_has_password "$u"; then set_password "$u" "$(gen_password 16)" y; fi
  install_user_tools_for "$u" || true
  install_claude_for "$u" || true
  if [[ $INSTALL_DOCKER == y && $role == dev ]]; then docker_rootless_for "$u" || warn "Docker for $u failed - retry: sudo vps-setup docker $u"; fi
  if [[ $vnc == y ]]; then
    ( IN_SETUP=y; cmd_vnc enable "$u" ) || warn "The VNC desktop for $u failed - retry: sudo vps-setup vnc enable $u"
  fi
  if [[ -n $apps ]]; then
    # shellcheck disable=SC2086
    ( apps_install $apps ) || warn "Some apps failed - retry: sudo vps-setup apps install $apps"
  fi
  if [[ -n $fwds ]]; then
    for n in $(fwd_normalize "$fwds"); do
      if [[ " $FORWARDS " != *" $n "* ]]; then FORWARDS_USER=$(uniq_words $FORWARDS_USER "$u=$n"); fi
    done
    save_config
    ( fwd_apply ) || warn "The office services failed - retry: sudo vps-setup forward apply"
  fi
  ok "$u added as $role."
  printf '\n'; cmd_client_config "$u"
  print_credentials
}

cmd_remove_user() {
  need_tty
  local u=${1-} uid confirm keep home
  [[ -n $u ]] || die "usage: vps-setup remove-user <user>"
  uid=$(id -u "$u" 2>/dev/null) || die "No user '$u'."
  is_human_uid "$uid" || die "'$u' is a system account."
  [[ $u != "$ADMIN_USER" ]] || die "$u is the primary admin of this setup."
  [[ $u != "${SUDO_USER-}" ]] || die "You can't remove yourself."
  prompt confirm "Type '$u' again to delete this user" "" accept_any
  [[ $confirm == "$u" ]] || die "Aborted."
  prompt_yn keep "Archive $u's home directory to $ARCHIVE_DIR first?" y
  home=$(home_of "$u")
  systemctl disable --now "vps-vnc@$u.service" >>"$LOG_FILE" 2>&1 || true
  loginctl disable-linger "$u" 2>/dev/null || true
  loginctl terminate-user "$u" 2>/dev/null || true
  pkill -KILL -u "$u" 2>/dev/null || true
  sleep 1
  if [[ $keep == y && -d $home ]]; then
    install -d -m 700 "$ARCHIVE_DIR"
    tar -C "$(dirname "$home")" -czf "$ARCHIVE_DIR/$u-$(date +%Y%m%d-%H%M%S).tar.gz" "$(basename "$home")"
    info "Archived to $ARCHIVE_DIR."
  fi
  userdel -r "$u" >>"$LOG_FILE" 2>&1 || userdel "$u"
  rm -f "$CRED_DIR/$u".*
  if [[ " $FORWARDS_USER " == *" $u="* ]]; then
    FORWARDS_USER=$(printf '%s\n' $FORWARDS_USER | awk -v p="$u=" 'index($0, p) != 1' | xargs); save_config
    ( fwd_apply ) || warn "Could not update the office services - run: sudo vps-setup forward apply"
  fi
  ok "Removed $u."
}

cmd_add_key() {
  need_tty
  local u=${1-}
  [[ -n $u ]] && id "$u" &>/dev/null || die "usage: vps-setup add-key <existing user>"
  collect_keys "$u" y
  apply_keys "$u" "$KEYS_OUT"
  ok "Key added for $u."
  print_credentials
}

cmd_password() {
  need_tty
  local u=${1-} uid pw
  [[ -n $u ]] || die "usage: vps-setup password <user>"
  uid=$(id -u "$u" 2>/dev/null) || die "No user '$u'."
  is_human_uid "$uid" || die "'$u' is a system account."
  prompt_password pw "New password for $u"
  set_password "$u" "$pw" "$PW_GENERATED"
  ok "Password set for $u (used for sudo/RDP - SSH stays key-only). They can change it with 'passwd'."
  print_credentials
}

cmd_ssh() {
  need_tty
  local ports=""
  while (( $# > 0 )); do
    case $1 in --ports|--port) ports=${2-}; shift 2 || die "$1 needs a value" ;; *) die "usage: vps-setup ssh [--ports \"22 9011\"]" ;; esac
  done
  [[ -n $ADMIN_USER ]] || die "Run the setup first."
  if [[ -z $ports ]]; then prompt ports "SSH ports (space-separated)" "${SSH_PORTS:-22}" valid_ssh_ports; fi
  valid_ssh_ports "$ports" || exit 1
  ssh_apply $(for p in $ports; do echo $((10#$p)); done)
  print_credentials
}

cmd_gitlab() {
  case ${1-} in
    disable) gitlab_disable ;;
    ""|apply)
      [[ -n $GITLAB_HOST ]] || die "No GitLab configured - run 'sudo vps-setup setup' or set GITLAB_HOST/GITLAB_SSH_PORT/GITLAB_PORTS in $CONF_FILE."
      gitlab_apply
      info "Re-send each user their config: sudo vps-setup client-config <user>"
      ;;
    *) die "usage: vps-setup gitlab [apply|disable]" ;;
  esac
}

# ----------------------------------------------------------------------------
# Resource usage per user, from each user's cgroup (user-<uid>.slice): everything a
# user runs is counted - SSH/VS Code sessions, Claude, tmux, their VNC desktop and
# their rootless Docker containers.
# ----------------------------------------------------------------------------
# usage_snapshot <slice dir>... - every counter of every slice in ONE awk process (no
# per-user commands), so it stays cheap and quick even when the server is overloaded.
usage_snapshot() {
  awk -v dirs="$*" '
    function val(f,   v) { v = 0; if ((getline v < f) <= 0) v = 0; close(f); return v + 0 }
    BEGIN {
      while ((getline line < "/etc/passwd") > 0) { split(line, p, ":"); user[p[3]] = p[1] }
      close("/etc/passwd")
      n = split(dirs, d, " ")
      for (k = 1; k <= n; k++) {
        dir = d[k]; base = dir; sub(/.*\//, "", base)
        if (base == "system.slice") name = "(system services)"
        else if (base == "user.slice") name = "(all users)"
        else { uid = base; gsub(/[^0-9]/, "", uid); name = (uid in user) ? user[uid] : "uid " uid }
        cpu = 0; f = dir "/cpu.stat"
        while ((getline line < f) > 0) { split(line, a, " "); if (a[1] == "usage_usec") cpu = a[2] }
        close(f)
        anon = 0; file = 0; f = dir "/memory.stat"
        while ((getline line < f) > 0) { split(line, a, " "); if (a[1] == "anon") anon = a[2]; else if (a[1] == "file") file = a[2] }
        close(f)
        r = 0; w = 0; f = dir "/io.stat"
        while ((getline line < f) > 0) {
          m = split(line, a, " ")
          for (i = 2; i <= m; i++) { split(a[i], kv, "="); if (kv[1] == "rbytes") r += kv[2]; else if (kv[1] == "wbytes") w += kv[2] }
        }
        close(f)
        printf "%s|%.0f|%.0f|%.0f|%.0f|%.0f|%.0f|%.0f|%.0f\n", name, cpu, anon, file,
          val(dir "/memory.swap.current"), val(dir "/memory.low"), r, w, val(dir "/pids.current")
      }
    }'
}

usage_table() { # usage_table <seconds> <cpu|mem> [user] - CPU and disk measured over <seconds>
  local secs=$1 sort=$2 only=${3-} cg=/sys/fs/cgroup d uid only_uid="" s1 s2 slices=()
  if [[ -n $only ]]; then only_uid=$(id -u "$only"); fi
  for d in "$cg"/user.slice/user-*.slice; do
    uid=${d##*/user-}; uid=${uid%.slice}
    [[ $uid =~ ^[0-9]+$ ]] && is_human_uid "$uid" || continue
    if [[ -n $only_uid && $uid != "$only_uid" ]]; then continue; fi
    slices+=("$d")
  done
  if [[ -z $only ]]; then for d in "$cg/system.slice" "$cg/user.slice"; do [[ -d $d ]] && slices+=("$d"); done; fi
  (( ${#slices[@]} > 0 )) || { printf 'No user is running anything right now.\n'; return 0; }
  s1=$(usage_snapshot "${slices[@]}")
  sleep "$secs"
  s2=$(usage_snapshot "${slices[@]}")
  printf '%-18s %7s %7s %8s %8s %7s %9s %8s %8s %6s\n' USER "CPU%" "SERVER" "RAM MB" "CACHE MB" "SWAP MB" "PROT. MB" "READ/s" "WRITE/s" PROCS
  printf '%s\n--\n%s\n' "$s1" "$s2" | awk -F'|' -v secs="$secs" -v ncpu="$(nproc)" -v sort="$sort" '
    function mb(b) { return sprintf("%.0f", b / 1048576) }
    $0 == "--" { second = 1; next }
    !second { c0[$1] = $2; r0[$1] = $7; w0[$1] = $8; next }
    {
      cpu = ($2 - c0[$1]) / (secs * 1e6) * 100        # 100 = one full core
      if (cpu < 0) cpu = 0
      key = (sort == "mem") ? $3 : cpu
      printf "%d\t%020.3f\t%-18s %7.1f %6.1f%% %8s %8s %7s %9s %8.1f %8.1f %6d\n",
        ($1 ~ /^\(/), key, $1, cpu, cpu / ncpu, mb($3), mb($4), mb($5), mb($6),
        ($7 - r0[$1]) / secs / 1048576, ($8 - w0[$1]) / secs / 1048576, $9
    }' | sort -t$'\t' -k1,1n -k2,2r | cut -f3-
}

usage_disk() { # home sizes (Docker images and containers included: they live in the home)
  local u home
  printf '%-18s %s\n' USER "HOME (incl. Docker data)"
  for u in $(server_users); do
    home=$(home_of "$u")
    printf '%-18s %s\n' "$u" "$(du -sxh "$home" 2>/dev/null | cut -f1)"
  done
  df -h / | awk 'NR == 2 {print "disk /: " $3 " used of " $2 " (" $5 "), " $4 " free"}'
}

usage_user() { # usage_user <user> - one user in detail
  local u=$1 uid sock
  uid=$(id -u "$u")
  usage_table 2 cpu "$u"
  printf '\nTop processes of %s right now (CPU over 1 s; 100 = one core):\n' "$u"
  # top's second sample is the live one (the first is the average since each process started)
  top -b -c -n 2 -d 1 -u "$u" -o %CPU -w 160 2>/dev/null \
    | awk '/^top - / {n++} n == 2 && /^ *PID / {p = 1} p && c++ < 16' | cut -c1-160
  sock=/run/user/$uid/docker.sock
  if [[ -S $sock ]]; then
    printf '\nDocker containers of %s:\n' "$u"
    timeout 20 runuser -u "$u" -- env XDG_RUNTIME_DIR="/run/user/$uid" DOCKER_HOST="unix://$sock" \
      docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.BlockIO}}' 2>/dev/null \
      || printf '  (none running, or Docker did not answer)\n'
  fi
}

cmd_usage() {
  local a secs=3 sort=cpu watch=n disk=n u=""
  while (( $# > 0 )); do
    case $1 in
      --watch|-w) watch=y; if [[ ${2-} =~ ^[0-9]+$ ]]; then secs=$2; shift; fi ;;
      --mem) sort=mem ;;
      --disk) disk=y ;;
      -*) die "usage: vps-setup usage [<user>] [--mem] [--watch [seconds]] [--disk]" ;;
      *) u=$1 ;;
    esac
    shift
  done
  [[ -f /sys/fs/cgroup/cgroup.controllers ]] || die "This server has no cgroup v2 - per-user numbers are not available."
  # Stay responsive on a busy server: ahead of the admin's own other work (other users
  # are kept apart by the fair-share weights anyway); reading the numbers costs almost nothing.
  renice -n -10 -p $$ >/dev/null 2>&1 || true
  ionice -c 2 -n 0 -p $$ >/dev/null 2>&1 || true
  if [[ -n $u ]]; then id "$u" &>/dev/null || die "No user '$u'."; usage_user "$u"; return 0; fi
  if [[ $disk == y ]]; then usage_disk; return 0; fi
  if [[ $watch == y ]]; then
    while :; do
      a=$(usage_table "$secs" "$sort")
      clear
      printf 'Per-user usage on %s, every %s s (Ctrl-C to stop)   load %s   %s CPUs\n\n' \
        "$(hostname -s)" "$secs" "$(cut -d' ' -f1-3 /proc/loadavg)" "$(nproc)"
      printf '%s\n' "$a"
    done
  fi
  usage_table "$secs" "$sort"
  printf '\nCPU%%: 100 = one full core (%s cores = %s); SERVER: share of the whole CPU.\n' "$(nproc)" "$(( $(nproc) * 100 ))"
  printf 'RAM: programs; CACHE: file cache (given back when needed); PROT.: memory protected for\n'
  printf 'that user right now (fair share). READ/WRITE: disk MB/s. Measured over %s s.\n' "$secs"
  printf 'More: vps-setup usage <user> | --mem | --watch | --disk\n'
}

cmd_status() {
  local eff
  step "Users"
  users_table | sed 's/^/    /'

  step "SSH"
  if eff=$(sshd_cmd -T 2>/dev/null); then
    info "$(grep -E '^(port|passwordauthentication|permitrootlogin|allowgroups) ' <<<"$eff" | tr '\n' ' ')"
  fi
  if ssh_verify ${SSH_PORTS:-22} 2>/dev/null; then ok "Effective sshd config matches the hardening."; else warn "sshd config differs from the hardening - run: sudo vps-setup ssh"; fi
  local p; for p in ${SSH_PORTS:-22}; do if port_listening "$p"; then info "port $p: listening"; else warn "port $p: NOT listening"; fi; done
  if ssh_change_pending; then warn "An SSH change is waiting for $ADMIN_USER's first login (auto-rollback pending)."; fi

  step "Internal GitLab"
  if [[ -n $GITLAB_HOST ]]; then
    if systemctl is-active --quiet "$GITLAB_UNIT"; then ok "Gateway running: $GITLAB_HOST -> $GITLAB_IP, ports $(gitlab_ports), direct fallback: ${GITLAB_DIRECT:-n}"; else warn "Gateway NOT running: sudo vps-setup gitlab"; fi
    info "Tunnels present (user:port): $(gitlab_tunnels)"
  else
    info "not configured"
  fi

  step "Office services"
  fwd_list

  step "Desktop apps"
  info "${APPS:-(none)}   (sudo vps-setup apps list)"

  step "Resource sharing (CPU/disk by equal weight; memory part re-balanced every 30 s)"
  if [[ -x $LIB_DIR/fairshare ]]; then
    "$LIB_DIR/fairshare" --dry-run 2>/dev/null | sed 's/^/    /' || true
    systemctl is-active --quiet vps-fairshare.timer || warn "vps-fairshare.timer is not running - run: sudo vps-setup setup"
  else
    info "not set up"
  fi

  step "Firewall"
  ufw status verbose 2>/dev/null | sed 's/^/    /' || true
  step "fail2ban"
  fail2ban-client status sshd 2>/dev/null | grep -E 'Currently banned|Total banned|Banned IP' | sed 's/^[|` -]*/    /' || info "not running"

  step "Remote desktop"
  if systemctl is-active --quiet xrdp; then
    if rdp_listening_safely; then ok "RDP active on 127.0.0.1:$RDP_LOCAL_PORT (SSH tunnel only)"; else warn "RDP is active but NOT bound to localhost only!"; fi
  else info "RDP: off"; fi
  systemctl list-units --plain --no-legend 'vps-vnc@*' 2>/dev/null | awk '{print "    VNC: " $1 " " $4}' || true

  step "System"
  info "$(uptime -p), load $(cut -d' ' -f1-3 /proc/loadavg)"
  free -h | awk 'NR > 1 {printf "    %-6s total %s, used %s\n", $1, $2, $3}'
  df -h / | awk 'NR == 2 {print "    disk / " $3 " used of " $2 " (" $5 ")"}'
  if [[ -f /var/run/reboot-required ]]; then warn "Reboot required (pending updates)."; fi
}

usage() {
  cat <<EOF
vps-setup $SCRIPT_VERSION - shared Claude Code dev server on Ubuntu

  setup                        First-time setup (interactive). Runs every step, reports
                               failures at the end. Safe to re-run.
  status                       Users, SSH, GitLab gateway, firewall, fail2ban, desktops.

  add-user <name> [--admin] [--vnc] [--apps "vscode vlc"] [--forward "host:port ..."]
                               Add a developer (or an admin with full sudo), optionally
                               with a VNC desktop, desktop apps and personal office
                               services (asked when not given).
  remove-user <name>           Remove a user (their home is archived first).
  add-key <name>               Add another SSH public key for a user.
  password <name>              Set or reset a password (used for sudo and RDP - never for SSH).
  client-config <name>         Print the ~/.ssh/config block for that user's computer
                               (several server ports with fallback + the GitLab tunnel).

  docker <name>                (Re)create that developer's private rootless Docker.
  rdp enable|disable           RDP desktop for every user, through an SSH tunnel.
  vnc enable|disable <name> [--new-password] [--reset-look]
                               A personal VNC desktop for one user, through an SSH tunnel.
                               Enabling again keeps the password; --reset-look moves the
                               user's old desktop settings aside.
  vnc timeout <30m|2h|3d|off> [<name>]
                               After its user disconnects, a VNC desktop closes with all its
                               apps once this time has passed (default 5m). Without a name:
                               the server default. Users set their own with: vnc-timeout 2h
  memory [apply|status]        zswap (compressed swap in RAM) and the OOM guard: systemd-oomd
                               ends a thrashing user's heaviest app or VNC desktop, never sshd.
  apps install|remove <app>... Desktop apps for every desktop user: vscode, chrome, firefox,
  apps list                    vlc, gimp, libreoffice, ... or any Ubuntu package (no snaps).
  gitlab [apply|disable]       Re-apply (after editing GITLAB_* in $CONF_FILE) or remove
                               the internal GitLab gateway.
  forward add <host:port|URL> [--user <name>]
  forward remove ... [--user <name>]   |   forward list|apply
                               Make an office service reachable on the server like on your
                               PC (e.g. http://192.168.2.212:8100/docs). Without --user: for
                               everyone, through anyone's SSH connection. With --user: only
                               for that user, only through their own connection. Each user
                               then updates their ssh config (their sheet has it).
  usage [<user>] [--mem] [--watch [s]] [--disk]
                               CPU, RAM, swap, disk I/O and processes per user (their
                               desktop and Docker included); one user in detail; home sizes.
  report                       Rewrite $REPORT_FILE and $USERS_DIR/<user>.txt
                               (done by itself after every change).

  ssh [--ports "22 9011"]      Re-apply the SSH hardening or change its ports (auto-rollback).
  confirm                      Keep a pending SSH change now (otherwise it is kept on the
                               admin's first login, or rolled back after $ROLLBACK_MINUTES minutes).
  help                         This text.

Developers have no root: they install tools without it (npm -g, pipx, ~/.local/bin),
use their own rootless Docker, and ask the admin for system packages (sudo apt install).
EOF
}

main() {
  local cmd=${1-}
  if (( $# > 0 )); then shift; fi
  case $cmd in help|-h|--help) usage; return 0 ;; esac
  [[ $EUID -eq 0 ]] || die "This needs root. Run it as the admin with sudo:  sudo vps-setup ${cmd:-status} $*"
  init_state
  trap 'on_error $LINENO' ERR
  if [[ -z $cmd ]]; then
    if [[ $SETUP_DONE == y ]]; then cmd=status; else cmd=setup; fi
  fi
  if [[ $cmd == _ssh-rollback ]]; then
    # Fired by the timer: keep the change if the admin logged in through it, else undo it.
    if ssh_change_pending; then
      if ssh_login_seen; then ssh_finalize
      else
        ssh_restore || true
        wall "vps-setup: an SSH change saw no login by $ADMIN_USER within $ROLLBACK_MINUTES minutes and was rolled back." 2>/dev/null || true
      fi
    fi
    return 0
  fi
  case $cmd in
    status|client-config|usage) ;;
    *)
      # one changing run at a time (e.g. a second setup while the first still runs in tmux)
      exec 9>"$STATE_DIR/.lock"
      if ! flock -n 9; then
        die "Another vps-setup run is still going. If it runs in tmux: sudo tmux attach -t vps-setup"
      fi
      ;;
  esac
  case $cmd in
    setup|status|client-config|help|report|usage) ;;
    forward|apps) if [[ ${1-} != list && -n ${1-} ]]; then REFRESH_FOR="$cmd $*"; fi ;;
    *) REFRESH_FOR="$cmd $*" ;;
  esac
  begin_run
  trap end_run EXIT
  case $cmd in
    setup)         cmd_setup "$@" ;;
    status)        cmd_status ;;
    add-user)      cmd_add_user "$@" ;;
    remove-user)   cmd_remove_user "$@" ;;
    add-key)       cmd_add_key "$@" ;;
    password)      cmd_password "$@" ;;
    client-config) cmd_client_config "$@" ;;
    docker)
      [[ $INSTALL_DOCKER == y ]] || die "Docker is not set up - run 'sudo vps-setup setup' and answer yes to Docker."
      [[ -n ${1-} ]] && id "$1" &>/dev/null || die "usage: vps-setup docker <user>"
      docker_rootless_for "$1"; ok "Rootless Docker ready for $1." ;;
    rdp)           cmd_rdp "$@" ;;
    vnc)           cmd_vnc "$@" ;;
    memory)        cmd_memory "$@" ;;
    gitlab)        cmd_gitlab "$@" ;;
    forward)       cmd_forward "$@" ;;
    usage)         cmd_usage "$@" ;;
    report)        refresh_files "report"; ok "Updated: $REPORT_FILE and $USERS_DIR/<user>.txt" ;;
    apps)          cmd_apps "$@" ;;
    ssh)           cmd_ssh "$@" ;;
    confirm)
      ssh_change_pending || die "No SSH change is pending."
      ssh_finalize; ok "SSH change kept (ports $SSH_PORTS)." ;;
    *) usage >&2; exit 2 ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
