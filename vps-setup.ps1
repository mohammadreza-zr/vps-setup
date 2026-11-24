#Requires -Version 5.1
<#
=============================================================================
vps-setup.ps1 - turns a fresh Windows Server into a hardened, shared Claude Code
development server, then manages it (users, keys, remote desktop, SSH, internal
GitLab access, office services).

The Windows counterpart of vps-setup.sh (Ubuntu): the same features, built only from
what Windows Server itself has - OpenSSH (a Windows capability), Windows Defender
Firewall, Task Scheduler, the event log, Remote Desktop (optionally the RDS role),
Windows Update and the .NET compiler. Nothing else is downloaded or installed: users
install their own tools (Claude Code, Git, Node...) in their profile, without admin rights.
See "Differences from the Ubuntu version" in: vps-setup help

First run (as an administrator, from a saved file, in the console or an RDP session):
    powershell -ExecutionPolicy Bypass -File .\vps-setup.ps1
It asks everything first, then does every server-side job. A step that fails is
reported and the rest still runs; a full result report is printed at the end (and
saved to C:\ProgramData\vps-setup\report.txt, without secrets).

Afterwards it is installed as the command  vps-setup  (C:\Program Files\vps-setup):
    vps-setup help        (elevated PowerShell/cmd, or over SSH as the admin)

Supported: Windows Server 2019, 2022 and 2025 (x64, Desktop Experience for the RDP
desktops) and later releases. Runs on the built-in Windows PowerShell 5.1 (pwsh
hands over to it).
Log (never contains secrets): C:\ProgramData\vps-setup\vps-setup.log
Generated passwords/keys:     C:\ProgramData\vps-setup\credentials (administrators only)
=============================================================================
#>

# Windows PowerShell 5.1 is part of every supported Windows Server and has every module
# used here (LocalAccounts, NetSecurity, ScheduledTasks) - pwsh hands over to it.
if ($PSVersionTable.PSEdition -eq 'Core') {
  & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @args
  exit $LASTEXITCODE
}

Set-StrictMode -Version 1
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # no progress bars from Windows' own cmdlets (capabilities, features)

$SCRIPT_VERSION = '2.2.0-windows'
$INSTALL_DIR = Join-Path $env:ProgramFiles 'vps-setup'
$INSTALL_PATH = Join-Path $INSTALL_DIR 'vps-setup.ps1'
$STATE_DIR = Join-Path $env:ProgramData 'vps-setup'      # administrators and SYSTEM only
$CONF_FILE = "$STATE_DIR\config.json"
$BACKUP_DIR = "$STATE_DIR\backup"
$ROLLBACK_DIR = "$STATE_DIR\ssh-rollback"
$RUN_NOTES = "$STATE_DIR\.run-notes"
$RUN_CREDS = "$STATE_DIR\.run-creds"
$CRED_DIR = "$STATE_DIR\credentials"
$ARCHIVE_DIR = "$STATE_DIR\archive"
$REPORT_FILE = "$STATE_DIR\report.txt"
$LOG_FILE = "$STATE_DIR\vps-setup.log"
$USERS_DIR = "$STATE_DIR\users"                          # one up-to-date sheet per user
$LAST_SETUP = "$STATE_DIR\last-setup.txt"                # steps + details of the last full setup
$BAN_STATE = "$STATE_DIR\ban-state.json"
$GW_EXE = "$INSTALL_DIR\vps-gw.exe"
$GW_CONF = "$STATE_DIR\gw.conf"
$GW_LOG = "$STATE_DIR\gw.log"
$GW_SERVICE = 'vps-gw'
$GITLAB_IP = '127.77.0.1'          # what the GitLab hostname(s) resolve to on the server
$GITLAB_SSH_ALT_PORT = 47022       # GitLab's SSH on the server when its port is an SSH port here
$FWD_NAME_NET = '127.77.1'         # office hostnames resolve to 127.77.1.<n> here
$LOOPBACK_NAME = 'vps-setup-loopback'   # holds office IP addresses (vps-setup forward add <ip>:<port>)
# Every user's tunnels (RemoteForward) land on their own block of loopback ports:
# TUNNEL_BASE + slot * 100 + n   (n 0-19: GitLab ports, 20+: office services)
$TUNNEL_BASE = 20000
$TUNNEL_SLOT_SIZE = 100
$TUNNEL_FWD_OFFSET = 20
$MAX_SLOT = 290                    # stays below Windows' dynamic port range (49152+)
$SSH_GROUP = 'ssh-users'           # only members may log in over SSH
$DEV_GROUP = 'devs'                # marks developers (no admin rights of any kind)
$RDP_LOCAL_PORT = 3389
$TASK_PATH = '\vps-setup\'
$ROLLBACK_TASK = 'ssh-rollback'
$BAN_TASK = 'ssh-ban'
$ROLLBACK_MINUTES = 10
$FW_GROUP = 'vps-setup'
$SID_ADMINS = 'S-1-5-32-544'
$SID_USERS = 'S-1-5-32-545'
$SID_RDP = 'S-1-5-32-555'
$SID_SYSTEM = 'S-1-5-18'
$HOSTS_FILE = "$env:SystemRoot\System32\drivers\etc\hosts"
$SSHD_DATA = Join-Path $env:ProgramData 'ssh'
$SSHD_CONFIG = "$SSHD_DATA\sshd_config"
$ADMIN_KEYS_FILE = "$SSHD_DATA\administrators_authorized_keys"
$SSH_CLIENT_CONFIG = "$SSHD_DATA\ssh_config"
$WINPS = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$RESERVED_NAMES = @('administrator', 'guest', 'defaultaccount', 'wdagutilityaccount', 'sshd', 'system', 'git')

# Answers / state (config.json). Lists are space-separated words, as in the Ubuntu version.
# GITLAB_HOST may list several names (the first is the main one). FORWARDS: office services
# for everyone; FORWARDS_USER: personal ones (user=host:port). USER_SLOTS / FWD_IDS: the
# stable numbers behind every user's tunnel ports.
$CONF_KEYS = @('ADMIN_USER', 'SSH_PORTS', 'RDP_ENABLED', 'RDP_PUBLIC', 'OPEN_WEB', 'AUTO_REBOOT',
  'TRUSTED_IPS', 'GITLAB_HOST', 'GITLAB_SSH_PORT', 'GITLAB_PORTS', 'GITLAB_DIRECT', 'FORWARDS',
  'FORWARDS_USER', 'USER_SLOTS', 'FWD_IDS', 'SETUP_DONE')
$CFG = @{}
$script:RESULTS = New-Object System.Collections.ArrayList
$script:IN_SETUP = $false
$script:REFRESH_FOR = ''
$script:KEYS_OUT = @()
$script:PW_GENERATED = 'n'
$script:NATIVE_RC = 0
$script:EXIT_CODE = 0
$script:LINE_BUF = ''
$script:FWD_LENIENT = $false
# the answers of the setup run that are not saved in config.json
$script:ADMIN_KEYS = @()
$script:ADMIN_PASSWORD = ''
$script:ADMIN_PW_GENERATED = 'n'
$script:DEV_USERS = @()
$script:DEV_KEYS = @{}
$script:NEW_HOSTNAME = ''
$script:TIMEZONE = ''
$script:FW_RESET = 'n'
$script:ADMINS_GROUP = 'Administrators'
$script:USERS_GROUP = 'Users'
$script:RDP_GROUP = 'Remote Desktop Users'
$UTF8 = New-Object System.Text.UTF8Encoding $false

# ----------------------------------------------------------------------------
# Output
# ----------------------------------------------------------------------------
function Log-File([string]$m) {
  try { if (Test-Path -LiteralPath $STATE_DIR) { [IO.File]::AppendAllText($LOG_FILE, ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) + "`r`n") } } catch { }
}
function Log-Raw([string]$m) {
  try { if (Test-Path -LiteralPath $STATE_DIR) { [IO.File]::AppendAllText($LOG_FILE, $m + "`r`n") } } catch { }
}
function Step([string]$m) { Write-Host ''; Write-Host "==> $m" -ForegroundColor Cyan; Log-File "==> $m" }
function Info([string]$m) { Write-Host "    $m"; Log-File "    $m" }
function Ok([string]$m) { Write-Host '[ok] ' -ForegroundColor Green -NoNewline; Write-Host $m; Log-File "ok  $m" }
function Warn([string]$m) { Write-Host '[!] ' -ForegroundColor Yellow -NoNewline; Write-Host $m; Log-File "WARN $m" }
function Die([string]$m) {
  Write-Host '[x] ' -ForegroundColor Red -NoNewline; Write-Host $m; Log-File "FAIL $m"
  $er = New-Object System.Management.Automation.ErrorRecord -ArgumentList @((New-Object System.Exception $m), 'VpsDie',
    [System.Management.Automation.ErrorCategory]::OperationStopped, $null)
  throw $er
}
function Is-Die($err) { return ([string]$err.FullyQualifiedErrorId) -like 'VpsDie*' }
function Show-Error($err) { # an unexpected error (Die already printed its own message)
  if (Is-Die $err) { return }
  $line = $err.InvocationInfo.ScriptLineNumber
  Write-Host '[x] ' -ForegroundColor Red -NoNewline; Write-Host ("Failed at line {0}: {1}" -f $line, $err.Exception.Message)
  Log-File ("FAIL line {0}: {1}" -f $line, $err.Exception.Message)
}
function Note([string]$m) { # goes into the final report
  Info $m
  try { if (Test-Path -LiteralPath $STATE_DIR) { [IO.File]::AppendAllText($RUN_NOTES, $m + "`r`n") } } catch { }
}

# ----------------------------------------------------------------------------
# Running programs
# ----------------------------------------------------------------------------
function Quote-Arg([string]$a) { # one argument, quoted the way Windows programs parse it
  if ($a -eq '') { return '""' }
  if ($a -notmatch '[\s"]') { return $a }
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('"')
  $bs = 0
  foreach ($ch in $a.ToCharArray()) {
    if ($ch -eq '\') { $bs++; continue }
    if ($ch -eq '"') { [void]$sb.Append('\' * ($bs * 2 + 1)); [void]$sb.Append('"'); $bs = 0; continue }
    if ($bs -gt 0) { [void]$sb.Append('\' * $bs); $bs = 0 }
    [void]$sb.Append($ch)
  }
  [void]$sb.Append('\' * ($bs * 2))
  [void]$sb.Append('"')
  return $sb.ToString()
}

# Run-Soft <description> <program> <arguments> - output goes to the log; while it runs a
# progress line is shown every 30 s; on failure the tail is shown and $false is returned.
function Run-Soft {
  param([string]$Desc, [string]$Exe, [string[]]$ArgList = @(), [int[]]$OkCodes = @(0), [int]$TimeoutMin = 0)
  Info $Desc
  $out = [IO.Path]::GetTempFileName()
  $err = [IO.Path]::GetTempFileName()
  $argStr = (@($ArgList) | ForEach-Object { Quote-Arg $_ }) -join ' '
  Log-Raw ''
  Log-Raw "> $Exe $argStr"
  $sp = @{ FilePath = $Exe; RedirectStandardOutput = $out; RedirectStandardError = $err; NoNewWindow = $true; PassThru = $true }
  if ($argStr) { $sp.ArgumentList = $argStr }
  try { $p = Start-Process @sp } catch {
    Warn ("{0} failed: {1}" -f $Desc, $_.Exception.Message)
    Remove-Item -LiteralPath $out, $err -Force -ErrorAction SilentlyContinue
    return $false
  }
  $null = $p.Handle   # keeps the exit code readable after the process ends
  $waited = 0
  while (-not $p.WaitForExit(2000)) {
    $waited += 2
    if ($waited % 30 -eq 0) {
      $last = ''
      try { $last = [string](Get-Content -LiteralPath $out -Tail 1 -ErrorAction Stop) } catch { }
      if ($last.Length -gt 100) { $last = $last.Substring(0, 100) }
      Write-Host ('      ... {0}m{1:00}s  {2}' -f [int][math]::Floor($waited / 60), ($waited % 60), $last)
    }
    if ($TimeoutMin -gt 0 -and $waited -ge $TimeoutMin * 60) {
      try { $p.Kill() } catch { }
      Warn "$Desc took longer than $TimeoutMin minutes - stopped."
      break
    }
  }
  $p.WaitForExit()
  $code = $p.ExitCode
  $text = [string](Get-Content -LiteralPath $out -Raw -ErrorAction SilentlyContinue) + [string](Get-Content -LiteralPath $err -Raw -ErrorAction SilentlyContinue)
  Log-Raw $text
  Remove-Item -LiteralPath $out, $err -Force -ErrorAction SilentlyContinue
  if ($OkCodes -contains $code) { return $true }
  Write-Host '[x] ' -ForegroundColor Red -NoNewline
  Write-Host ("{0} failed (exit {1}). Last lines (full log: {2}):" -f $Desc, $code, $LOG_FILE)
  @($text -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -Last 30 | ForEach-Object { Write-Host "    $_" }
  return $false
}

# Run - the same, but a failure stops the current step
function Run {
  param([string]$Desc, [string]$Exe, [string[]]$ArgList = @(), [int[]]$OkCodes = @(0), [int]$TimeoutMin = 0)
  if (-not (Run-Soft -Desc $Desc -Exe $Exe -ArgList $ArgList -OkCodes $OkCodes -TimeoutMin $TimeoutMin)) { Die "$Desc failed." }
}

# Native-Out <program> <arguments> - its output lines (stdout + stderr); exit code in NATIVE_RC
function Native-Out([string]$Exe, [string[]]$ArgList = @()) {
  $eap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { $o = @(& $Exe @ArgList 2>&1 | ForEach-Object { [string]$_ }) } finally { $ErrorActionPreference = $eap }
  $script:NATIVE_RC = $LASTEXITCODE
  return $o
}

function Sha256-Text([string]$t) {
  $h = (New-Object System.Security.Cryptography.SHA256Managed).ComputeHash($UTF8.GetBytes($t))
  return ([BitConverter]::ToString($h) -replace '-', '').ToLower()
}

# ----------------------------------------------------------------------------
# Small helpers
# ----------------------------------------------------------------------------
function Trim-Text([string]$s) { if ($null -eq $s) { return '' }; return $s.Trim() }
function Words([string]$s) { if ([string]::IsNullOrWhiteSpace($s)) { return @() }; return @($s.Trim() -split '\s+') }
function Uniq-Words { # Uniq-Words <list or array>... - words in order, each once, as one string
  $seen = @{}
  $out = New-Object System.Collections.ArrayList
  foreach ($a in $args) {
    foreach ($w in @(Words ([string]$a))) { if (-not $seen.ContainsKey($w)) { $seen[$w] = 1; [void]$out.Add($w) } }
  }
  return ($out -join ' ')
}
function New-Dir([string]$d) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }
function Write-Text([string]$path, [string]$text) { [IO.File]::WriteAllText($path, $text, $UTF8) }   # UTF-8 without BOM (sshd needs that)
function Read-Text([string]$path) { if (Test-Path -LiteralPath $path) { return [string](Get-Content -LiteralPath $path -Raw -Encoding UTF8) }; return '' }
function Lines([string[]]$l) { return (($l -join "`n") + "`n") }
function Host-Alias { return $env:COMPUTERNAME.ToLower() }
function Is-Elevated {
  $p = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Group-NameBySid([string]$sid) {
  $n = (New-Object System.Security.Principal.SecurityIdentifier $sid).Translate([System.Security.Principal.NTAccount]).Value
  return ($n -split '\\')[-1]
}
function Rid-Of([string]$sid) { return [int64](($sid -split '-')[-1]) }

function Ensure-RegKey([string]$p) { if (-not (Test-Path -LiteralPath $p)) { New-Item -Path $p -Force | Out-Null } }
function Set-Reg([string]$path, [string]$name, $value, [string]$type = 'DWord') {
  Ensure-RegKey $path
  New-ItemProperty -Path $path -Name $name -Value $value -PropertyType $type -Force | Out-Null
}

function Add-MachinePath([string]$dir) {
  $k = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
  $cur = [string](Get-Item -Path $k).GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
  if ((';' + $cur.ToLower() + ';').Contains(';' + $dir.ToLower() + ';')) { return }
  Set-ItemProperty -Path $k -Name Path -Value ($cur.TrimEnd(';') + ";$dir") -Type ExpandString
  $env:Path = "$env:Path;$dir"
}

function Gen-Password([int]$len = 20) { # letters and digits only (safe to type and paste), all three kinds
  $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
  $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
  do {
    $b = New-Object byte[] $len
    $rng.GetBytes($b)
    $p = -join ($b | ForEach-Object { $chars[$_ % $chars.Length] })
  } until ($p -cmatch '[A-Z]' -and $p -cmatch '[a-z]' -and $p -match '[0-9]')
  return $p
}

function Server-Ip {
  try {
    $r = @(Find-NetRoute -RemoteIPAddress 1.1.1.1 -ErrorAction Stop | Where-Object { $_.PSObject.Properties['IPAddress'] -and $_.IPAddress })
    if ($r.Count -gt 0) { return [string]$r[0].IPAddress }
  } catch { }
  $a = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' -and $_.InterfaceAlias -ne $LOOPBACK_NAME } |
    Select-Object -First 1
  if ($a) { return [string]$a.IPAddress }
  return '<server-ip>'
}

function Backup-File([string]$f) {
  New-Dir $BACKUP_DIR
  Copy-Item -LiteralPath $f -Destination ("{0}\{1}.{2}" -f $BACKUP_DIR, (Split-Path $f -Leaf), (Get-Date -Format 'yyyyMMdd-HHmmss')) -Force
}

# Set-PrivateAcl <path> [sid...] [-Dir] - only SYSTEM, Administrators and the given SIDs
function Set-PrivateAcl([string]$path, [string[]]$extraSids = @(), [switch]$Dir) {
  $perm = 'F'
  if ($Dir) { $perm = '(OI)(CI)F' }
  $a = @($path, '/inheritance:r', '/grant:r', "*${SID_SYSTEM}:$perm", '/grant:r', "*${SID_ADMINS}:$perm")
  foreach ($s in $extraSids) { if ($s) { $a += @('/grant:r', "*${s}:$perm") } }
  $o = Native-Out 'icacls.exe' $a
  if ($script:NATIVE_RC -ne 0) { Die ("icacls failed for {0}: {1}" -f $path, ($o -join ' ')) }
}

function Need-Tty {
  $redirected = $true
  try { $redirected = [Console]::IsInputRedirected } catch { }
  if ($redirected -or -not [Environment]::UserInteractive) { Die 'This command is interactive: run it from a console or an SSH terminal.' }
}

function Reboot-Pending {
  if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { return $true }
  if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { return $true }
  try {
    $a = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName').ComputerName
    $b = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName').ComputerName
    if ($a -ne $b) { return $true }
  } catch { }
  return $false
}

function Is-ServerCore {
  return ((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').InstallationType -eq 'Server Core')
}

# ----------------------------------------------------------------------------
# Native helpers (user profiles, the loopback adapter) - compiled by Windows' own C# compiler
# ----------------------------------------------------------------------------
$NATIVE_SRC = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace VpsNative
{
    public static class Win
    {
        [DllImport("userenv.dll", CharSet = CharSet.Unicode)]
        static extern int CreateProfile(string sid, string user, StringBuilder path, uint len);

        // 0 = created; 0x800700B7 = it exists already
        public static int CreateUserProfile(string sid, string user)
        {
            StringBuilder sb = new StringBuilder(260);
            return CreateProfile(sid, user, sb, 260);
        }

        [StructLayout(LayoutKind.Sequential)]
        struct SP_DEVINFO_DATA { public int cbSize; public Guid ClassGuid; public int DevInst; public IntPtr Reserved; }

        [DllImport("setupapi.dll", SetLastError = true)]
        static extern IntPtr SetupDiCreateDeviceInfoList(ref Guid classGuid, IntPtr hwnd);
        [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern bool SetupDiCreateDeviceInfo(IntPtr set, string name, ref Guid classGuid, string desc, IntPtr hwnd, int flags, ref SP_DEVINFO_DATA data);
        [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern bool SetupDiSetDeviceRegistryProperty(IntPtr set, ref SP_DEVINFO_DATA data, int property, byte[] buffer, int size);
        [DllImport("setupapi.dll", SetLastError = true)]
        static extern bool SetupDiCallClassInstaller(int fn, IntPtr set, ref SP_DEVINFO_DATA data);
        [DllImport("setupapi.dll", SetLastError = true)]
        static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
        [DllImport("newdev.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern bool UpdateDriverForPlugAndPlayDevices(IntPtr hwnd, string hardwareId, string infPath, int flags, out bool reboot);

        // Adds a "Microsoft KM-TEST Loopback Adapter" (what devcon install netloop.inf *MSLOOP does)
        public static int InstallLoopback(string inf)
        {
            Guid net = new Guid("4d36e972-e325-11ce-bfc1-08002be10318");
            IntPtr set = SetupDiCreateDeviceInfoList(ref net, IntPtr.Zero);
            if (set == new IntPtr(-1)) return Marshal.GetLastWin32Error();
            try
            {
                SP_DEVINFO_DATA d = new SP_DEVINFO_DATA();
                d.cbSize = Marshal.SizeOf(typeof(SP_DEVINFO_DATA));
                if (!SetupDiCreateDeviceInfo(set, "Net", ref net, null, IntPtr.Zero, 1, ref d)) return Marshal.GetLastWin32Error();
                byte[] hw = Encoding.Unicode.GetBytes("*MSLOOP\0\0");
                if (!SetupDiSetDeviceRegistryProperty(set, ref d, 1, hw, hw.Length)) return Marshal.GetLastWin32Error();
                if (!SetupDiCallClassInstaller(0x19, set, ref d)) return Marshal.GetLastWin32Error();
            }
            finally
            {
                SetupDiDestroyDeviceInfoList(set);
            }
            bool reboot;
            if (!UpdateDriverForPlugAndPlayDevices(IntPtr.Zero, "*MSLOOP", inf, 1, out reboot)) return Marshal.GetLastWin32Error();
            return 0;
        }
    }
}
'@
function Load-Native { if (-not ('VpsNative.Win' -as [type])) { Add-Type -TypeDefinition $NATIVE_SRC -Language CSharp } }

# ----------------------------------------------------------------------------
# Prompts
# ----------------------------------------------------------------------------
function Accept-Any([string]$a) { return $true }

# Prompt-Value <question> [default] [validator function name]
function Prompt-Value([string]$q, [string]$def = '', [string]$check = '') {
  while ($true) {
    Write-Host '? ' -ForegroundColor Cyan -NoNewline
    if ($def) { $ans = Read-Host "$q [$def]" } else { $ans = Read-Host $q }
    $ans = Trim-Text $ans
    if (-not $ans) { $ans = $def }
    if ($ans -eq '-') { $ans = '' }   # "-" clears a default
    if ($check) { if (& $check $ans) { return $ans } }
    elseif ($ans) { return $ans }
  }
}

function Prompt-YN([string]$q, [string]$def = 'n') {
  $hint = 'y/N'
  if ($def -eq 'y') { $hint = 'Y/n' }
  while ($true) {
    Write-Host '? ' -ForegroundColor Cyan -NoNewline
    $a = Trim-Text (Read-Host "$q [$hint]")
    if (-not $a) { $a = $def }
    switch ($a.ToLower()) { 'y' { return 'y' } 'yes' { return 'y' } 'n' { return 'n' } 'no' { return 'n' } }
  }
}

function SecureToPlain($s) {
  $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
  try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

# Prompt-Password <question> - empty input generates one; sets PW_GENERATED=y|n
function Prompt-Password([string]$q) {
  while ($true) {
    Write-Host '? ' -ForegroundColor Cyan -NoNewline
    $a = SecureToPlain (Read-Host "$q (min 12 chars, empty = generate one)" -AsSecureString)
    if (-not $a) { $script:PW_GENERATED = 'y'; return (Gen-Password 20) }
    if ($a.Length -lt 12) { Warn 'Too short.'; continue }
    Write-Host '? ' -ForegroundColor Cyan -NoNewline
    $b = SecureToPlain (Read-Host 'Repeat it' -AsSecureString)
    if ($a -cne $b) { Warn 'The two entries differ.'; continue }
    $script:PW_GENERATED = 'n'
    return $a
  }
}

# Read-LineTimeout <seconds> - a typed line, or $null when none was finished in time
function Read-LineTimeout([int]$sec) {
  $deadline = (Get-Date).AddSeconds($sec)
  try {
    while ((Get-Date) -lt $deadline) {
      while ([Console]::KeyAvailable) {
        $k = [Console]::ReadKey($true)
        if ($k.Key -eq 'Enter') { Write-Host ''; $l = $script:LINE_BUF; $script:LINE_BUF = ''; return $l }
        if ($k.Key -eq 'Backspace') {
          if ($script:LINE_BUF.Length -gt 0) { $script:LINE_BUF = $script:LINE_BUF.Substring(0, $script:LINE_BUF.Length - 1); Write-Host "`b `b" -NoNewline }
          continue
        }
        $script:LINE_BUF += $k.KeyChar
        Write-Host $k.KeyChar -NoNewline
      }
      Start-Sleep -Milliseconds 200
    }
  } catch { Start-Sleep -Seconds $sec }
  return $null
}

# ----------------------------------------------------------------------------
# Validators (print why on failure)
# ----------------------------------------------------------------------------
function Valid-Username([string]$u) {
  if ($u -cnotmatch '^[a-z_][a-z0-9_-]{0,19}$') { Warn "Use lowercase letters, digits, '-' or '_' (start with a letter, max 20)."; return $false }
  if ($RESERVED_NAMES -contains $u) { Warn "'$u' is a built-in or reserved account name - use a personal one."; return $false }
  $x = Get-LocalUser -Name $u -ErrorAction SilentlyContinue
  if ($x -and (Rid-Of $x.SID.Value) -lt 1000) { Warn "'$u' is a system account."; return $false }
  if (-not $x -and (Get-LocalGroup -Name $u -ErrorAction SilentlyContinue)) { Warn "'$u' is the name of a group."; return $false }
  return $true
}
function Valid-PortNumber([string]$p) {
  if ($p -match '^[0-9]{1,5}$' -and [int]$p -ge 1 -and [int]$p -le 65535) { return $true }
  Warn "'$p' is not a port (1-65535)."
  return $false
}
function Process-Names { $n = @{}; foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) { $n[[int]$p.Id] = $p.ProcessName.ToLower() }; return $n }
function Port-Listening([int]$port) { return @(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue).Count -gt 0 }
function Wait-Port([int]$port) { for ($i = 0; $i -lt 20; $i++) { if (Port-Listening $port) { return $true }; Start-Sleep -Milliseconds 500 }; return $false }
function Valid-Port([string]$p) { # a port sshd may use: free, or already used by sshd itself
  if (-not (Valid-PortNumber $p)) { return $false }
  $names = Process-Names
  foreach ($c in @(Get-NetTCPConnection -State Listen -LocalPort ([int]$p) -ErrorAction SilentlyContinue)) {
    $n = [string]$names[[int]$c.OwningProcess]
    if ($n -eq 'sshd' -or $c.LocalAddress -eq $GITLAB_IP) { continue }
    Warn "Port $p is already used by another program ($n)."
    return $false
  }
  return $true
}
function Valid-SshPorts([string]$list) {
  $seen = @{}
  if (-not (Words $list)) { Warn 'Enter at least one port.'; return $false }
  foreach ($p in @(Words $list)) {
    if (-not (Valid-Port $p)) { return $false }
    if ($seen.ContainsKey([int]$p)) { Warn "Port $p is listed twice."; return $false }
    $seen[[int]$p] = 1
  }
  return $true
}
function Valid-PortListOrEmpty([string]$list) { foreach ($p in @(Words $list)) { if (-not (Valid-PortNumber $p)) { return $false } }; return $true }
function Valid-Hostname([string]$h) { # a Windows computer name: at most 15 characters
  if ($h -match '^[A-Za-z0-9]([A-Za-z0-9-]{0,13}[A-Za-z0-9])?$' -and $h -notmatch '^[0-9]+$') { return $true }
  Warn "Use letters, digits and '-' (at most 15, not only digits; e.g. claude-dev)."
  return $false
}
function Valid-GitlabHosts([string]$list) {
  foreach ($h in @(Words $list)) {
    if ($h -notmatch '^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$') { Warn "'$h' is not a hostname (e.g. gitlab.local or gitlab.company.com)."; return $false }
  }
  return $true
}
function Is-PrivateIpv4([string]$ip) { return $ip -match '^(10\.|127\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.)' }
function Public-Ipv4Of([string]$name) { # public DNS answer for a name, ignoring the hosts file
  try {
    $r = Resolve-DnsName -Name $name -Type A -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction Stop | Where-Object { $_.Type -eq 'A' } | Select-Object -First 1
    if ($r) { return [string]$r.IPAddress }
  } catch { }
  return ''
}
function Valid-Timezone([string]$t) {
  if ($t -and (Get-TimeZone -ListAvailable | Where-Object { $_.Id -eq $t })) { return $true }
  Warn "Unknown timezone - use a Windows timezone ID (examples: UTC, W. Europe Standard Time, Iran Standard Time; list: Get-TimeZone -ListAvailable)."
  return $false
}
function Valid-IpList([string]$list) {
  foreach ($t in @(Words $list)) { if ($t -notmatch '^[0-9A-Fa-f:.]+(/[0-9]{1,3})?$') { Warn "'$t' is not an IP or CIDR."; return $false } }
  return $true
}
function Ip-ToNumber([string]$ip) { $b = ([System.Net.IPAddress]::Parse($ip)).GetAddressBytes(); return ([int64]$b[0] * 16777216) + ([int64]$b[1] * 65536) + ([int64]$b[2] * 256) + [int64]$b[3] }
function In-Subnet([string]$ip, [string]$net, [int]$len) {
  if ($len -le 0) { return $true }
  $size = [math]::Pow(2, 32 - $len)
  return [math]::Floor((Ip-ToNumber $ip) / $size) -eq [math]::Floor((Ip-ToNumber $net) / $size)
}
function Ip-Trusted([string]$ip, [string[]]$list) {
  foreach ($t in $list) {
    if ($t -eq $ip) { return $true }
    if ($t -match '^([0-9.]+)/([0-9]{1,2})$' -and $ip -match '^[0-9.]+$') { if (In-Subnet $ip $Matches[1] ([int]$Matches[2])) { return $true } }
  }
  return $false
}

# ----------------------------------------------------------------------------
# SSH public keys
# ----------------------------------------------------------------------------
function Read-SshBlob([byte[]]$b) { # the length-prefixed fields of a public key blob
  $out = New-Object System.Collections.ArrayList
  $i = 0
  while ($i + 4 -le $b.Length) {
    $l = ([int64]$b[$i] * 16777216) + ([int64]$b[$i + 1] * 65536) + ([int64]$b[$i + 2] * 256) + [int64]$b[$i + 3]
    $i += 4
    if ($i + $l -gt $b.Length) { return $null }
    $seg = New-Object byte[] $l
    [Array]::Copy($b, $i, $seg, 0, $l)
    [void]$out.Add($seg)
    $i += $l
  }
  if ($i -ne $b.Length -or $out.Count -lt 2) { return $null }
  return , $out.ToArray()
}

# Normalize-PubKey <authorized_keys line> - "type base64 [comment]", or $null.
# Strips authorized_keys options in front of the key; checks the key data itself.
function Normalize-PubKey([string]$line) {
  $line = Trim-Text ($line -replace "`r", '')
  if (-not $line -or $line.StartsWith('#') -or $line -match 'PRIVATE KEY') { return $null }
  $re = '((sk-)?(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521))(@openssh\.com)?\s+([A-Za-z0-9+/]+={0,3})(\s+\S.*)?)$'
  if ($line -notmatch $re) { return $null }
  $key = $Matches[1]
  $b64 = $Matches[6]
  $type = ($key -split '\s+')[0]
  try { $blob = [Convert]::FromBase64String($b64) } catch { return $null }
  $parts = Read-SshBlob $blob
  if (-not $parts -or [Text.Encoding]::ASCII.GetString($parts[0]) -ne $type) { return $null }
  if ($type -eq 'ssh-rsa') {
    $n = $parts[2]
    $z = 0
    while ($z -lt $n.Length -and $n[$z] -eq 0) { $z++ }
    if (($n.Length - $z) * 8 -lt 2048) { Warn 'RSA keys must be at least 2048 bits.'; return $null }
  }
  return (($key -replace '\s+', ' ').Trim())
}

function Keys-FromFile([string]$f, [string]$onlyTag = '') {
  $out = @()
  if (-not (Test-Path -LiteralPath $f)) { return $out }
  foreach ($l in @(Get-Content -LiteralPath $f -Encoding UTF8)) {
    $line = ([string]$l).TrimEnd()
    if ($onlyTag) {
      if (-not $line.EndsWith($onlyTag)) { continue }
      $line = $line.Substring(0, $line.Length - $onlyTag.Length)
    }
    $k = Normalize-PubKey $line
    if ($k) { $out += $k }
  }
  return $out
}

# ----------------------------------------------------------------------------
# State
# ----------------------------------------------------------------------------
function Load-Config {
  $script:CFG = @{}
  foreach ($k in $CONF_KEYS) { $script:CFG[$k] = '' }
  if (Test-Path -LiteralPath $CONF_FILE) {
    $o = (Read-Text $CONF_FILE) | ConvertFrom-Json
    foreach ($k in $CONF_KEYS) { if ($o.PSObject.Properties[$k]) { $script:CFG[$k] = [string]$o.$k } }
  }
}

function Save-Config {
  $o = [ordered]@{ '_' = "vps-setup $SCRIPT_VERSION state - written by the script, edit with care" }
  foreach ($k in $CONF_KEYS) { $o[$k] = [string]$script:CFG[$k] }
  Write-Text "$CONF_FILE.new" ((New-Object PSObject -Property $o) | ConvertTo-Json)
  Move-Item -LiteralPath "$CONF_FILE.new" -Destination $CONF_FILE -Force
}

function Init-State {
  if (-not (Test-Path -LiteralPath $STATE_DIR)) {
    New-Dir $STATE_DIR
    Set-PrivateAcl $STATE_DIR -Dir
  }
  if (-not (Test-Path -LiteralPath $LOG_FILE)) { Write-Text $LOG_FILE '' }
  Load-Config
  try {
    $script:ADMINS_GROUP = Group-NameBySid $SID_ADMINS
    $script:USERS_GROUP = Group-NameBySid $SID_USERS
    $script:RDP_GROUP = Group-NameBySid $SID_RDP
  } catch { }
}

function Begin-Run { Write-Text $RUN_NOTES ''; Write-Text $RUN_CREDS '' }
function End-Run {
  # After anything that changed users or services: the report and the user sheets follow.
  if ($script:REFRESH_FOR -and $CFG.SETUP_DONE -eq 'y') {
    try { Refresh-Files $script:REFRESH_FOR; if ($script:EXIT_CODE -eq 0) { Info "Updated: $REPORT_FILE and $USERS_DIR\<user>.txt" } }
    catch { Warn ("Could not update {0} / {1}: {2}" -f $REPORT_FILE, $USERS_DIR, $_.Exception.Message) }
  }
  Remove-Item -LiteralPath $RUN_CREDS -Force -ErrorAction SilentlyContinue
}

function Note-Cred([string]$u, [string]$what, [string]$value) {
  New-Dir $CRED_DIR
  [IO.File]::AppendAllText("$CRED_DIR\$u.txt", ('{0}  {1,-16} {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $what, $value) + "`r`n")
  [IO.File]::AppendAllText($RUN_CREDS, "$u`t$what`t$value`r`n")
}

function Print-Credentials {
  if (-not (Test-Path -LiteralPath $RUN_CREDS) -or (Get-Item -LiteralPath $RUN_CREDS).Length -eq 0) { return }
  Step "Credentials created now (also in $CRED_DIR - hand them over privately, then delete that folder)"
  foreach ($l in @(Get-Content -LiteralPath $RUN_CREDS)) {
    $f = $l -split "`t"
    if ($f.Count -ge 3) { Write-Host ('    {0,-16} {1,-16} {2}' -f $f[0], $f[1], $f[2]) }
  }
}

function Check-OS {
  $os = Get-CimInstance Win32_OperatingSystem
  if ($os.ProductType -eq 1) { Die "This script is for Windows Server (found '$($os.Caption)')." }
  if ($os.ProductType -eq 2) { Die 'This server is a domain controller - it has no local accounts. Use a member or standalone server.' }
  $build = [int]$os.BuildNumber
  if ($build -lt 17763) { Die "Windows Server 2019 or later is required (found $($os.Caption), build $build)." }
  if (@(17763, 20348, 26100) -notcontains $build) { Warn "$($os.Caption) (build $build) has not been tested with this script - newer releases are expected to work." }
  if (Is-ServerCore) { Warn 'Server Core has no desktop: RDP desktops and desktop apps will not work here. Everything else does.' }
  if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64') { Warn "$env:PROCESSOR_ARCHITECTURE has not been tested with this script (x64 has)." }
}

function Install-Self {
  $src = $PSCommandPath
  if (-not $src -or -not (Test-Path -LiteralPath $src)) { Die 'Save the script to a file and run it from there (powershell -ExecutionPolicy Bypass -File .\vps-setup.ps1).' }
  New-Dir $INSTALL_DIR
  if ((Resolve-Path -LiteralPath $src).Path -ne $INSTALL_PATH) {
    Copy-Item -LiteralPath $src -Destination $INSTALL_PATH -Force
    Info "Installed management command: vps-setup ($INSTALL_DIR)"
  }
  Unblock-File -LiteralPath $INSTALL_PATH -ErrorAction SilentlyContinue
  # Program Files: everyone may read and run it - without elevation it only explains how to
  # run it; every command that changes something needs an administrator.
  $shim = "@`"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`" -NoProfile -ExecutionPolicy Bypass -File `"%~dp0vps-setup.ps1`" %*`r`n@exit /b %ERRORLEVEL%`r`n"
  [IO.File]::WriteAllText("$INSTALL_DIR\vps-setup.cmd", $shim, [Text.Encoding]::ASCII)
  Add-MachinePath $INSTALL_DIR
}

# ----------------------------------------------------------------------------
# Users (local accounts and groups)
# ----------------------------------------------------------------------------
function Group-Members([string]$group) {
  try {
    $g = [ADSI]"WinNT://$env:COMPUTERNAME/$group,group"
    return @($g.psbase.Invoke('Members') | ForEach-Object { [string]$_.GetType().InvokeMember('Name', 'GetProperty', $null, $_, $null) })
  } catch { return @() }
}
function In-Group([string]$u, [string]$group) { return @(Group-Members $group | Where-Object { $_ -ieq $u }).Count -gt 0 }
function Add-ToGroup([string]$u, [string]$group) { if (-not (In-Group $u $group)) { Add-LocalGroupMember -Group $group -Member $u } }
function Remove-FromGroup([string]$u, [string]$group) { if (In-Group $u $group) { Remove-LocalGroupMember -Group $group -Member $u -ErrorAction SilentlyContinue } }
function Ensure-Group([string]$g, [string]$desc) { if (-not (Get-LocalGroup -Name $g -ErrorAction SilentlyContinue)) { New-LocalGroup -Name $g -Description $desc | Out-Null } }
function User-Exists([string]$u) { return [bool](Get-LocalUser -Name $u -ErrorAction SilentlyContinue) }
function Sid-Of([string]$u) { return (Get-LocalUser -Name $u).SID.Value }
function Is-HumanUser([string]$u) { $x = Get-LocalUser -Name $u -ErrorAction SilentlyContinue; return ($x -and (Rid-Of $x.SID.Value) -ge 1000) }
function Human-Users { return @(Get-LocalUser | Where-Object { (Rid-Of $_.SID.Value) -ge 1000 } | ForEach-Object { $_.Name.ToLower() }) }
function Is-Admin([string]$u) { return In-Group $u $script:ADMINS_GROUP }
function Server-Users { # admin + developers (members of the SSH group)
  $m = @(Group-Members $SSH_GROUP | ForEach-Object { $_.ToLower() })
  return @(Human-Users | Where-Object { $m -contains $_ })
}
function User-HasPassword([string]$u) { $x = Get-LocalUser -Name $u -ErrorAction SilentlyContinue; return [bool]($x -and $null -ne $x.PasswordLastSet) }
function Home-Of([string]$u) {
  $x = Get-LocalUser -Name $u -ErrorAction SilentlyContinue
  if (-not $x) { return $null }
  $p = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$($x.SID.Value)" -Name ProfileImagePath -ErrorAction SilentlyContinue).ProfileImagePath
  if ($p) { return [Environment]::ExpandEnvironmentVariables($p) }
  return $null
}

# A local account has no profile folder until its first logon - create it now, so its SSH
# keys can be put in place before that.
function Ensure-Profile([string]$u) {
  $h = Home-Of $u
  if (-not $h -or -not (Test-Path -LiteralPath $h)) {
    Load-Native
    $r = [VpsNative.Win]::CreateUserProfile((Sid-Of $u), $u)
    if ($r -ne 0 -and $r -ne -2147024713) { Die ('Could not create the profile of {0} (0x{1:X8}).' -f $u, $r) }
    $h = Home-Of $u
  }
  if (-not $h -or -not (Test-Path -LiteralPath $h)) { Die "The profile folder of $u is missing." }
  return $h
}

function Ensure-SshDir([string]$u) {
  $d = (Home-Of $u) + '\.ssh'
  New-Dir $d
  Set-PrivateAcl $d @((Sid-Of $u)) -Dir
  return $d
}

function Slot-Of([string]$u) {
  foreach ($e in @(Words $CFG.USER_SLOTS)) { $kv = $e -split '=', 2; if ($kv[0] -eq $u) { return [int]$kv[1] } }
  return 0
}
function Assign-Slot([string]$u) {
  if ((Slot-Of $u) -gt 0) { return }
  $used = @{}
  foreach ($e in @(Words $CFG.USER_SLOTS)) { $used[[int](($e -split '=', 2)[1])] = 1 }
  for ($i = 1; $i -le $MAX_SLOT; $i++) {
    if (-not $used.ContainsKey($i)) { $CFG.USER_SLOTS = Uniq-Words $CFG.USER_SLOTS "$u=$i"; Save-Config; return }
  }
  Die 'No free tunnel slot left (too many users).'
}
function Free-Slot([string]$u) { $CFG.USER_SLOTS = (@(Words $CFG.USER_SLOTS) | Where-Object { ($_ -split '=', 2)[0] -ne $u }) -join ' ' }
function Tunnel-Port([string]$u, [int]$n) { $s = Slot-Of $u; if ($s -le 0) { return 0 }; return $TUNNEL_BASE + $s * $TUNNEL_SLOT_SIZE + $n }

function Keys-Of([string]$u) {
  if (Is-Admin $u) { return @(Keys-FromFile $ADMIN_KEYS_FILE " vps-setup:$u") }
  $h = Home-Of $u
  if (-not $h) { return @() }
  return @(Keys-FromFile "$h\.ssh\authorized_keys")
}

# Administrators' keys live in ProgramData\ssh\administrators_authorized_keys (Windows'
# OpenSSH default) - each line is tagged with its user, so they can be told apart.
function Add-AuthorizedKeys([string]$u, [string[]]$keys) {
  if (Is-Admin $u) {
    New-Dir $SSHD_DATA
    $f = $ADMIN_KEYS_FILE
    $tag = " vps-setup:$u"
  } else {
    $f = (Ensure-SshDir $u) + '\authorized_keys'
    $tag = ''
  }
  $lines = New-Object System.Collections.ArrayList
  foreach ($l in @((Read-Text $f) -split "`r?`n")) { if ($l.Trim()) { [void]$lines.Add($l.TrimEnd()) } }
  foreach ($k in $keys) {
    if (-not $k) { continue }
    $blob = ($k -split ' ')[1]
    $mine = @($lines | Where-Object { (($_ -split '\s+') -contains $blob) -and (-not $tag -or $_.EndsWith($tag)) })
    if ($mine.Count -eq 0) { [void]$lines.Add("$k$tag") }
  }
  Write-Text $f (Lines $lines)
  if (Is-Admin $u) { Set-PrivateAcl $f } else { Set-PrivateAcl $f @((Sid-Of $u)) }
}

function Remove-AdminKeys([string]$u) { # the tagged lines of one user
  if (-not (Test-Path -LiteralPath $ADMIN_KEYS_FILE)) { return }
  $keep = @((Read-Text $ADMIN_KEYS_FILE) -split "`r?`n" | Where-Object { $_.Trim() -and -not $_.TrimEnd().EndsWith(" vps-setup:$u") })
  Write-Text $ADMIN_KEYS_FILE (Lines $keep)
  Set-PrivateAcl $ADMIN_KEYS_FILE
}

function Ssh-Tool([string]$name) {
  $d = ''
  $s = Sshd-Exe
  if ($s) { $d = Split-Path $s }
  foreach ($c in @("$d\$name.exe", "$env:SystemRoot\System32\OpenSSH\$name.exe")) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
  Die "$name.exe (OpenSSH) not found."
}

function Generate-KeyFor([string]$u) { # the private key goes to CRED_DIR only - never into the user's profile
  $kg = Ssh-Tool 'ssh-keygen'
  $tmp = Join-Path $env:TEMP ('vps-key-' + [guid]::NewGuid().ToString('N'))
  New-Dir $tmp
  try {
    Run "Generating an SSH key for $u" $kg @('-q', '-t', 'ed25519', '-N', '', '-C', "$u@$(Host-Alias)", '-f', "$tmp\key")
    Add-AuthorizedKeys $u @((Read-Text "$tmp\key.pub").Trim())
    New-Dir $CRED_DIR
    Copy-Item -LiteralPath "$tmp\key" -Destination "$CRED_DIR\$u.id_ed25519" -Force
  } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
  Note-Cred $u 'ssh private key' "$CRED_DIR\$u.id_ed25519"
}

function Apply-Keys([string]$u, [string[]]$keys) { # key lines | 'generate' | none (keep existing)
  $keys = @($keys | Where-Object { $_ })
  if ($keys.Count -eq 0) { return }
  if ($keys[0] -eq 'generate') { Generate-KeyFor $u } else { Add-AuthorizedKeys $u $keys }
}

function Set-UserPassword([string]$u, [string]$pw, [string]$generated) {
  Set-LocalUser -Name $u -Password (ConvertTo-SecureString $pw -AsPlainText -Force)
  if ($generated -eq 'y') { Note-Cred $u 'password' $pw }
}

# Resolve-Keys <spec> - a pasted public key, or copy:<user> (that user's keys)
function Resolve-Keys([string]$spec) {
  if ($spec -like 'copy:*') {
    $from = $spec.Substring(5)
    if (-not (User-Exists $from)) { Warn "No user '$from'."; return @() }
    return @(Keys-Of $from)
  }
  $k = Normalize-PubKey $spec
  if ($k) { return @($k) }
  return @()
}

# Collect-Keys <user> [-RequireNew] - sets KEYS_OUT to key lines, 'generate', or nothing (keep existing)
function Collect-Keys([string]$u, [switch]$RequireNew) {
  $has = $false
  if (User-Exists $u) { $has = @(Keys-Of $u).Count -gt 0 }
  $hint = "paste a public key, 'generate', or 'copy:<user>'"
  if ($has -and -not $RequireNew) { $hint += ', empty = keep existing keys' }
  while ($true) {
    $spec = Prompt-Value "SSH key for $u ($hint)" '' 'Accept-Any'
    if (-not $spec) {
      if ($has -and -not $RequireNew) { $script:KEYS_OUT = @(); return }
      Warn 'A key is required (password login over SSH is disabled).'
      continue
    }
    if ($spec -eq 'generate') { $script:KEYS_OUT = @('generate'); return }
    $k = @(Resolve-Keys $spec)
    if ($k.Count -gt 0) { $script:KEYS_OUT = $k; return }
    Warn "That is not a valid SSH public key (expected 'ssh-ed25519 AAAA... comment')."
  }
}

# Ensure-User <user> <admin|dev> [password] [generated y|n]. Windows accounts always get a
# password (used for RDP and the lock screen - never for SSH); one is generated when none is given.
function Ensure-User([string]$u, [string]$role, [string]$password = '', [string]$generated = 'n') {
  if (User-Exists $u) {
    Info "User $u exists - updating it."
    if ($password) { Set-UserPassword $u $password $generated }
    Set-LocalUser -Name $u -PasswordNeverExpires $true
  } else {
    if (-not $password) { $password = Gen-Password 20; $generated = 'y' }
    New-LocalUser -Name $u -Password (ConvertTo-SecureString $password -AsPlainText -Force) -PasswordNeverExpires -AccountNeverExpires -Description 'vps-setup user' | Out-Null
    if ($generated -eq 'y') { Note-Cred $u 'password' $password }
    Ok "Created user $u"
  }
  Add-ToGroup $u $script:USERS_GROUP
  $h = Ensure-Profile $u
  Add-ToGroup $u $SSH_GROUP
  Assign-Slot $u
  if ($role -eq 'admin') {
    $old = @(Keys-FromFile "$h\.ssh\authorized_keys")
    Add-ToGroup $u $script:ADMINS_GROUP
    Remove-FromGroup $u $DEV_GROUP
    if ($old.Count -gt 0) { Add-AuthorizedKeys $u $old }   # admins' keys live in the shared admin file
  } else {
    Add-ToGroup $u $DEV_GROUP
    if (Is-Admin $u) { Remove-FromGroup $u $script:ADMINS_GROUP; Warn "Removed $u from $($script:ADMINS_GROUP) (developers get no admin rights)." }
    foreach ($g in @('Backup Operators', 'Hyper-V Administrators', 'Server Operators')) {
      if (In-Group $u $g) { Warn "$u is in '$g', which is close to admin rights - remove it there." }
    }
    if ($CFG.RDP_ENABLED -eq 'y') { Add-ToGroup $u $script:RDP_GROUP }
  }
  Setup-UserEnv $u
}

# The profile folder is the user's own: SYSTEM, Administrators and the user (Windows' default).
# Tools a user installs go into it (e.g. Claude Code into .local\bin) - no admin rights needed.
function Setup-UserEnv([string]$u) {
  $h = Home-Of $u
  foreach ($d in @("$h\projects", "$h\.local", "$h\.local\bin")) { New-Dir $d }
  [void](Ensure-SshDir $u)
}

function Claude-Installed([string]$h) { return (Test-Path -LiteralPath "$h\.local\bin\claude.exe") -or (Test-Path -LiteralPath "$h\AppData\Roaming\npm\claude.cmd") }

# ----------------------------------------------------------------------------
# OpenSSH server - the Windows capability (preinstalled on Server 2025)
# ----------------------------------------------------------------------------
function Sshd-Exe {
  $svc = Get-CimInstance Win32_Service -Filter "Name='sshd'" -ErrorAction SilentlyContinue
  if ($svc -and $svc.PathName) {
    $p = $svc.PathName.Trim()
    if ($p.StartsWith('"')) { $p = $p.Substring(1, $p.IndexOf('"', 1) - 1) } else { $p = ($p -split ' ')[0] }
    if (Test-Path -LiteralPath $p) { return $p }
  }
  if (Test-Path -LiteralPath "$env:SystemRoot\System32\OpenSSH\sshd.exe") { return "$env:SystemRoot\System32\OpenSSH\sshd.exe" }
  return $null
}
function Sshd-Version {
  $s = Sshd-Exe
  if (-not $s) { return [version]'0.0' }
  $ssh = Join-Path (Split-Path $s) 'ssh.exe'
  if (-not (Test-Path -LiteralPath $ssh)) { return [version]'0.0' }
  $o = (Native-Out $ssh @('-V')) -join ' '
  if ($o -match 'OpenSSH_for_Windows_(\d+)\.(\d+)') { return [version]("{0}.{1}" -f $Matches[1], $Matches[2]) }
  return [version]'0.0'
}

function Install-OpenSsh {
  $was = $false
  $svc = Get-Service sshd -ErrorAction SilentlyContinue
  if ($svc -and $svc.Status -eq 'Running') { $was = $true }
  if (-not (Sshd-Exe)) {
    $cap = Get-WindowsCapability -Online -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'OpenSSH.Server*' } | Select-Object -First 1
    if (-not $cap) { Die 'This Windows has no OpenSSH.Server capability.' }
    Info 'Adding the OpenSSH server capability (from Windows Update - can take several minutes)...'
    try { Add-WindowsCapability -Online -Name $cap.Name -ErrorAction Stop | Out-Null }
    catch {
      Die ("Windows could not add OpenSSH ({0}). It comes from Windows Update (Features on Demand): " +
        "allow this server to reach Windows Update, or add it from the Features on Demand media: " +
        "Add-WindowsCapability -Online -Name {1} -Source <FoD folder> -LimitAccess" -f $_.Exception.Message, $cap.Name)
    }
  }
  if (-not (Sshd-Exe)) { Die 'The OpenSSH server could not be added.' }
  # Its default configuration accepts passwords: nothing may reach it before the hardening step.
  foreach ($n in @('OpenSSH-Server-In-TCP', 'sshd')) { Disable-NetFirewallRule -Name $n -ErrorAction SilentlyContinue }
  if (-not (Test-Path -LiteralPath $SSHD_CONFIG) -or -not (Test-Path -LiteralPath "$SSHD_DATA\ssh_host_ed25519_key")) {
    # its first start writes the default configuration and the host keys (with the right ACLs)
    Start-Service sshd
    for ($i = 0; $i -lt 20 -and -not (Test-Path -LiteralPath "$SSHD_DATA\ssh_host_ed25519_key"); $i++) { Start-Sleep -Milliseconds 500 }
    if (-not $was) { Stop-Service sshd -Force -ErrorAction SilentlyContinue }
  }
  if (-not $was) { Set-Service sshd -StartupType Manual }   # enabled by the SSH hardening step
  Set-Reg 'HKLM:\SOFTWARE\OpenSSH' 'DefaultShell' $WINPS 'String'
  if (Get-Service ssh-agent -ErrorAction SilentlyContinue) { Set-Service ssh-agent -StartupType Manual -ErrorAction SilentlyContinue }
  Note "OpenSSH server $(Sshd-Version) ($(Sshd-Exe)); login shell: Windows PowerShell"
}

function Apply-HostnameTimezone {
  if ($env:COMPUTERNAME -ine $script:NEW_HOSTNAME) {
    Rename-Computer -NewName $script:NEW_HOSTNAME -Force -WarningAction SilentlyContinue
    Note "Hostname: $($script:NEW_HOSTNAME) after the next reboot (Windows renames on restart)."
  }
  if ((Get-TimeZone).Id -ne $script:TIMEZONE) { Set-TimeZone -Id $script:TIMEZONE }
  Set-Service w32time -StartupType Automatic -ErrorAction SilentlyContinue
  Start-Service w32time -ErrorAction SilentlyContinue
  [void](Native-Out 'w32tm.exe' @('/resync', '/nowait'))
  Note "Hostname $($script:NEW_HOSTNAME), timezone $($script:TIMEZONE)"
}

# ----------------------------------------------------------------------------
# System configuration
# ----------------------------------------------------------------------------
function Set-ManagedBlock([string]$file, [string]$name, [string[]]$block) { # one marked block inside a file
  $begin = "# >>> vps-setup $name >>>"
  $end = "# <<< vps-setup $name <<<"
  $out = New-Object System.Collections.ArrayList
  $skip = $false
  foreach ($l in @((Read-Text $file) -split "`r?`n")) {
    if ($l -eq $begin) { $skip = $true; continue }
    if ($l -eq $end) { $skip = $false; continue }
    if (-not $skip) { [void]$out.Add($l) }
  }
  while ($out.Count -gt 0 -and -not ([string]$out[$out.Count - 1]).Trim()) { $out.RemoveAt($out.Count - 1) }
  if ($block.Count -gt 0) {
    if ($out.Count -gt 0) { [void]$out.Add('') }
    [void]$out.Add($begin)
    foreach ($b in $block) { [void]$out.Add($b) }
    [void]$out.Add($end)
  }
  New-Dir (Split-Path $file)
  Write-Text $file (Lines $out)
}

$PROFILE_BLOCK = @'
# Managed by vps-setup: where per-user installs put their programs (no admin rights needed)
foreach ($vpsDir in @("$env:USERPROFILE\.local\bin", "$env:APPDATA\npm")) {
  if ((Test-Path $vpsDir) -and ((';' + $env:Path + ';') -notlike "*;$vpsDir;*")) { $env:Path = "$vpsDir;$env:Path" }
}
Remove-Variable vpsDir -ErrorAction SilentlyContinue
# VS Code's terminal and Windows Terminal show 24-bit colour; SSH does not pass that on
if (-not $env:COLORTERM -and $env:TERM_PROGRAM -eq 'vscode') { $env:COLORTERM = 'truecolor' }
if ($env:SSH_CONNECTION -and -not $global:VpsMotdShown -and [Environment]::UserInteractive -and
    -not ([Environment]::GetCommandLineArgs() | Where-Object { $_ -match '^-(c|command|encodedcommand|f|file)$' })) {
  $global:VpsMotdShown = $true
  Write-Host ''
  Write-Host '  Claude Code dev server (managed by vps-setup)'
  Write-Host '    Claude Code: irm https://claude.ai/install.ps1 | iex   (into your profile; needs Git for'
  Write-Host '                 Windows - its installer works without admin rights). Then: claude'
  Write-Host '    Your own tools install into your profile without admin rights; system-wide: ask the admin.'
  Write-Host '    Long tasks: an SSH session ends when you disconnect - use your RDP desktop for them'
  Write-Host '    Internal GitLab / office services: work here like on your PC while you are connected'
  Write-Host ''
}
'@

function Apply-ShellDefaults {
  Set-Reg 'HKLM:\SOFTWARE\OpenSSH' 'DefaultShell' $WINPS 'String'
  $block = @($PROFILE_BLOCK -split "`r?`n")
  Set-ManagedBlock "$env:SystemRoot\System32\WindowsPowerShell\v1.0\profile.ps1" 'shell' $block
  if (Test-Path -LiteralPath "$env:ProgramFiles\PowerShell\7") { Set-ManagedBlock "$env:ProgramFiles\PowerShell\7\profile.ps1" 'shell' $block }
  # A system-wide Git (if the admin installed one) uses Windows' OpenSSH and its config
  # (ProgramData\ssh - where the GitLab mapping is). Nothing is installed here.
  $git = "$env:ProgramFiles\Git\cmd\git.exe"
  if (Test-Path -LiteralPath $git) {
    [void](Native-Out $git @('config', '--system', 'core.sshCommand', ("$env:SystemRoot\System32\OpenSSH\ssh.exe" -replace '\\', '/')))
    [void](Native-Out $git @('config', '--system', 'core.longpaths', 'true'))
    if (Test-Path -LiteralPath "$env:ProgramFiles\Git\bin\bash.exe") { [Environment]::SetEnvironmentVariable('CLAUDE_CODE_GIT_BASH_PATH', "$env:ProgramFiles\Git\bin\bash.exe", 'Machine') }
  }
  Note 'Shell: Windows PowerShell over SSH; per-user program folders on PATH in the all-users profile.'
}

function Apply-SystemTuning {
  Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'LongPathsEnabled' 1   # deep node_modules trees
  try { Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force -Confirm:$false -ErrorAction Stop } catch { }
  Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' 'EnableMulticast' 0   # no LLMNR
  Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' 'UserAuthentication' 1   # RDP: NLA
  Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Server\ServerManager' 'DoNotOpenAtLogon' 1
  $cs = Get-CimInstance Win32_ComputerSystem
  if (-not $cs.AutomaticManagedPagefile) { Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $true }; Note 'Page file: managed by Windows again.' }
  $wu = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
  Set-Reg $wu 'NoAutoUpdate' 0
  Set-Reg $wu 'AUOptions' 4            # download and install automatically
  Set-Reg $wu 'ScheduledInstallDay' 0  # every day
  Set-Reg $wu 'ScheduledInstallTime' 4 # at 04:00
  if ($CFG.AUTO_REBOOT -eq 'y') {
    Set-Reg $wu 'NoAutoRebootWithLoggedOnUsers' 0
    Set-Reg $wu 'AlwaysAutoRebootAtScheduledTime' 1
  } else {
    Set-Reg $wu 'NoAutoRebootWithLoggedOnUsers' 1
    Remove-ItemProperty -Path $wu -Name 'AlwaysAutoRebootAtScheduledTime' -ErrorAction SilentlyContinue
  }
  [void](Native-Out 'wevtutil.exe' @('sl', 'OpenSSH/Operational', '/ms:67108864'))
  Ok 'SMBv1 and LLMNR off, RDP with NLA, long paths, Windows Update installs every day at 04:00'
}

# ----------------------------------------------------------------------------
# Fair sharing between users - Windows' Dynamic Fair Share Scheduling: CPU, disk and network
# are shared equally between the RDP sessions that compete for them; an idle server lets one
# user use 100%. Windows has no per-user memory protection.
# ----------------------------------------------------------------------------
function Apply-FairShare {
  Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Quota System' 'EnableCpuQuota' 1
  foreach ($k in @('Disk', 'NetFS')) {
    $p = "HKLM:\SYSTEM\CurrentControlSet\Services\TSFairShare\$k"
    if (Test-Path -LiteralPath $p) { Set-Reg $p 'EnableFairShare' 1 }
  }
  Note 'Fair sharing: no fixed limits - any user may use all free CPU and RAM. Windows shares CPU'
  Note '  (and disk/network, with the RDS role) equally between the RDP sessions that compete for it.'
  Note '  SSH sessions all run in one Windows session, so between them it is first come, first served:'
  Note '  see who uses what with: vps-setup usage'
}

# ----------------------------------------------------------------------------
# Windows Defender Firewall
# ----------------------------------------------------------------------------
function Ensure-FwRule([string]$name, [string]$display, [string]$proto, [string]$port) {
  if (Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue) { Enable-NetFirewallRule -Name $name; return }
  New-NetFirewallRule -Name $name -DisplayName $display -Group $FW_GROUP -Direction Inbound -Protocol $proto -LocalPort $port -Action Allow -Profile Any | Out-Null
}
function Remove-FwRule([string]$name) { Remove-NetFirewallRule -Name $name -ErrorAction SilentlyContinue }

function Inbound-AllowRules { return @(Get-NetFirewallRule -Direction Inbound -Action Allow -Enabled True -ErrorAction SilentlyContinue | Where-Object { $_.Group -ne $FW_GROUP }) }
function Inbound-AllowRulesForPort([string]$port) {
  $out = @()
  foreach ($r in @(Inbound-AllowRules)) {
    $pf = $r | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
    if ($pf -and (@($pf.LocalPort) -contains $port)) { $out += $r }
  }
  return $out
}
# Inbound rules this setup does not need - kept: Core Networking (DHCP, IPv6), ping, and RDP
# (that one is closed only once SSH works)
function Other-InboundRules {
  $out = @()
  foreach ($r in @(Inbound-AllowRules)) {
    if ($r.Group -eq '@FirewallAPI.dll,-25000') { continue }
    $pf = $r | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
    if ($pf) {
      if (@('ICMPv4', 'ICMPv6', '1', '58') -contains [string]$pf.Protocol) { continue }
      if (@($pf.LocalPort) -contains "$RDP_LOCAL_PORT") { continue }
    }
    $out += $r
  }
  return $out
}

function Apply-Firewall([int[]]$sshPorts) {
  Set-NetFirewallProfile -Profile Domain, Private, Public -Enabled True -DefaultInboundAction Block -DefaultOutboundAction Allow -AllowInboundRules True
  if ($script:FW_RESET -eq 'y') {
    $n = 0
    foreach ($r in @(Other-InboundRules)) { Disable-NetFirewallRule -Name $r.Name; Log-File "firewall: disabled '$($r.DisplayName)' ($($r.Name))"; $n++ }
    if ($n -gt 0) { Note "Firewall: disabled $n other inbound rule(s) (names in $LOG_FILE; Enable-NetFirewallRule -Name <name> brings one back)." }
  }
  foreach ($p in $sshPorts) { Ensure-FwRule "vps-setup-ssh-$p" "vps-setup SSH $p" 'TCP' "$p" }
  foreach ($n in @('OpenSSH-Server-In-TCP', 'sshd')) { Disable-NetFirewallRule -Name $n -ErrorAction SilentlyContinue }   # SSH ports are ours
  if ($CFG.OPEN_WEB -eq 'y') { Ensure-FwRule 'vps-setup-http' 'vps-setup HTTP' 'TCP' '80'; Ensure-FwRule 'vps-setup-https' 'vps-setup HTTPS' 'TCP' '443' }
  else { Remove-FwRule 'vps-setup-http'; Remove-FwRule 'vps-setup-https' }
  if ($CFG.RDP_PUBLIC -eq 'y') { Ensure-FwRule 'vps-setup-rdp' 'vps-setup RDP (public)' 'TCP' "$RDP_LOCAL_PORT" }
  $web = ''
  if ($CFG.OPEN_WEB -eq 'y') { $web = ', 80, 443' }
  $rdp = 'RDP: open until the SSH login is confirmed, then only through an SSH tunnel'
  if ($CFG.RDP_PUBLIC -eq 'y') { $rdp = 'RDP: open to the internet (as chosen)' }
  Note "Firewall: incoming blocked except SSH ($($sshPorts -join ' '))$web. $rdp. GitLab/office tunnels are never opened."
}

# RDP to the internet: closed once SSH works (then: through an SSH tunnel only), unless RDP_PUBLIC=y
function Rdp-ApplyPublic {
  if ($CFG.RDP_PUBLIC -eq 'y') { Ensure-FwRule 'vps-setup-rdp' 'vps-setup RDP (public)' 'TCP' "$RDP_LOCAL_PORT"; return }
  Remove-FwRule 'vps-setup-rdp'
  $n = 0
  foreach ($r in @(Inbound-AllowRulesForPort "$RDP_LOCAL_PORT")) { Disable-NetFirewallRule -Name $r.Name; $n++ }
  if ($n -gt 0) { Note "RDP closed to the internet ($n firewall rule(s) disabled) - use it through SSH: ssh -N -L 13389:127.0.0.1:$RDP_LOCAL_PORT $(Host-Alias)" }
}

# ----------------------------------------------------------------------------
# SSH brute-force guard (what fail2ban does on Ubuntu), from Windows parts only: every minute
# a Task Scheduler task reads the OpenSSH event log; 4 failures in 10 minutes -> the address
# is blocked in Windows Firewall for 1 h, doubling with every repeat up to a week.
# Never blocked: loopback and TRUSTED_IPS.
# ----------------------------------------------------------------------------
function Apply-Ban {
  $a = New-ScheduledTaskAction -Execute $WINPS -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$INSTALL_PATH`" _ban"
  $t1 = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)
  $t2 = New-ScheduledTaskTrigger -AtStartup
  $p = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
  $s = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
  Register-ScheduledTask -TaskName $BAN_TASK -TaskPath $TASK_PATH -Action $a -Trigger @($t1, $t2) -Principal $p -Settings $s -Force | Out-Null
  [void](Native-Out 'wevtutil.exe' @('sl', 'OpenSSH/Operational', '/e:true', '/ms:67108864'))
  $never = 'loopback'
  if ($CFG.TRUSTED_IPS) { $never += ", $($CFG.TRUSTED_IPS)" }
  Note "SSH brute-force guard: 4 failures in 10 min -> blocked 1 h (doubling, up to 1 week); never blocked: $never"
}

function Parse-Time([string]$s) { return [datetime]::Parse($s, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() }

function Cmd-Ban {
  $nowU = (Get-Date).ToUniversalTime()
  $ips = @{}
  $cursor = (Get-Date).AddMinutes(-10)
  $applied = ''
  if (Test-Path -LiteralPath $BAN_STATE) {
    try {
      $j = (Read-Text $BAN_STATE) | ConvertFrom-Json
      $cursor = (Parse-Time ([string]$j.cursor)).ToLocalTime()
      $applied = [string]$j.applied
      foreach ($pr in $j.ips.PSObject.Properties) {
        $v = $pr.Value
        $ips[$pr.Name] = @{ fails = @($v.fails | Where-Object { $_ }); n = [int]$v.n; until = [string]$v.until }
      }
    } catch { }
  }
  $trusted = @(Words $CFG.TRUSTED_IPS)
  $events = @()
  try { $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'OpenSSH/Operational'; StartTime = $cursor } -ErrorAction Stop) } catch { }
  $bad = '(Invalid user|Failed \S+ for|authenticating user|invalid user|maximum authentication attempts|Unable to negotiate|banner exchange|Did not receive identification|Bad protocol version)'
  $latest = $cursor
  foreach ($e in $events) {
    if ($e.TimeCreated -gt $latest) { $latest = $e.TimeCreated }
    $m = [string]$e.Message
    if (-not $m) { $m = (@($e.Properties | ForEach-Object { [string]$_.Value }) -join ' ') }
    if ($m -match 'Accepted ' -or $m -notmatch $bad) { continue }
    $ipm = [regex]::Match($m, '(\d{1,3}(?:\.\d{1,3}){3}|[0-9A-Fa-f]*:[0-9A-Fa-f:]+) port \d+')
    if (-not $ipm.Success) { continue }
    $ip = $ipm.Groups[1].Value
    if ($ip -like '127.*' -or $ip -eq '::1' -or (Ip-Trusted $ip $trusted)) { continue }
    if (-not $ips.ContainsKey($ip)) { $ips[$ip] = @{ fails = @(); n = 0; until = '' } }
    $ips[$ip].fails += $e.TimeCreated.ToUniversalTime().ToString('o')
  }
  $active = @()
  foreach ($ip in @($ips.Keys)) {
    $x = $ips[$ip]
    $x.fails = @($x.fails | Where-Object { (Parse-Time $_) -gt $nowU.AddMinutes(-10) })
    $banned = $x.until -and ((Parse-Time $x.until) -gt $nowU)
    if (-not $banned -and $x.fails.Count -ge 4) {
      $x.n++
      $hours = [math]::Min([math]::Pow(2, $x.n - 1), 168)
      $x.until = $nowU.AddHours($hours).ToString('o')
      $x.fails = @()
      $banned = $true
      Log-File "ssh-ban: $ip blocked for $hours h"
    }
    if ($banned) { $active += $ip }
    elseif ($x.fails.Count -eq 0 -and (-not $x.until -or (Parse-Time $x.until) -lt $nowU.AddDays(-7))) { $ips.Remove($ip) }
  }
  $want = (@($active | Sort-Object) -join ',')
  if ($want -ne $applied) {
    $rule = Get-NetFirewallRule -Name 'vps-setup-ban' -ErrorAction SilentlyContinue
    if ($active.Count -gt 0) {
      if ($rule) { Set-NetFirewallRule -Name 'vps-setup-ban' -RemoteAddress $active -Enabled True }
      else { New-NetFirewallRule -Name 'vps-setup-ban' -DisplayName 'vps-setup SSH bans' -Group $FW_GROUP -Direction Inbound -Action Block -RemoteAddress $active -Profile Any | Out-Null }
    } elseif ($rule) { Set-NetFirewallRule -Name 'vps-setup-ban' -Enabled False }
  }
  $state = @{ cursor = $latest.AddMilliseconds(1).ToUniversalTime().ToString('o'); applied = $want; ips = $ips }
  Write-Text $BAN_STATE ($state | ConvertTo-Json -Depth 5)
}

function Ban-List { # "ip (until ...)" for every active ban
  if (-not (Test-Path -LiteralPath $BAN_STATE)) { return @() }
  $out = @()
  try {
    $j = (Read-Text $BAN_STATE) | ConvertFrom-Json
    foreach ($pr in $j.ips.PSObject.Properties) {
      $u = [string]$pr.Value.until
      if ($u -and (Parse-Time $u) -gt (Get-Date).ToUniversalTime()) { $out += ('{0} (until {1:yyyy-MM-dd HH:mm})' -f $pr.Name, (Parse-Time $u).ToLocalTime()) }
    }
  } catch { }
  return $out
}

# ----------------------------------------------------------------------------
# Internal GitLab and other office services, reachable on the server like on your PC
#
#   Each developer's PC forwards a port of their own on the server's loopback to the
#   service (RemoteForward <port> gitlab.local:22 in their ssh config). On the server the
#   GitLab hostname(s) resolve to 127.77.0.1, office hostnames to 127.77.1.<n>, and office
#   IP addresses live on a loopback adapter - there the vps-gw service listens on the
#   service's own port and carries each connection through the connecting user's own
#   tunnel first, then any other developer's. A port is used only when what listens on it
#   is that user's own SSH session; a closed tunnel, or one that can't reach the service,
#   is skipped - GitLab stays reachable while anyone is connected. A personal service
#   (forward add ... --user) only accepts its users, only through their own tunnel.
# ----------------------------------------------------------------------------
$GATEWAY_SRC = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.ServiceProcess;
using System.Text;
using System.Threading;

// vps-gw - managed by vps-setup. Reads gw.conf:
//   svc <listen ip> <port> <label> <* | user,user> <- | direct host:port>
//   tun <user> <loopback port>          (the tunnels of the svc above, in order)
namespace VpsGw
{
    public class Tunnel { public string User; public int Port; }

    public class Svc
    {
        public IPAddress ListenIp;
        public int ListenPort;
        public string Label;
        public List<string> Owners;   // null = for everyone
        public string DirectHost;
        public int DirectPort;
        public List<Tunnel> Tunnels = new List<Tunnel>();
    }

    public static class Log
    {
        static readonly object Sync = new object();
        public static string File_;
        public static void W(string msg)
        {
            lock (Sync)
            {
                try
                {
                    FileInfo fi = new FileInfo(File_);
                    if (fi.Exists && fi.Length > 5 * 1024 * 1024) { File.Copy(File_, File_ + ".1", true); File.WriteAllText(File_, ""); }
                    File.AppendAllText(File_, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " " + msg + Environment.NewLine);
                }
                catch (Exception) { }
            }
        }
    }

    public static class Tcp
    {
        [DllImport("iphlpapi.dll", SetLastError = true)]
        static extern uint GetExtendedTcpTable(IntPtr table, ref int size, bool order, int af, int tableClass, uint reserved);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
        [DllImport("advapi32.dll", SetLastError = true)]
        static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
        [DllImport("kernel32.dll")]
        static extern bool CloseHandle(IntPtr h);

        public struct Row
        {
            public int State; public byte[] LocalAddr; public int LocalPort;
            public byte[] RemoteAddr; public int RemotePort; public int Pid;
        }

        static int Port(int raw) { return ((raw & 0xFF) << 8) | ((raw >> 8) & 0xFF); }

        // IPv4 TCP table with owning process ids (TCP_TABLE_OWNER_PID_ALL)
        public static List<Row> Rows()
        {
            List<Row> rows = new List<Row>();
            int size = 0;
            GetExtendedTcpTable(IntPtr.Zero, ref size, false, 2, 5, 0);
            for (int attempt = 0; attempt < 5; attempt++)
            {
                size += 4096;
                IntPtr buf = Marshal.AllocHGlobal(size);
                try
                {
                    uint r = GetExtendedTcpTable(buf, ref size, false, 2, 5, 0);
                    if (r == 122) continue;
                    if (r != 0) return rows;
                    int n = Marshal.ReadInt32(buf);
                    for (int i = 0; i < n; i++)
                    {
                        int off = 4 + i * 24;
                        Row row = new Row();
                        row.State = Marshal.ReadInt32(buf, off);
                        row.LocalAddr = BitConverter.GetBytes(Marshal.ReadInt32(buf, off + 4));
                        row.LocalPort = Port(Marshal.ReadInt32(buf, off + 8));
                        row.RemoteAddr = BitConverter.GetBytes(Marshal.ReadInt32(buf, off + 12));
                        row.RemotePort = Port(Marshal.ReadInt32(buf, off + 16));
                        row.Pid = Marshal.ReadInt32(buf, off + 20);
                        rows.Add(row);
                    }
                    return rows;
                }
                finally { Marshal.FreeHGlobal(buf); }
            }
            return rows;
        }

        static bool Same(byte[] a, byte[] b)
        {
            if (a.Length != b.Length) return false;
            for (int i = 0; i < a.Length; i++) if (a[i] != b[i]) return false;
            return true;
        }

        public static string OwnerSid(int pid)
        {
            if (pid <= 0) return null;
            IntPtr h = OpenProcess(0x1000, false, pid);
            if (h == IntPtr.Zero) return null;
            try
            {
                IntPtr tok;
                if (!OpenProcessToken(h, 0x0008, out tok)) return null;
                try { using (WindowsIdentity wi = new WindowsIdentity(tok)) { return wi.User.Value; } }
                finally { CloseHandle(tok); }
            }
            catch (Exception) { return null; }
            finally { CloseHandle(h); }
        }

        public static string ProcName(int pid)
        {
            try { return Process.GetProcessById(pid).ProcessName.ToLowerInvariant(); }
            catch (Exception) { return ""; }
        }

        // the local process on the other end of an accepted connection
        public static int PeerPid(Socket s)
        {
            IPEndPoint peer = s.RemoteEndPoint as IPEndPoint;
            IPEndPoint local = s.LocalEndPoint as IPEndPoint;
            if (peer == null || local == null) return -1;
            byte[] pa = peer.Address.GetAddressBytes();
            byte[] la = local.Address.GetAddressBytes();
            foreach (Row r in Rows())
                if (r.LocalPort == peer.Port && r.RemotePort == local.Port && Same(r.LocalAddr, pa) && Same(r.RemoteAddr, la)) return r.Pid;
            return -1;
        }

        public static List<int> ListenerPids(int port)
        {
            List<int> pids = new List<int>();
            foreach (Row r in Rows())
            {
                bool loop = r.LocalAddr[0] == 127 || (r.LocalAddr[0] == 0 && r.LocalAddr[1] == 0 && r.LocalAddr[2] == 0 && r.LocalAddr[3] == 0);
                if (r.State == 2 && r.LocalPort == port && loop) pids.Add(r.Pid);
            }
            return pids;
        }
    }

    public static class Gateway
    {
        static readonly List<Svc> Services = new List<Svc>();
        static readonly Dictionary<string, string> SidByUser = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        static readonly Semaphore Slots = new Semaphore(256, 256);
        const string SystemSid = "S-1-5-18";

        static string UserSid(string user)
        {
            string sid;
            if (SidByUser.TryGetValue(user, out sid)) return sid;
            try { sid = new NTAccount(Environment.MachineName, user).Translate(typeof(SecurityIdentifier)).Value; }
            catch (Exception) { sid = null; }
            SidByUser[user] = sid;
            return sid;
        }

        static string UserOfSid(string sid)
        {
            if (sid == null) return null;
            foreach (KeyValuePair<string, string> kv in SidByUser) if (kv.Value == sid) return kv.Key;
            return null;
        }

        static void Load(string conf)
        {
            Svc cur = null;
            foreach (string raw in File.ReadAllLines(conf))
            {
                string line = raw.Trim();
                if (line.Length == 0 || line.StartsWith("#")) continue;
                string[] f = line.Split(new char[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
                if (f[0] == "svc" && f.Length >= 6)
                {
                    cur = new Svc();
                    cur.ListenIp = IPAddress.Parse(f[1]);
                    cur.ListenPort = int.Parse(f[2]);
                    cur.Label = f[3];
                    if (f[4] != "*")
                    {
                        cur.Owners = new List<string>(f[4].ToLowerInvariant().Split(','));
                        foreach (string o in cur.Owners) UserSid(o);
                    }
                    if (f[5] != "-")
                    {
                        int c = f[5].LastIndexOf(':');
                        cur.DirectHost = f[5].Substring(0, c);
                        cur.DirectPort = int.Parse(f[5].Substring(c + 1));
                    }
                    Services.Add(cur);
                }
                else if (f[0] == "tun" && f.Length >= 3 && cur != null)
                {
                    Tunnel t = new Tunnel();
                    t.User = f[1].ToLowerInvariant();
                    t.Port = int.Parse(f[2]);
                    UserSid(t.User);
                    cur.Tunnels.Add(t);
                }
            }
        }

        public static void Run(string conf)
        {
            Log.File_ = Path.Combine(Path.GetDirectoryName(conf), "gw.log");
            try { Load(conf); }
            catch (Exception e) { Log.W("cannot read " + conf + ": " + e.Message); return; }
            List<Thread> threads = new List<Thread>();
            foreach (Svc svc in Services)
            {
                Svc s = svc;
                Thread th = new Thread(delegate () { Serve(s); });
                th.IsBackground = true;
                th.Start();
                threads.Add(th);
            }
            Log.W("started: " + Services.Count + " service(s)");
            foreach (Thread th2 in threads) th2.Join();
        }

        static void Serve(Svc svc)
        {
            TcpListener l = null;
            for (int i = 0; l == null; i++)
            {
                try { l = new TcpListener(svc.ListenIp, svc.ListenPort); l.Start(128); }
                catch (SocketException e)
                {
                    l = null;
                    // at boot the loopback adapter's addresses may still be coming up
                    if (i == 15) { Log.W("cannot listen on " + svc.ListenIp + ":" + svc.ListenPort + " (" + e.Message + ") - continuing with the others"); return; }
                    Thread.Sleep(2000);
                }
            }
            Log.W("listening on " + svc.ListenIp + ":" + svc.ListenPort + " for " + svc.Label +
                  (svc.Owners == null ? " (everyone)" : " (personal: " + string.Join(",", svc.Owners.ToArray()) + ")"));
            while (true)
            {
                Socket c;
                try { c = l.AcceptSocket(); }
                catch (Exception e) { Log.W("accept failed: " + e.Message); Thread.Sleep(500); continue; }
                Slots.WaitOne();
                Socket cc = c;
                Thread th = new Thread(delegate () { Handle(cc, svc); });
                th.IsBackground = true;
                th.Start();
            }
        }

        static Socket Connect(IPAddress ip, int port, int timeoutMs)
        {
            Socket s = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
            try
            {
                IAsyncResult ar = s.BeginConnect(ip, port, null, null);
                if (!ar.AsyncWaitHandle.WaitOne(timeoutMs)) { s.Close(); return null; }
                s.EndConnect(ar);
                s.NoDelay = true;
                return s;
            }
            catch (Exception) { s.Close(); return null; }
        }

        // a tunnel port is used only if what listens on it is that user's own sshd session
        static bool TunnelOwnedBy(Tunnel t, out string why)
        {
            why = "";
            List<int> pids = Tcp.ListenerPids(t.Port);
            if (pids.Count == 0) { why = "not open"; return false; }
            string want = UserSid(t.User);
            foreach (int pid in pids)
            {
                string sid = Tcp.OwnerSid(pid);
                string name = Tcp.ProcName(pid);
                if (name != "sshd") { why = "the port is held by another program (" + name + ")"; return false; }
                if (sid != null && sid != want && sid != SystemSid) { why = "the port was opened by another user"; return false; }
            }
            return true;
        }

        static void Handle(Socket client, Svc svc)
        {
            try
            {
                int pid = Tcp.PeerPid(client);
                string peerSid = Tcp.OwnerSid(pid);
                string peer = UserOfSid(peerSid);
                string who = peer != null ? peer : (peerSid != null ? peerSid : "unknown");
                if (svc.Owners != null && (peer == null || !svc.Owners.Contains(peer)))
                {
                    Log.W(svc.Label + ": refused a connection from " + who + " (personal service of " + string.Join(",", svc.Owners.ToArray()) + ")");
                    return;
                }
                byte[] early = null;
                if (client.Poll(300000, SelectMode.SelectRead))
                {
                    byte[] b = new byte[65536];
                    int n = client.Receive(b);
                    if (n <= 0) return;
                    early = new byte[n];
                    Array.Copy(b, early, n);
                }
                List<Tunnel> order = new List<Tunnel>();
                foreach (Tunnel t in svc.Tunnels) if (t.User == peer) order.Add(t);
                if (svc.Owners == null) foreach (Tunnel t2 in svc.Tunnels) if (t2.User != peer) order.Add(t2);
                foreach (Tunnel t3 in order)
                {
                    string why;
                    if (!TunnelOwnedBy(t3, out why))
                    {
                        if (why != "not open") Log.W(svc.Label + ": skipping the tunnel of " + t3.User + " (" + why + ")");
                        continue;
                    }
                    Socket up = Connect(IPAddress.Loopback, t3.Port, 3000);
                    if (up == null) continue;
                    if (TryRoute(client, up, early, svc.Label + " for " + who + " via " + t3.User + "'s tunnel")) return;
                }
                if (svc.DirectHost != null)
                {
                    foreach (IPAddress ip in DirectIps(svc.DirectHost))
                    {
                        Socket up2 = Connect(ip, svc.DirectPort, 5000);
                        if (up2 == null) continue;
                        if (TryRoute(client, up2, early, svc.Label + " for " + who + " direct " + ip)) return;
                    }
                }
                Log.W(svc.Label + " for " + who + ": no route (" +
                      (svc.Owners != null ? "this user's own tunnel is not open" : "no developer tunnel is open") +
                      (svc.DirectHost != null ? ", direct failed" : "") + ")");
            }
            catch (Exception e) { Log.W(svc.Label + ": " + e.Message); }
            finally
            {
                try { client.Close(); } catch (Exception) { }
                Slots.Release();
            }
        }

        static bool TryRoute(Socket client, Socket up, byte[] early, string what)
        {
            try
            {
                if (early != null) SendAll(up, early, early.Length);
                if (up.Poll(3000000, SelectMode.SelectRead))
                {
                    byte[] first = new byte[65536];
                    int n = up.Receive(first);
                    if (n <= 0) throw new IOException("open, but the service is not reachable through it");
                    SendAll(client, first, n);
                }
            }
            catch (Exception e) { Log.W(what + ": skipped (" + e.Message + ")"); up.Close(); return false; }
            Log.W(what);
            Thread back = new Thread(delegate () { Relay(up, client); });
            back.IsBackground = true;
            back.Start();
            Relay(client, up);
            back.Join();
            up.Close();
            return true;
        }

        static void SendAll(Socket s, byte[] b, int n)
        {
            int off = 0;
            while (off < n)
            {
                int k = s.Send(b, off, n - off, SocketFlags.None);
                if (k <= 0) throw new IOException("send failed");
                off += k;
            }
        }

        static void Relay(Socket src, Socket dst)
        {
            byte[] b = new byte[65536];
            try
            {
                while (true)
                {
                    int n = src.Receive(b);
                    if (n <= 0) break;
                    SendAll(dst, b, n);
                }
            }
            catch (Exception) { }
            finally { try { dst.Shutdown(SocketShutdown.Send); } catch (Exception) { } }
        }

        // the service's public address (looked up in public DNS, not the hosts file)
        static readonly object DnsSync = new object();
        static readonly Dictionary<string, List<IPAddress>> DnsCache = new Dictionary<string, List<IPAddress>>();
        static readonly Dictionary<string, DateTime> DnsAt = new Dictionary<string, DateTime>();

        static List<IPAddress> DirectIps(string host)
        {
            lock (DnsSync)
            {
                List<IPAddress> ips = null;
                DateTime at = DateTime.MinValue;
                DnsCache.TryGetValue(host, out ips);
                DnsAt.TryGetValue(host, out at);
                double maxAge = (ips != null && ips.Count > 0) ? 300 : 30;   // a failed lookup is retried after 30 s
                if (ips == null || (DateTime.UtcNow - at).TotalSeconds > maxAge)
                {
                    ips = PublicIpv4(host);
                    DnsCache[host] = ips;
                    DnsAt[host] = DateTime.UtcNow;
                }
                return ips;
            }
        }

        static List<IPAddress> DnsServers()
        {
            List<IPAddress> list = new List<IPAddress>();
            foreach (NetworkInterface ni in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (ni.OperationalStatus != OperationalStatus.Up) continue;
                foreach (IPAddress a in ni.GetIPProperties().DnsAddresses)
                    if (a.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(a) && !list.Contains(a)) list.Add(a);
            }
            return list;
        }

        static int SkipName(byte[] d, int i)
        {
            while (i < d.Length)
            {
                int len = d[i];
                if (len == 0) return i + 1;
                if ((len & 0xC0) == 0xC0) return i + 2;
                i += len + 1;
            }
            throw new IOException("bad DNS answer");
        }

        static List<IPAddress> PublicIpv4(string name)
        {
            List<IPAddress> found = new List<IPAddress>();
            byte[] id = new byte[2];
            new Random().NextBytes(id);
            MemoryStream q = new MemoryStream();
            q.Write(id, 0, 2);
            q.Write(new byte[] { 1, 0, 0, 1, 0, 0, 0, 0, 0, 0 }, 0, 10);
            foreach (string label in name.TrimEnd('.').Split('.'))
            {
                byte[] lb = Encoding.ASCII.GetBytes(label);
                q.WriteByte((byte)lb.Length);
                q.Write(lb, 0, lb.Length);
            }
            q.Write(new byte[] { 0, 0, 1, 0, 1 }, 0, 5);
            byte[] query = q.ToArray();
            foreach (IPAddress server in DnsServers())
            {
                try
                {
                    using (UdpClient udp = new UdpClient(AddressFamily.InterNetwork))
                    {
                        udp.Client.ReceiveTimeout = 2000;
                        udp.Send(query, query.Length, new IPEndPoint(server, 53));
                        IPEndPoint from = null;
                        byte[] d = udp.Receive(ref from);
                        if (d.Length < 12 || d[0] != id[0] || d[1] != id[1]) continue;
                        int answers = (d[6] << 8) | d[7];
                        int i = SkipName(d, 12) + 4;
                        for (int k = 0; k < answers && i < d.Length; k++)
                        {
                            i = SkipName(d, i);
                            if (i + 10 > d.Length) break;
                            int type = (d[i] << 8) | d[i + 1];
                            int rdlen = (d[i + 8] << 8) | d[i + 9];
                            i += 10;
                            if (i + rdlen > d.Length) break;
                            if (type == 1 && rdlen == 4) found.Add(new IPAddress(new byte[] { d[i], d[i + 1], d[i + 2], d[i + 3] }));
                            i += rdlen;
                        }
                        if (found.Count > 0) return found;
                    }
                }
                catch (Exception) { }
            }
            return found;
        }
    }

    public class GwService : ServiceBase
    {
        public GwService() { ServiceName = "vps-gw"; CanStop = true; CanShutdown = true; }
        protected override void OnStart(string[] args)
        {
            Thread t = new Thread(delegate () { Gateway.Run(Program.Conf); });
            t.IsBackground = true;
            t.Start();
        }
        protected override void OnStop() { }
    }

    public static class Program
    {
        public static string Conf;
        public static int Main(string[] args)
        {
            Conf = args.Length > 0 ? args[0] : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "vps-setup\\gw.conf");
            if (args.Length > 1 && args[1] == "--console") { Gateway.Run(Conf); return 0; }
            ServiceBase.Run(new GwService());
            return 0;
        }
    }
}
'@

function Gitlab-Ports { return @(Words (Uniq-Words $CFG.GITLAB_SSH_PORT $CFG.GITLAB_PORTS)) }
function Gitlab-Primary { $a = @(Words $CFG.GITLAB_HOST); if ($a.Count -gt 0) { return $a[0] }; return '' }
function Ssh-PortSet { $s = @{}; foreach ($p in (@(Words $CFG.SSH_PORTS) + @(Current-SshPorts))) { $s[[int]$p] = 1 }; return $s }
# GitLab's SSH port on the server: its own, unless sshd uses that port here
function Gitlab-ListenPort([int]$port) {
  if ($port -eq [int]$CFG.GITLAB_SSH_PORT -and (Ssh-PortSet).ContainsKey($port)) { return $GITLAB_SSH_ALT_PORT }
  return $port
}

# ---- office services (vps-setup forward add 192.168.2.212:8100) ----
function Fwd-IpOk([string]$ip) { # an office address: private, and not on this server's own network
  $o = $ip.Split('.')
  $a = [int]$o[0]
  $b = [int]$o[1]
  if (-not ($a -eq 10 -or ($a -eq 172 -and $b -ge 16 -and $b -le 31) -or ($a -eq 192 -and $b -eq 168) -or ($a -eq 100 -and $b -ge 64 -and $b -le 127))) {
    Warn "$ip is not a private (office) address - the server reaches public addresses by itself."
    return $false
  }
  foreach ($x in @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceAlias -ne $LOOPBACK_NAME -and $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' })) {
    if (In-Subnet $ip $x.IPAddress ([int]$x.PrefixLength)) {
      Warn "$ip is on this server's own network ($($x.IPAddress)/$($x.PrefixLength)) - forwarding it would cut the server off from it."
      return $false
    }
  }
  return $true
}

function Fwd-Parse([string]$spec) { # host:port or URL -> "host:port" (or $null, with the reason)
  $s = $spec.ToLower()
  $scheme = ''
  if ($s -match '^([a-z][a-z0-9+.-]*)://(.*)$') { $scheme = $Matches[1]; $s = $Matches[2] }
  $s = ($s -split '/', 2)[0]
  $s = ($s -split '\?', 2)[0]
  $s = ($s -split '@')[-1]
  if ($s.Contains(':')) {
    $i = $s.LastIndexOf(':')
    $h = $s.Substring(0, $i)
    $port = $s.Substring($i + 1)
  } else {
    $h = $s
    if ($scheme -eq 'http') { $port = '80' } elseif ($scheme -eq 'https') { $port = '443' } else { Warn "'$spec': give the port too, e.g. ${s}:8100"; return $null }
  }
  if ($port -notmatch '^[0-9]{1,5}$' -or [int]$port -lt 1 -or [int]$port -gt 65535) { Warn "'$spec': bad port '$port'."; return $null }
  $port = [int]$port
  if ($h -match '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$') {
    $o = @($h.Split('.') | ForEach-Object { [int]$_ })
    if (@($o | Where-Object { $_ -gt 255 }).Count -gt 0) { Warn "'$h' is not an IPv4 address."; return $null }
    $h = $o -join '.'
    if (-not $script:FWD_LENIENT -and -not (Fwd-IpOk $h)) { return $null }
  } elseif ($h -match '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$' -and $h.Length -le 50) {
    if (-not $script:FWD_LENIENT -and (@(Words $CFG.GITLAB_HOST | ForEach-Object { $_.ToLower() }) -contains $h)) { Warn "$h is the GitLab host - it is reachable already (vps-setup gitlab)."; return $null }
  } else {
    Warn "'$spec': not a hostname (at most 50 characters) or an IPv4 address."
    return $null
  }
  return "${h}:$port"
}

function Fwd-Match([string]$spec, [string[]]$pool) { # the entries a remove request means
  $h = $spec.ToLower() -replace '^[a-z][a-z0-9+.-]*://', ''
  $h = (($h -split '/', 2)[0] -split '\?', 2)[0]
  $h = ($h -split '@')[-1]
  $script:FWD_LENIENT = $true
  try { $n = Fwd-Parse $spec 3>$null 6>$null } finally { $script:FWD_LENIENT = $false }
  $out = @($pool | Where-Object { $n -and $_ -eq $n })
  if ($out.Count -gt 0 -or $h.Contains(':')) { return $out }   # an explicit port: exactly that
  return @($pool | Where-Object { $_.Substring(0, $_.LastIndexOf(':')) -eq $h })   # no port: every port of that host
}

function Valid-ForwardList([string]$list) { foreach ($s in @(Words $list)) { if (-not (Fwd-Parse $s)) { return $false } }; return $true }
function Fwd-Normalize([string]$list) { $out = @(); foreach ($s in @(Words $list)) { $n = Fwd-Parse $s; if ($n) { $out += $n } }; return (Uniq-Words $out) }
function Fwd-Targets { # every forwarded host:port, for everyone or personal
  $per = @()
  foreach ($e in @(Words $CFG.FORWARDS_USER)) { $per += ($e -split '=', 2)[1] }
  return @(Words (Uniq-Words $CFG.FORWARDS $per))
}
function Fwd-ForUser([string]$u) { # what <user> gets: the forwards for everyone + their own
  $own = @()
  foreach ($e in @(Words $CFG.FORWARDS_USER)) { $kv = $e -split '=', 2; if ($kv[0] -eq $u) { $own += $kv[1] } }
  return @(Words (Uniq-Words $CFG.FORWARDS $own))
}
function Fwd-ScopeOf([string]$t) { # "all", or the users (comma-separated) whose own it is
  if (@(Words $CFG.FORWARDS) -contains $t) { return 'all' }
  $us = @()
  foreach ($e in @(Words $CFG.FORWARDS_USER)) { $kv = $e -split '=', 2; if ($kv[1] -eq $t -and (User-Exists $kv[0])) { $us += $kv[0] } }
  return ($us -join ',')
}
function Fwd-OwnerNames([string]$t) {
  if (@(Words $CFG.FORWARDS) -contains $t) { return 'everyone' }
  $us = @()
  foreach ($e in @(Words $CFG.FORWARDS_USER)) { $kv = $e -split '=', 2; if ($kv[1] -eq $t) { $us += $kv[0] } }
  if ($us.Count -eq 0) { return '(nobody)' }
  return ($us -join ' ')
}
function Fwd-HostOf([string]$t) { return $t.Substring(0, $t.LastIndexOf(':')) }
function Fwd-PortOf([string]$t) { return [int]$t.Substring($t.LastIndexOf(':') + 1) }
function Fwd-Hosts { $seen = @{}; $out = @(); foreach ($t in @(Fwd-Targets)) { $h = Fwd-HostOf $t; if (-not $seen.ContainsKey($h)) { $seen[$h] = 1; $out += $h } }; return $out }
function Fwd-IsIp([string]$h) { return $h -match '^[0-9.]+$' }
function Fwd-IpOf([string]$h) { # the address this server uses for a forwarded host
  if (Fwd-IsIp $h) { return $h }
  $n = 0
  foreach ($x in @(Fwd-Hosts)) {
    if (Fwd-IsIp $x) { continue }
    $n++
    if ($x -eq $h) { return "$FWD_NAME_NET.$n" }
  }
  return $null
}

# Every office service keeps its number (its tunnel port) while it exists
function Fwd-IdOf([string]$t) {
  foreach ($e in @(Words $CFG.FWD_IDS)) { $i = $e.LastIndexOf('='); if ($e.Substring(0, $i) -eq $t) { return [int]$e.Substring($i + 1) } }
  return 0
}
function Sync-FwdIds {
  $targets = @(Fwd-Targets)
  $keep = @()
  $used = @{}
  foreach ($e in @(Words $CFG.FWD_IDS)) {
    $i = $e.LastIndexOf('=')
    if ($targets -contains $e.Substring(0, $i)) { $keep += $e; $used[[int]$e.Substring($i + 1)] = 1 }
  }
  foreach ($t in $targets) {
    if (@($keep | Where-Object { $_.StartsWith("$t=") }).Count -gt 0) { continue }
    $id = 0
    for ($k = 1; $k -lt ($TUNNEL_SLOT_SIZE - $TUNNEL_FWD_OFFSET); $k++) { if (-not $used.ContainsKey($k)) { $id = $k; break } }
    if ($id -eq 0) { Die 'Too many office services (at most 79).' }
    $used[$id] = 1
    $keep += "$t=$id"
  }
  $CFG.FWD_IDS = $keep -join ' '
}

# ---- the gateway service ----
function Render-GwConf {
  $lines = @('# Managed by vps-setup - read by the vps-gw service when it starts')
  $users = @(Server-Users)
  $sshSet = Ssh-PortSet
  if ($CFG.GITLAB_HOST -and $CFG.GITLAB_SSH_PORT) {
    $ports = @(Gitlab-Ports)
    for ($i = 0; $i -lt $ports.Count; $i++) {
      $p = [int]$ports[$i]
      $lp = Gitlab-ListenPort $p
      if ($lp -eq $p -and $sshSet.ContainsKey($p)) { continue }   # a web port that sshd uses here
      $direct = '-'
      if ($CFG.GITLAB_DIRECT -eq 'y') { $direct = "$(Gitlab-Primary):$p" }
      $lines += "svc $GITLAB_IP $lp gitlab:$p * $direct"
      foreach ($u in $users) { $tp = Tunnel-Port $u $i; if ($tp -gt 0) { $lines += "tun $u $tp" } }
    }
  }
  foreach ($t in @(Fwd-Targets)) {
    $scope = Fwd-ScopeOf $t
    if (-not $scope) { continue }   # its users are gone
    $h = Fwd-HostOf $t
    $id = Fwd-IdOf $t
    if ($scope -eq 'all') { $owners = '*'; $tunUsers = $users } else { $owners = $scope; $tunUsers = @($scope -split ',') }
    $lines += "svc $(Fwd-IpOf $h) $(Fwd-PortOf $t) $t $owners -"
    foreach ($u in $tunUsers) { $tp = Tunnel-Port $u ($TUNNEL_FWD_OFFSET + $id); if ($tp -gt 0) { $lines += "tun $u $tp" } }
  }
  return (Lines $lines)
}

function Build-Gateway { # compiled from the source above with the C# compiler that ships with Windows
  $hash = Sha256-Text $GATEWAY_SRC
  $hf = "$INSTALL_DIR\vps-gw.sha256"
  if ((Test-Path -LiteralPath $GW_EXE) -and (Read-Text $hf).Trim() -eq $hash) { return }
  $s = Get-Service $GW_SERVICE -ErrorAction SilentlyContinue
  if ($s -and $s.Status -ne 'Stopped') { Stop-Service $GW_SERVICE -Force }
  New-Dir $INSTALL_DIR
  Remove-Item -LiteralPath $GW_EXE -Force -ErrorAction SilentlyContinue
  Add-Type -TypeDefinition $GATEWAY_SRC -Language CSharp -OutputAssembly $GW_EXE -OutputType ConsoleApplication -ReferencedAssemblies 'System.ServiceProcess'
  Write-Text $hf $hash
}

function Hosts-Update([string]$tag, [string[]]$entries = @()) { # entries: "ip name..." - our lines, nothing else mapping those names
  $marker = "# vps-setup $tag"
  $names = @()
  foreach ($e in $entries) { $names += @(Words $e | Select-Object -Skip 1 | ForEach-Object { $_.ToLower() }) }
  $out = New-Object System.Collections.ArrayList
  $backed = $false
  $lines = @()
  if (Test-Path -LiteralPath $HOSTS_FILE) { $lines = @(Get-Content -LiteralPath $HOSTS_FILE) }
  foreach ($l in $lines) {
    if ($l.TrimEnd().EndsWith($marker)) { continue }
    $w = @(Words (($l -split '#', 2)[0]))
    if ($w.Count -ge 2 -and $l -notmatch '# vps-setup ') {
      $hit = @($w[1..($w.Count - 1)] | Where-Object { $names -contains $_.ToLower() })
      if ($hit.Count -gt 0) {
        if (-not $backed) { Backup-File $HOSTS_FILE; $backed = $true }
        [void]$out.Add("# disabled by vps-setup: $l")
        Note "The hosts file already mapped $($hit -join ' ') - that line was commented out."
        continue
      }
    }
    [void]$out.Add($l)
  }
  foreach ($e in $entries) { [void]$out.Add("$e  $marker") }
  [IO.File]::WriteAllText($HOSTS_FILE, (($out -join "`r`n") + "`r`n"), [Text.Encoding]::ASCII)
  [void](Native-Out 'ipconfig.exe' @('/flushdns'))
}

function Loopback-Adapter { return (Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $LOOPBACK_NAME -or $_.InterfaceDescription -like '*KM-TEST*' } | Select-Object -First 1) }

# Office services given by IP address: the address lives on a loopback adapter, so this
# server's own connections to it reach the gateway (it never answers on any real network).
function Loopback-Sync {
  $want = @()
  foreach ($t in @(Fwd-Targets)) {
    $h = Fwd-HostOf $t
    if ((Fwd-IsIp $h) -and (Fwd-ScopeOf $t) -and $want -notcontains $h) { $want += $h }
  }
  $a = Loopback-Adapter
  if ($want.Count -eq 0) {
    if ($a) { Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue }
    return
  }
  if (-not $a) {
    Info 'Adding a loopback network adapter for the office IP addresses...'
    Load-Native
    $r = [VpsNative.Win]::InstallLoopback("$env:SystemRoot\INF\netloop.inf")
    if ($r -ne 0) { Die "Could not add the loopback adapter (error $r). Office services given by IP need it - give them by hostname instead." }
    for ($i = 0; $i -lt 30 -and -not $a; $i++) { Start-Sleep -Seconds 1; $a = Loopback-Adapter }
    if (-not $a) { Die 'The loopback adapter did not appear.' }
  }
  if ($a.Name -ne $LOOPBACK_NAME) { Rename-NetAdapter -Name $a.Name -NewName $LOOPBACK_NAME; $a = Loopback-Adapter }
  if ([string]$a.Status -eq 'Disabled') { Enable-NetAdapter -Name $LOOPBACK_NAME -Confirm:$false }
  Disable-NetAdapterBinding -Name $LOOPBACK_NAME -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
  Set-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -Dhcp Disabled -ErrorAction SilentlyContinue
  $have = @(Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)
  foreach ($x in $have) { if ($want -notcontains $x.IPAddress) { Remove-NetIPAddress -InputObject $x -Confirm:$false -ErrorAction SilentlyContinue } }
  foreach ($ip in $want) {
    if (-not ($have | Where-Object { $_.IPAddress -eq $ip })) { New-NetIPAddress -InterfaceIndex $a.ifIndex -IPAddress $ip -PrefixLength 32 -SkipAsSource $true | Out-Null }
  }
  for ($i = 0; $i -lt 20; $i++) {   # usable once Windows has checked the addresses
    $tent = @(Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { [string]$_.AddressState -ne 'Preferred' })
    if ($tent.Count -eq 0) { break }
    Start-Sleep -Milliseconds 500
  }
}

function Ssh-ClientBlock { # git over SSH to the internal GitLab, for every user on this server
  if (-not ($CFG.GITLAB_HOST -and $CFG.GITLAB_SSH_PORT)) { return @() }
  return @("Host $($CFG.GITLAB_HOST)", '    User git', "    HostName $GITLAB_IP", "    Port $(Gitlab-ListenPort ([int]$CFG.GITLAB_SSH_PORT))",
    "    HostKeyAlias $(Gitlab-Primary)", '    StrictHostKeyChecking accept-new', '    UserKnownHostsFile ~/.ssh/known_hosts_gitlab')
}

function Gw-Needed { return [bool](($CFG.GITLAB_HOST -and $CFG.GITLAB_SSH_PORT) -or @(Fwd-Targets).Count -gt 0) }

function Gw-Apply { # writes everything from the current configuration and (re)starts the gateway
  if (-not (Gw-Needed)) { Gw-Remove; return }
  Sync-FwdIds
  Save-Config
  Build-Gateway
  Write-Text $GW_CONF (Render-GwConf)
  Loopback-Sync
  $gl = @()
  if ($CFG.GITLAB_HOST -and $CFG.GITLAB_SSH_PORT) { $gl = @("$GITLAB_IP $($CFG.GITLAB_HOST)") }
  Hosts-Update 'gitlab' $gl
  $fh = @()
  foreach ($h in @(Fwd-Hosts)) { if (-not (Fwd-IsIp $h)) { $fh += "$(Fwd-IpOf $h) $h" } }
  Hosts-Update 'forward' $fh
  Set-ManagedBlock $SSH_CLIENT_CONFIG 'gitlab' @(Ssh-ClientBlock)
  if (-not (Get-Service $GW_SERVICE -ErrorAction SilentlyContinue)) {
    New-Service -Name $GW_SERVICE -BinaryPathName "`"$GW_EXE`" `"$GW_CONF`"" -DisplayName 'vps-setup gateway' -StartupType Automatic `
      -Description 'Internal GitLab and office services through the developers'' SSH tunnels (vps-setup)' | Out-Null
    [void](Native-Out 'sc.exe' @('failure', $GW_SERVICE, 'reset=', '86400', 'actions=', 'restart/2000/restart/2000/restart/5000'))
  }
  Restart-Service $GW_SERVICE -Force
  Start-Sleep -Seconds 3
  if ((Get-Service $GW_SERVICE).Status -ne 'Running') {
    @((Read-Text $GW_LOG) -split "`r?`n") | Select-Object -Last 15 | ForEach-Object { Write-Host "    $_" }
    Die "The gateway service did not start (log: $GW_LOG)."
  }
}

function Gw-Remove {
  if (Get-Service $GW_SERVICE -ErrorAction SilentlyContinue) {
    Stop-Service $GW_SERVICE -Force -ErrorAction SilentlyContinue
    [void](Native-Out 'sc.exe' @('delete', $GW_SERVICE))
  }
  Hosts-Update 'gitlab'
  Hosts-Update 'forward'
  Set-ManagedBlock $SSH_CLIENT_CONFIG 'gitlab' @()
  Loopback-Sync
  Remove-Item -LiteralPath $GW_CONF -Force -ErrorAction SilentlyContinue
}

function Gw-Listening([string]$ip, [int]$port) { return @(Get-NetTCPConnection -State Listen -LocalAddress $ip -LocalPort $port -ErrorAction SilentlyContinue).Count -gt 0 }

function Gitlab-Apply {
  if (-not ($CFG.GITLAB_HOST -and $CFG.GITLAB_SSH_PORT)) { Die 'No GitLab configured (GITLAB_HOST / GITLAB_SSH_PORT).' }
  Gw-Apply
  $ready = @()
  $taken = @()
  foreach ($p in @(Gitlab-Ports)) {
    $lp = Gitlab-ListenPort ([int]$p)
    if (Gw-Listening $GITLAB_IP $lp) { $ready += $p } else { $taken += $p }
  }
  Note "GitLab: $($CFG.GITLAB_HOST) -> $GITLAB_IP on this server; ports ready: $(if ($ready.Count) { $ready -join ' ' } else { '(none)' })"
  Note "GitLab: git@$(Gitlab-Primary) works for every user (SSH port $($CFG.GITLAB_SSH_PORT), mapped in $SSH_CLIENT_CONFIG)."
  if ($CFG.GITLAB_DIRECT -eq 'y') { Note "GitLab: with no developer tunnel up, connections go directly to $(Gitlab-Primary)'s public address." }
  if ($taken.Count -gt 0) { Note "GitLab: port(s) $($taken -join ' ') are already taken on this server (e.g. by sshd) - continuing with the others; git over SSH is unaffected." }
}

function Gitlab-Disable {
  $CFG.GITLAB_HOST = ''; $CFG.GITLAB_SSH_PORT = ''; $CFG.GITLAB_PORTS = ''; $CFG.GITLAB_DIRECT = ''
  Save-Config
  Gw-Apply
  Ok 'GitLab gateway removed.'
}

function Gitlab-Tunnels { # which users have a tunnel open right now
  $out = @()
  $ports = @(Gitlab-Ports)
  foreach ($u in @(Server-Users)) {
    for ($i = 0; $i -lt $ports.Count; $i++) { $tp = Tunnel-Port $u $i; if ($tp -gt 0 -and (Port-Listening $tp)) { $out += "${u}:$($ports[$i])" } }
  }
  if ($out.Count -eq 0) { return '(none)' }
  return ($out -join ' ')
}

function Fwd-Apply {
  if (@(Fwd-Targets).Count -eq 0) { Gw-Apply; return }
  Gw-Apply
  foreach ($t in @(Fwd-Targets)) {
    if (-not (Fwd-ScopeOf $t)) { continue }
    if (-not (Gw-Listening (Fwd-IpOf (Fwd-HostOf $t)) (Fwd-PortOf $t))) { Warn "The gateway is not listening for $t yet (log: $GW_LOG)." }
  }
  $all = $CFG.FORWARDS
  if (-not $all) { $all = '(none)' }
  Note "Office services for everyone (while any developer is connected): $all"
  if ($CFG.FORWARDS_USER) { Note "Personal office services (while that user is connected): $($CFG.FORWARDS_USER)" }
}

function Fwd-TunnelUsers([string]$t) { # users whose tunnel for <host:port> is open now
  $out = @()
  $id = Fwd-IdOf $t
  if ($id -le 0) { return '(nobody connected)' }
  foreach ($u in @(Server-Users)) { $tp = Tunnel-Port $u ($TUNNEL_FWD_OFFSET + $id); if ($tp -gt 0 -and (Port-Listening $tp)) { $out += $u } }
  if ($out.Count -eq 0) { return '(nobody connected)' }
  return ($out -join ' ')
}

function Fwd-List {
  if (@(Fwd-Targets).Count -eq 0) {
    Info 'No office services. For everyone: vps-setup forward add 192.168.2.212:8100'
    Info '                     One user only: vps-setup forward add 192.168.2.212:8100 --user ali'
    return
  }
  $s = Get-Service $GW_SERVICE -ErrorAction SilentlyContinue
  if ($s -and $s.Status -eq 'Running') { Ok "Gateway running ($GW_SERVICE)" } else { Warn 'Gateway NOT running: vps-setup forward apply' }
  Write-Host ('    {0,-30} {1,-18} {2,-14} {3}' -f 'SERVICE', 'FOR', 'HERE AS', 'TUNNEL OPEN NOW')
  foreach ($t in @(Fwd-Targets)) {
    Write-Host ('    {0,-30} {1,-18} {2,-14} {3}' -f $t, (Fwd-OwnerNames $t), (Fwd-IpOf (Fwd-HostOf $t)), (Fwd-TunnelUsers $t))
  }
}

function Cmd-Forward([string[]]$a) {
  $action = ''
  if ($a.Count -gt 0) { $action = $a[0] }
  $user = ''
  $specs = @()
  for ($i = 1; $i -lt $a.Count; $i++) {
    $x = $a[$i]
    if ($x -eq '--user' -or $x -eq '-u') { $i++; if ($i -lt $a.Count) { $user = $a[$i] } }
    elseif ($x -like '--user=*') { $user = $x.Substring(7) }
    elseif ($x.StartsWith('-')) { Die "Unknown option $x" }
    else { $specs += $x }
  }
  if ($user -and -not ((User-Exists $user) -and (In-Group $user $SSH_GROUP))) { Die "'$user' is not a server user." }
  switch ($action) {
    'add' {
      if ($specs.Count -eq 0) { Die 'usage: vps-setup forward add <host:port | URL>... [--user <name>]   e.g. http://192.168.2.212:8100/docs' }
      $added = @()
      foreach ($s in $specs) { $n = Fwd-Parse $s; if (-not $n) { Die "Not added: $s" }; $added += $n }
      if (-not $user) {
        $CFG.FORWARDS = Uniq-Words $CFG.FORWARDS $added
        # now for everyone: personal copies of the same service are not needed any more
        $CFG.FORWARDS_USER = (@(Words $CFG.FORWARDS_USER) | Where-Object { $added -notcontains ($_ -split '=', 2)[1] }) -join ' '
      } else {
        foreach ($n in $added) {
          if (@(Words $CFG.FORWARDS) -contains $n) { Warn "$n is already there for everyone (including $user)."; continue }
          $CFG.FORWARDS_USER = Uniq-Words $CFG.FORWARDS_USER "$user=$n"
        }
      }
      Save-Config
      Fwd-Apply
      Ok "Office services - for everyone: $(if ($CFG.FORWARDS) { $CFG.FORWARDS } else { '(none)' }); personal: $(if ($CFG.FORWARDS_USER) { $CFG.FORWARDS_USER } else { '(none)' })"
      $who = 'Every developer'
      if ($user) { $who = $user }
      $sheet = '<user>'
      if ($user) { $sheet = $user }
      Info "$who adds these lines under the server's Host in ~/.ssh/config and reconnects"
      Info "(the full, updated block is in $USERS_DIR\$sheet.txt):"
      foreach ($n in $added) {
        $id = Fwd-IdOf $n
        if ($user) { Info "    RemoteForward $(Tunnel-Port $user ($TUNNEL_FWD_OFFSET + $id)) $n" }
        else { Info "    RemoteForward <that user's port: $TUNNEL_BASE + slot*$TUNNEL_SLOT_SIZE + $($TUNNEL_FWD_OFFSET + $id)> $n" }
      }
    }
    'remove' {
      if ($specs.Count -eq 0) {
        if (-not $user) { Die 'usage: vps-setup forward remove <host:port | URL>... [--user <name>]   (or --user <name> alone: all of theirs)' }
        $CFG.FORWARDS_USER = (@(Words $CFG.FORWARDS_USER) | Where-Object { ($_ -split '=', 2)[0] -ne $user }) -join ' '
      }
      foreach ($s in $specs) {
        if ($user) { $pool = @(@(Words $CFG.FORWARDS_USER) | Where-Object { ($_ -split '=', 2)[0] -eq $user } | ForEach-Object { ($_ -split '=', 2)[1] }) }
        else { $pool = @(Words $CFG.FORWARDS) }
        $matched = @(Fwd-Match $s $pool)
        if ($matched.Count -eq 0) {
          if (-not $user) {
            $who = @()
            foreach ($e in @(Words $CFG.FORWARDS_USER)) { $kv = $e -split '=', 2; if (@(Fwd-Match $s @($kv[1])).Count -gt 0) { $who += $kv[0] } }
            if ($who.Count -gt 0) { Die "'$s' is a personal forward of: $($who -join ' ') - remove it with --user <name>." }
          }
          $now = $pool -join ' '
          if (-not $now) { $now = '(none)' }
          Die "No forward matches '$s'. Now: $now   (vps-setup forward list)"
        }
        foreach ($n in $matched) {
          if ($user) { $CFG.FORWARDS_USER = (@(Words $CFG.FORWARDS_USER) | Where-Object { $_ -ne "$user=$n" }) -join ' ' }
          else { $CFG.FORWARDS = (@(Words $CFG.FORWARDS) | Where-Object { $_ -ne $n }) -join ' ' }
          Info "Removing $n$(if ($user) { " (personal, $user)" })"
        }
      }
      Save-Config
      Fwd-Apply
      Ok "Office services - for everyone: $(if ($CFG.FORWARDS) { $CFG.FORWARDS } else { '(none)' }); personal: $(if ($CFG.FORWARDS_USER) { $CFG.FORWARDS_USER } else { '(none)' })"
    }
    'apply' { Fwd-Apply; Fwd-List }
    'list' { Fwd-List }
    '' { Fwd-List }
    default { Die 'usage: vps-setup forward add|remove <host:port | URL>... [--user <name>]  |  forward list|apply' }
  }
}

# ----------------------------------------------------------------------------
# Client side: the ~/.ssh/config block for a user's own computer
# ----------------------------------------------------------------------------
function User-MayRdp([string]$u) { return (Is-Admin $u) -or (In-Group $u $script:RDP_GROUP) }

function Client-Config([string]$u) {
  $ports = @(Words $CFG.SSH_PORTS)
  if ($ports.Count -eq 0) { $ports = @('22') }
  $o = New-Object System.Collections.ArrayList
  $add = { param($l) [void]$o.Add($l) }
  & $add "# ---- ~/.ssh/config on $u's computer --------------------------------------"
  & $add "Host $(Host-Alias)"
  & $add "    HostName $(Server-Ip)"
  & $add "    Port $($ports[0])"
  & $add "    User $u"
  & $add '    # The private key that matches the public key the admin added'
  & $add '    IdentityFile ~/.ssh/id_ed25519'
  & $add '    IdentitiesOnly yes'
  & $add '    # git on the server signs in to GitLab with the key on THIS computer (load it first'
  & $add '    # with: ssh-add). Needs a recent OpenSSH on the server; otherwise make a key there'
  & $add '    # (ssh-keygen) and add it to your GitLab account.'
  & $add '    ForwardAgent yes'
  & $add '    ServerAliveInterval 15'
  & $add '    ServerAliveCountMax 4'
  if ($ports.Count -gt 1) {
    & $add '    # The server listens on several ports: if one is blocked on your network, the next'
    & $add "    # is tried (needs ncat - part of nmap; on Windows use a single 'Port' instead)."
    & $add "    ProxyCommand sh -c 'for p in $($ports -join ' '); do ncat --wait 8 %h `$p && exit 0; done; exit 1'"
    & $add '    # The same through your HTTP proxy:'
    & $add "    # ProxyCommand sh -c 'for p in $($ports -join ' '); do ncat --proxy 127.0.0.1:2080 --proxy-type http --wait 8 %h `$p && exit 0; done; exit 1'"
  } else {
    & $add '    # Only if your network needs a proxy to reach the server:'
    & $add '    # ProxyCommand ncat --proxy 127.0.0.1:2080 --proxy-type http %h %p'
  }
  if ($CFG.GITLAB_HOST -and $CFG.GITLAB_SSH_PORT) {
    & $add '    # Server -> your network: the internal GitLab, while this connection is open'
    $gp = @(Gitlab-Ports)
    for ($i = 0; $i -lt $gp.Count; $i++) { $tp = Tunnel-Port $u $i; if ($tp -gt 0) { & $add "    RemoteForward $tp $(Gitlab-Primary):$($gp[$i])" } }
  }
  $mine = @(Fwd-ForUser $u)
  if ($mine.Count -gt 0) {
    & $add "    # Server -> your network: office services (e.g. http://$($mine[0]) on the server)"
    foreach ($s in $mine) { $tp = Tunnel-Port $u ($TUNNEL_FWD_OFFSET + (Fwd-IdOf $s)); if ((Fwd-IdOf $s) -gt 0 -and $tp -gt 0) { & $add "    RemoteForward $tp $s" } }
  }
  if (User-MayRdp $u) {
    & $add '    # Your desktop: while connected, open Remote Desktop (mstsc) to localhost:13389'
    & $add "    LocalForward 13389 127.0.0.1:$RDP_LOCAL_PORT"
  }
  & $add "# VS Code Remote-SSH: the server runs Windows - in VS Code's settings.json add"
  & $add "#   `"remote.SSH.remotePlatform`": { `"$(Host-Alias)`": `"windows`" }"
  & $add '# ---------------------------------------------------------------------------'
  return ($o -join "`r`n")
}

function Cmd-ClientConfig([string]$u) {
  if (-not $u -or -not (User-Exists $u)) { Die 'usage: vps-setup client-config <user>' }
  Write-Host (Client-Config $u)
}

# ----------------------------------------------------------------------------
# SSH hardening with automatic rollback
# ----------------------------------------------------------------------------
function Render-SshdConfig([int[]]$ports) {
  $kbd = 'KbdInteractiveAuthentication no'
  if ((Sshd-Version) -lt [version]'8.7') { $kbd = 'ChallengeResponseAuthentication no' }   # its older name
  $l = @(
    '# Managed by vps-setup - rewritten on every run. Change ports: vps-setup ssh --ports "22 9011"',
    '# Several ports: if one cannot be opened, sshd keeps serving the others.'
  )
  foreach ($p in $ports) { $l += "Port $p" }
  $l += @(
    'PubkeyAuthentication yes',
    'AuthenticationMethods publickey',
    'PasswordAuthentication no',
    $kbd,
    'PermitEmptyPasswords no',
    "AllowGroups $SSH_GROUP",
    'MaxAuthTries 4',
    'LoginGraceTime 30',
    'ClientAliveInterval 120',
    'ClientAliveCountMax 3',
    '# Local forwards: VS Code Remote-SSH and the RDP tunnel. Remote forwards: each user''s',
    '# tunnels back to the internal GitLab and the office services. GatewayPorts no = they',
    '# bind to loopback only, never to the public interface.',
    'AllowTcpForwarding yes',
    'GatewayPorts no',
    'PermitTunnel no',
    'X11Forwarding no',
    '# Lets developers use their own SSH key for git (GitLab/GitHub) from the server.',
    'AllowAgentForwarding yes',
    'PermitUserEnvironment no',
    'UseDNS no',
    'AuthorizedKeysFile .ssh/authorized_keys',
    'Subsystem sftp sftp-server.exe',
    '',
    '# Windows OpenSSH: administrators'' keys are in ProgramData\ssh\administrators_authorized_keys',
    'Match Group administrators',
    '       AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys'
  )
  return (Lines $l)
}

function Current-SshPorts { # what sshd listens on now
  $ports = @{}
  $names = Process-Names
  foreach ($c in @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue)) {
    if ([string]$names[[int]$c.OwningProcess] -eq 'sshd') { $ports[[int]$c.LocalPort] = 1 }
  }
  return @($ports.Keys | Sort-Object)
}

function Sshd-Check { # syntax and keys of the configuration on disk
  $o = Native-Out (Sshd-Exe) @('-t')
  Log-Raw ($o -join "`r`n")
  if ($script:NATIVE_RC -ne 0) { foreach ($x in $o) { Warn "sshd: $x" }; return $false }
  return $true
}

function Sshd-Effective { # sshd -T, or $null when this OpenSSH can't show it
  $exe = Sshd-Exe
  $o = @(Native-Out $exe @('-T'))
  if ($script:NATIVE_RC -ne 0) { $o = @(Native-Out $exe @('-T', '-C', "user=$($CFG.ADMIN_USER),host=localhost,addr=127.0.0.1")) }
  if ($script:NATIVE_RC -ne 0) { return $null }
  return , $o
}

function Ssh-Verify([int[]]$ports, [switch]$Quiet) { # checks the EFFECTIVE config, not just the file
  $eff = Sshd-Effective
  if ($null -eq $eff) {
    if (-not $Quiet) { Warn 'sshd -T could not show the effective configuration - relying on the syntax check.' }
    return $true
  }
  $problems = @()
  $have = @($eff | Where-Object { $_ -match '^port \d+' } | ForEach-Object { [int](($_ -split ' ')[1]) } | Sort-Object -Unique)
  $want = @($ports | Sort-Object -Unique)
  if (($have -join ' ') -ne ($want -join ' ')) { $problems += "sshd would listen on port(s) '$($have -join ' ')' instead of '$($want -join ' ')'" }
  foreach ($w in @('passwordauthentication no', 'pubkeyauthentication yes', 'authenticationmethods publickey', 'gatewayports no', 'allowtcpforwarding yes')) {
    if ($eff -notcontains $w) {
      $k = ($w -split ' ')[0]
      $problems += "expected '$w', effective: '$(@($eff | Where-Object { $_ -like "$k *" }) -join '; ')'"
    }
  }
  if (-not @($eff | Where-Object { $_ -match "^allowgroups( .*)? $([regex]::Escape($SSH_GROUP))( |$)" })) { $problems += "AllowGroups does not include $SSH_GROUP" }
  if (@($eff | Where-Object { $_ -match '^allowusers ' })) { $problems += 'an AllowUsers line is active' }
  if ($problems.Count -gt 0) {
    if (-not $Quiet) { foreach ($p in $problems) { Warn "sshd: $p" } }
    return $false
  }
  return $true
}

function Ssh-Snapshot([int[]]$old) {
  if (Test-Path -LiteralPath $ROLLBACK_DIR) { Remove-Item -LiteralPath $ROLLBACK_DIR -Recurse -Force }
  New-Dir $ROLLBACK_DIR
  if (Test-Path -LiteralPath $SSHD_CONFIG) { Copy-Item -LiteralPath $SSHD_CONFIG -Destination "$ROLLBACK_DIR\sshd_config" -Force }
  $svc = Get-Service sshd
  $mode = (Get-CimInstance Win32_Service -Filter "Name='sshd'").StartMode
  Write-Text "$ROLLBACK_DIR\service.txt" "$($svc.Status) $mode"
  Write-Text "$ROLLBACK_DIR\old_ports.txt" ($old -join ' ')
  $rules = @(Get-NetFirewallRule -Group $FW_GROUP -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'vps-setup-ssh-*' } | ForEach-Object { $_.Name })
  Write-Text "$ROLLBACK_DIR\fw_rules.txt" ($rules -join ' ')
}

function Ssh-RestoreFiles {
  if (-not (Test-Path -LiteralPath "$ROLLBACK_DIR\sshd_config")) { Warn 'No SSH snapshot to restore.'; return $false }
  Copy-Item -LiteralPath "$ROLLBACK_DIR\sshd_config" -Destination $SSHD_CONFIG -Force
  return $true
}

function Ssh-Restore { # the snapshot, with sshd running the way it ran before
  if (-not (Ssh-RestoreFiles)) { return }
  $st = @((Read-Text "$ROLLBACK_DIR\service.txt").Trim() -split ' ')
  $mode = @{ Auto = 'Automatic'; Manual = 'Manual'; Disabled = 'Disabled' }[$st[-1]]
  if ($st[0] -eq 'Running') { Set-Service sshd -StartupType Automatic; Restart-Service sshd -Force }
  else { Stop-Service sshd -Force -ErrorAction SilentlyContinue }
  if ($mode) { Set-Service sshd -StartupType $mode }
  $before = @(Words (Read-Text "$ROLLBACK_DIR\fw_rules.txt"))
  foreach ($r in @(Get-NetFirewallRule -Group $FW_GROUP -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'vps-setup-ssh-*' })) {
    if ($before -notcontains $r.Name) { Remove-FwRule $r.Name }
  }
  Remove-Item -LiteralPath "$ROLLBACK_DIR\applied_at" -Force -ErrorAction SilentlyContinue
  Log-File 'SSH configuration rolled back'
}

function Schedule-Rollback {
  Cancel-Rollback
  $a = New-ScheduledTaskAction -Execute $WINPS -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$INSTALL_PATH`" _ssh-rollback"
  $t = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes($ROLLBACK_MINUTES)
  $p = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
  $s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
  Register-ScheduledTask -TaskName $ROLLBACK_TASK -TaskPath $TASK_PATH -Action $a -Trigger $t -Principal $p -Settings $s -Force | Out-Null
}
function Cancel-Rollback { Unregister-ScheduledTask -TaskName $ROLLBACK_TASK -TaskPath $TASK_PATH -Confirm:$false -ErrorAction SilentlyContinue }
function Ssh-ChangePending { return (Test-Path -LiteralPath "$ROLLBACK_DIR\applied_at") }

# A public-key login by the admin through the NEW sshd (not from the server itself) proves
# the change works - then it is kept automatically.
function Ssh-LoginSeen {
  if (-not (Ssh-ChangePending)) { return $false }
  try { $since = (Parse-Time (Read-Text "$ROLLBACK_DIR\applied_at").Trim()).ToLocalTime() } catch { return $false }
  $events = @()
  try { $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'OpenSSH/Operational'; StartTime = $since } -ErrorAction Stop) } catch { return $false }
  $re = '(?i)Accepted publickey for (\S+\\)?' + [regex]::Escape($CFG.ADMIN_USER) + ' from (\S+) port'
  foreach ($e in $events) {
    $m = [string]$e.Message
    if (-not $m) { $m = (@($e.Properties | ForEach-Object { [string]$_.Value }) -join ' ') }
    $x = [regex]::Match($m, $re)
    if ($x.Success -and $x.Groups[2].Value -notmatch '^(127\.|::1$)') { return $true }
  }
  return $false
}

function Ssh-Finalize { # keep the new SSH setup: close the old ports, close RDP to the internet, save
  Cancel-Rollback
  $new = @((Read-Text $SSHD_CONFIG) -split "`r?`n" | Where-Object { $_ -match '^Port\s+\d+' } | ForEach-Object { [int](($_ -split '\s+')[1]) })
  foreach ($r in @(Get-NetFirewallRule -Group $FW_GROUP -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'vps-setup-ssh-*' })) {
    if ($new -notcontains [int]($r.Name -replace '^vps-setup-ssh-', '')) { Remove-FwRule $r.Name }
  }
  foreach ($n in @('OpenSSH-Server-In-TCP', 'sshd')) { Disable-NetFirewallRule -Name $n -ErrorAction SilentlyContinue }
  $CFG.SSH_PORTS = $new -join ' '
  Save-Config
  Rdp-ApplyPublic
  if (Gw-Needed) { try { Gw-Apply } catch { Warn "The gateway did not restart: $($_.Exception.Message)" } }
  Remove-Item -LiteralPath "$ROLLBACK_DIR\applied_at" -Force -ErrorAction SilentlyContinue
  Log-File "SSH change confirmed (ports $($new -join ' '))"
}

function Ssh-WaitForLogin([int[]]$ports) {
  $ip = Server-Ip
  $keyfile = "$CRED_DIR\$($CFG.ADMIN_USER).id_ed25519"
  $keyopt = ''
  if (Test-Path -LiteralPath $keyfile) { $keyopt = '-i <saved private key> ' }
  $y = 'Yellow'
  Write-Host ''
  Write-Host '  ---------------------------------------------------------------------------' -ForegroundColor $y
  Write-Host ("   SSH is now key-only, ports {0}, group {1} only." -f ($ports -join ' '), $SSH_GROUP) -ForegroundColor $y
  Write-Host ("   KEEP THIS WINDOW OPEN. From your computer, log in as {0} on any of them:" -f $CFG.ADMIN_USER) -ForegroundColor $y
  Write-Host ''
  Write-Host ("       ssh {0}-p {1} {2}@{3}" -f $keyopt, $ports[0], $CFG.ADMIN_USER, $ip) -ForegroundColor $y
  Write-Host ''
  Write-Host '   The setup continues by itself as soon as that login arrives.' -ForegroundColor $y
  Write-Host "   Your provider's cloud firewall (if any) must allow these TCP ports." -ForegroundColor $y
  Write-Host ("   No login within {0} minutes -> SSH is rolled back automatically." -f $ROLLBACK_MINUTES) -ForegroundColor $y
  if ($CFG.RDP_PUBLIC -ne 'y') { Write-Host '   After the login, RDP is closed to the internet (then: through an SSH tunnel).' -ForegroundColor $y }
  Write-Host '  ---------------------------------------------------------------------------' -ForegroundColor $y
  if ($keyopt) {
    Write-Host ''
    Write-Host "  Private key for $($CFG.ADMIN_USER) (save it on your computer as ~/.ssh/id_ed25519, readable only by you):"
    Write-Host ''
    Write-Host (Read-Text $keyfile)
  }
  Write-Host "  Waiting for the login... (type 'skip' + Enter to stop waiting - it is still kept as soon"
  Write-Host "  as $($CFG.ADMIN_USER) logs in; 'no' rolls back now)"
  $deadline = (Get-Date).AddSeconds($ROLLBACK_MINUTES * 60 - 20)
  $script:LINE_BUF = ''
  while ((Get-Date) -lt $deadline) {
    if (Ssh-LoginSeen) { Ssh-Finalize; Note "SSH: login by $($CFG.ADMIN_USER) confirmed - hardening kept on ports $($ports -join ' ')."; return }
    $ans = Read-LineTimeout 5
    if ($null -ne $ans) {
      switch ((Trim-Text $ans).ToLower()) {
        'skip' { Note "SSH: not confirmed yet - kept automatically once $($CFG.ADMIN_USER) logs in, else rolled back after $ROLLBACK_MINUTES min."; return }
        'no' { Cancel-Rollback; Ssh-Restore; Die 'Rolled back on request - SSH runs as before.' }
      }
    }
  }
  if (Ssh-LoginSeen) { Ssh-Finalize; Note "SSH: login by $($CFG.ADMIN_USER) confirmed - hardening kept."; return }
  Cancel-Rollback
  Ssh-Restore
  Die "No login by $($CFG.ADMIN_USER) through the new SSH setup - rolled back. Fix it, then run: vps-setup ssh"
}

function Ssh-Apply([int[]]$ports) {
  $old = @(Current-SshPorts)
  $new = Render-SshdConfig $ports
  $svc = Get-Service sshd -ErrorAction SilentlyContinue
  if (-not $svc) { Die 'The OpenSSH server is not installed (run: vps-setup setup).' }
  if ((Read-Text $SSHD_CONFIG) -eq $new -and $svc.Status -eq 'Running' -and -not (Ssh-ChangePending) -and (Ssh-Verify $ports -Quiet)) {
    $up = @($ports | Where-Object { Port-Listening $_ })
    if ($up.Count -gt 0) {
      Note "SSH: already hardened, listening on $($up -join ' ') - unchanged."
      foreach ($p in $ports) { Ensure-FwRule "vps-setup-ssh-$p" "vps-setup SSH $p" 'TCP' "$p" }
      Rdp-ApplyPublic
      return
    }
  }
  if (-not @(Keys-Of $CFG.ADMIN_USER).Count) { Die "$($CFG.ADMIN_USER) has no SSH key - add one first (vps-setup add-key $($CFG.ADMIN_USER))." }
  Ssh-Snapshot $old
  foreach ($p in $ports) { Ensure-FwRule "vps-setup-ssh-$p" "vps-setup SSH $p" 'TCP' "$p" }
  if (-not (Test-Path -LiteralPath "$BACKUP_DIR\sshd_config.original") -and (Test-Path -LiteralPath $SSHD_CONFIG)) {
    New-Dir $BACKUP_DIR
    Copy-Item -LiteralPath $SSHD_CONFIG -Destination "$BACKUP_DIR\sshd_config.original"
  }
  Write-Text $SSHD_CONFIG $new
  if (-not (Sshd-Check) -or -not (Ssh-Verify $ports)) {
    [void](Ssh-RestoreFiles)
    Die 'The SSH configuration did not validate - nothing was changed (see the messages above).'
  }
  Schedule-Rollback
  if ($env:SSH_CONNECTION) {
    Warn 'You are connected over SSH: restarting sshd ends this connection. Log in again (on the new port) -'
    Warn "the change is then kept by itself (or run: vps-setup confirm). No login in $ROLLBACK_MINUTES minutes -> rolled back."
  }
  Set-Service sshd -StartupType Automatic
  Restart-Service sshd -Force
  Write-Text "$ROLLBACK_DIR\applied_at" ((Get-Date).ToUniversalTime().ToString('o'))
  $up = @()
  $down = @()
  foreach ($p in $ports) { if (Wait-Port $p) { $up += $p } else { $down += $p } }
  if ($up.Count -eq 0) {
    Cancel-Rollback
    Ssh-Restore
    Die "sshd could not open any of the ports $($ports -join ' ') - rolled back to the previous SSH setup."
  }
  if ($down.Count -gt 0) { Note "SSH: port(s) $($down -join ' ') could not be opened on the server - continuing with $($up -join ' ') (see the OpenSSH/Operational event log)." }
  Note "SSH listening on: $($up -join ' ')"
  Ssh-WaitForLogin $up
}

# ----------------------------------------------------------------------------
# Remote desktop: Windows' own RDP, a desktop of their own for every user. It is closed to
# the internet once SSH works - reach it through an SSH tunnel (LocalForward 13389).
# ----------------------------------------------------------------------------
function Tunnel-HintRdp([string]$u) {
  Info "RDP for ${u}: connected with the client-config block (LocalForward 13389), open"
  Info '  Remote Desktop (mstsc) to localhost:13389 and log in with the Windows username + password.'
  Info "  Without that block: ssh -N -L 13389:127.0.0.1:$RDP_LOCAL_PORT $(Host-Alias)"
}

function Cmd-Rdp([string[]]$a) {
  $action = ''
  if ($a.Count -gt 0) { $action = $a[0] }
  switch ($action) {
    'enable' {
      if (Is-ServerCore) { Die 'Server Core has no desktop for RDP.' }
      Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' 'fDenyTSConnections' 0
      Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' 'UserAuthentication' 1
      Set-Service TermService -StartupType Automatic
      Start-Service TermService -ErrorAction SilentlyContinue
      foreach ($u in @(Server-Users)) { if (-not (Is-Admin $u)) { Add-ToGroup $u $script:RDP_GROUP } }
      if ($a -contains '--multi') {
        $f = Get-WindowsFeature -Name RDS-RD-Server
        if (-not $f.Installed) {
          $r = Install-WindowsFeature -Name RDS-RD-Server
          Note 'RDS Session Host installed - more than 2 desktops at a time. Licensing: a 120-day grace period,'
          Note '  then RDS CALs and a license server are needed (Microsoft licensing terms).'
          if ([string]$r.RestartNeeded -eq 'Yes') { Note '  It is active after a reboot (Restart-Computer).' }
        }
      }
      $CFG.RDP_ENABLED = 'y'
      Save-Config
      if ($CFG.SETUP_DONE -eq 'y' -and -not (Ssh-ChangePending)) { Rdp-ApplyPublic }
      Note 'RDP for every user: each gets their own desktop (a disconnected one keeps running).'
      if (-not (Get-WindowsFeature -Name RDS-RD-Server).Installed) { Note '  Without the RDS role, at most 2 desktops at a time (more: vps-setup rdp enable --multi).' }
      Tunnel-HintRdp '<user>'
    }
    'disable' {
      foreach ($u in @(Server-Users)) { if (-not (Is-Admin $u)) { Remove-FromGroup $u $script:RDP_GROUP } }
      $CFG.RDP_ENABLED = 'n'
      Save-Config
      if ($a -contains '--off') {
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' 'fDenyTSConnections' 1
        Warn 'RDP is now off for everyone, administrators included (back: vps-setup rdp enable).'
      }
      Ok 'RDP disabled for developers (administrators keep it, through an SSH tunnel).'
    }
    default { Die 'usage: vps-setup rdp enable [--multi] | disable [--off]' }
  }
}


# ----------------------------------------------------------------------------
# Setup
# ----------------------------------------------------------------------------
# Try-Step <title> <scriptblock> - a failure is recorded for the report and the setup
# continues with the next step.
function Try-Step([string]$StepTitle, [scriptblock]$StepBody) {
  Step $StepTitle
  try {
    $null = & $StepBody
    [void]$script:RESULTS.Add("ok`t$StepTitle")
  } catch {
    Show-Error $_
    [void]$script:RESULTS.Add("FAILED`t$StepTitle")
    Warn "'$StepTitle' failed - continuing with the next step (details: $LOG_FILE)."
  }
  Load-Config
}
function Skip-Step([string]$t, [string]$why) { [void]$script:RESULTS.Add("skipped`t$t - $why"); Warn "Skipped '$t': $why" }
function Step-Ok([string]$t) { return @($script:RESULTS | Where-Object { $_ -eq "ok`t$t" }).Count -gt 0 }

function Collect-Answers {
  Step '1/5  Admin account (Administrators group)'
  Info 'The admin is a Windows administrator. Developers have no admin rights. Nothing is installed'
  Info 'for them: everyone installs their own tools (Claude Code, Git, Node...) into their profile,'
  Info 'which needs no admin rights. System-wide programs: the admin installs them.'
  $def = $CFG.ADMIN_USER
  if (-not $def -and $env:USERNAME -and $RESERVED_NAMES -notcontains $env:USERNAME.ToLower()) { $def = $env:USERNAME.ToLower() }
  $CFG.ADMIN_USER = Prompt-Value 'Admin username' $def 'Valid-Username'
  Collect-Keys $CFG.ADMIN_USER
  $script:ADMIN_KEYS = $script:KEYS_OUT
  $script:ADMIN_PASSWORD = ''
  $script:ADMIN_PW_GENERATED = 'n'
  $replace = 'y'
  if (User-HasPassword $CFG.ADMIN_USER) { $replace = Prompt-YN "$($CFG.ADMIN_USER) already has a password. Replace it?" 'n' }
  if ($replace -eq 'y') {
    $script:ADMIN_PASSWORD = Prompt-Password "Password for $($CFG.ADMIN_USER) (Windows logon, RDP)"
    $script:ADMIN_PW_GENERATED = $script:PW_GENERATED
  }

  Step '2/5  Developer accounts (no admin rights; VS Code Remote-SSH + Claude Code)'
  $script:DEV_USERS = @()
  $script:DEV_KEYS = @{}
  while ($true) {
    $name = Prompt-Value 'Developer username (empty = done)' '' 'Accept-Any'
    if (-not $name) { break }
    if (-not (Valid-Username $name)) { continue }
    if ($name -eq $CFG.ADMIN_USER -or $script:DEV_USERS -contains $name) { Warn 'Already listed.'; continue }
    Collect-Keys $name
    $script:DEV_USERS += $name
    $script:DEV_KEYS[$name] = $script:KEYS_OUT
  }

  Step '3/5  SSH and server'
  $existing = @(Current-SshPorts) -join ' '
  $def = $CFG.SSH_PORTS
  if (-not $def) { $def = $existing }
  if (-not $def) { $def = '22' }
  Info 'Several ports are allowed: if one is blocked on a network, clients use the next one.'
  $CFG.SSH_PORTS = (@(Words (Prompt-Value 'SSH ports (space-separated)' $def 'Valid-SshPorts')) | ForEach-Object { [int]$_ }) -join ' '
  $CFG.TRUSTED_IPS = Prompt-Value 'IPs/CIDRs the SSH guard must never block, e.g. your office (space-separated, empty = none)' $CFG.TRUSTED_IPS 'Valid-IpList'

  $script:NEW_HOSTNAME = Prompt-Value 'Hostname' $env:COMPUTERNAME.ToLower() 'Valid-Hostname'
  $script:TIMEZONE = Prompt-Value 'Timezone (Windows ID)' (Get-TimeZone).Id 'Valid-Timezone'
  $d = $CFG.OPEN_WEB; if (-not $d) { $d = 'n' }
  $CFG.OPEN_WEB = Prompt-YN 'Open ports 80/443 to the internet (only if this server hosts a website)?' $d
  $d = $CFG.AUTO_REBOOT; if (-not $d) { $d = 'n' }
  $CFG.AUTO_REBOOT = Prompt-YN 'Reboot automatically at 04:00 when a security update needs it (stops running sessions)?' $d
  $d = 'n'
  if ($CFG.RDP_PUBLIC -eq 'y') { $d = 'y' }
  $close = Prompt-YN 'Close RDP (3389) to the internet once SSH works (then RDP only through an SSH tunnel)?' $(if ($d -eq 'y') { 'n' } else { 'y' })
  $CFG.RDP_PUBLIC = $(if ($close -eq 'y') { 'n' } else { 'y' })
  $script:FW_RESET = 'n'
  $others = @(Other-InboundRules)
  if ($others.Count -gt 0) {
    Warn 'The firewall already lets in other connections:'
    $others | Select-Object -First 40 | ForEach-Object { Write-Host "        $($_.DisplayName)" }
    if ($others.Count -gt 40) { Write-Host "        ... and $($others.Count - 40) more" }
    $script:FW_RESET = Prompt-YN 'Disable them and keep only what this setup needs (ping and core networking stay)?' 'y'
  }

  Step '4/5  Internal GitLab and office services'
  Info 'Internal GitLab: reached through the developers'' SSH connections; on the server it then'
  Info 'works like on your PC (git@<host>:..., https://<host>). Any domain works - a local one'
  Info "(gitlab.local) or a global one (gitlab.company.com). '-' clears a value."
  $CFG.GITLAB_HOST = Prompt-Value 'GitLab hostname(s) as your PCs know them, main one first (empty = none)' $CFG.GITLAB_HOST 'Valid-GitlabHosts'
  if ($CFG.GITLAB_HOST) {
    $d = $CFG.GITLAB_SSH_PORT; if (-not $d) { $d = '22' }
    $CFG.GITLAB_SSH_PORT = [string][int](Prompt-Value 'GitLab SSH port (inside your network)' $d 'Valid-PortNumber')
    $d = $CFG.GITLAB_PORTS; if (-not $d) { $d = '80 443' }
    $CFG.GITLAB_PORTS = Prompt-Value 'Other GitLab ports to reach (web 80/443, registry...; space-separated, empty = none)' $d 'Valid-PortListOrEmpty'
    $pub = Public-Ipv4Of (Gitlab-Primary)
    if ($pub -and -not (Is-PrivateIpv4 $pub)) {
      Info "$(Gitlab-Primary) also resolves on the internet ($pub)."
      $d = $CFG.GITLAB_DIRECT; if (-not $d) { $d = 'y' }
      $CFG.GITLAB_DIRECT = Prompt-YN "When no developer tunnel is up, connect to $pub directly?" $d
    } else {
      if ($pub) { Info "$(Gitlab-Primary) resolves to a private address ($pub) - only reachable through the tunnels." }
      $CFG.GITLAB_DIRECT = 'n'
    }
  } else {
    $CFG.GITLAB_SSH_PORT = ''; $CFG.GITLAB_PORTS = ''; $CFG.GITLAB_DIRECT = ''
  }
  Info 'Other office services (a backend, its API docs, a database...) work on the server the same'
  Info 'way, e.g. http://192.168.2.212:8100/docs. Later: vps-setup forward add <host:port>.'
  $CFG.FORWARDS = Fwd-Normalize (Prompt-Value 'Office services to reach (host:port or URL, space-separated, empty = none)' $CFG.FORWARDS 'Valid-ForwardList')

  Step '5/5  Remote desktop (optional - VS Code Remote-SSH needs none; can be enabled later)'
  $d = $CFG.RDP_ENABLED; if (-not $d) { $d = 'n' }
  $CFG.RDP_ENABLED = Prompt-YN 'An RDP desktop for every developer now (administrators always have one; through an SSH tunnel)?' $d

  Step 'Plan'
  Info "Admin:               $($CFG.ADMIN_USER)"
  Info "Developers:          $(if ($script:DEV_USERS.Count) { $script:DEV_USERS -join ' ' } else { '(none)' })"
  Info "SSH:                 ports $($CFG.SSH_PORTS), keys only, group $SSH_GROUP only"
  Info "Firewall:            SSH$(if ($CFG.OPEN_WEB -eq 'y') { ' + 80/443' }) inbound$(if ($CFG.RDP_PUBLIC -eq 'y') { ' + RDP' }), everything else blocked"
  Info "Hostname/timezone:   $($script:NEW_HOSTNAME) / $($script:TIMEZONE)   Auto-reboot: $($CFG.AUTO_REBOOT)"
  if ($CFG.GITLAB_HOST) { Info "Internal GitLab:     $($CFG.GITLAB_HOST) - ports $((Gitlab-Ports) -join ' '), through the users' SSH connections" }
  else { Info 'Internal GitLab:     (none)' }
  Info "Office services:     $(if ($CFG.FORWARDS) { $CFG.FORWARDS } else { '(none)' })"
  Info "RDP for developers:  $($CFG.RDP_ENABLED)"
  Info 'Installed software:  none - only Windows Server features (OpenSSH, Firewall, Remote Desktop)'
  $others = @(Human-Users | Where-Object { $_ -ne $CFG.ADMIN_USER -and $script:DEV_USERS -notcontains $_ -and -not (In-Group $_ $SSH_GROUP) })
  if ($others.Count -gt 0) { Warn "These existing accounts will NOT be able to log in over SSH: $($others -join ' ') (add later: vps-setup add-user <name>)" }
}

function Step-Users {
  Ensure-Group $SSH_GROUP 'May log in over SSH (vps-setup)'
  Ensure-Group $DEV_GROUP 'Developers - no admin rights (vps-setup)'
  Ensure-User $CFG.ADMIN_USER 'admin' $script:ADMIN_PASSWORD $script:ADMIN_PW_GENERATED
  Apply-Keys $CFG.ADMIN_USER $script:ADMIN_KEYS
  if (-not @(Keys-Of $CFG.ADMIN_USER).Count) { Die "$($CFG.ADMIN_USER) has no SSH key." }
  foreach ($u in $script:DEV_USERS) { Ensure-User $u 'dev'; Apply-Keys $u $script:DEV_KEYS[$u] }
  Note "Users: admin $($CFG.ADMIN_USER); developers $(if ($script:DEV_USERS.Count) { $script:DEV_USERS -join ' ' } else { '(none)' })"
}

function Step-Firewall { Apply-Firewall @(Words (Uniq-Words (Current-SshPorts) $CFG.SSH_PORTS) | ForEach-Object { [int]$_ }) }

function Users-Table { # one row per human account: what it has right now
  $rows = @(('{0,-16} {1,-6} {2,-5} {3,-9} {4,-5} {5,-5} {6}' -f 'USER', 'ROLE', 'SSH', 'PASSWORD', 'KEYS', 'RDP', 'CLAUDE'))
  foreach ($u in @(Human-Users)) {
    $role = '-'
    if (Is-Admin $u) { $role = 'admin' } elseif (In-Group $u $DEV_GROUP) { $role = 'dev' }
    $pw = 'none'; if (User-HasPassword $u) { $pw = 'set' }
    $ssh = 'no'; if (In-Group $u $SSH_GROUP) { $ssh = 'yes' }
    $rdp = 'no'; if (User-MayRdp $u) { $rdp = 'yes' }
    $h = Home-Of $u
    $cl = 'no'; if ($h -and (Claude-Installed $h)) { $cl = 'yes' }
    $rows += ('{0,-16} {1,-6} {2,-5} {3,-9} {4,-5} {5,-5} {6}' -f $u, $role, $ssh, $pw, @(Keys-Of $u).Count, $rdp, $cl)
  }
  return $rows
}

function Services-Summary {
  $l = @()
  $p = $CFG.SSH_PORTS; if (-not $p) { $p = '22' }
  $l += "SSH ports:          $p"
  $g = '(none)'; if ($CFG.GITLAB_HOST) { $g = "$($CFG.GITLAB_HOST) - ports $((Gitlab-Ports) -join ' ')" }
  $l += "Internal GitLab:    $g"
  $l += "Office services:    $(if ($CFG.FORWARDS) { $CFG.FORWARDS } else { '(none)' })"
  $l += "Personal services:  $(if ($CFG.FORWARDS_USER) { $CFG.FORWARDS_USER } else { '(none)' })"
  $r = 'administrators (developers: off)'
  if ($CFG.RDP_ENABLED -eq 'y') { $r = 'every user' }
  if ($CFG.RDP_PUBLIC -eq 'y') { $r += ', open to the internet' } else { $r += ', through an SSH tunnel only' }
  $l += "RDP desktops:       $r"
  return $l
}

function Connect-Help {
  $l = @()
  $l += "Connect from each computer (VS Code: Remote-SSH -> Connect to Host -> $(Host-Alias)):"
  $l += '  - First time on the server, every user installs Claude Code into their profile (no admin'
  $l += '    rights): Git for Windows (its installer works for one user), then in PowerShell:'
  $l += '        irm https://claude.ai/install.ps1 | iex'
  $l += '    and runs: claude   (log in with your own account)'
  $l += '  - Long tasks: a Windows SSH session ends when you disconnect - run them in your RDP'
  $l += '    desktop (a disconnected desktop keeps running; connect again to pick it up).'
  if ($CFG.GITLAB_HOST) {
    $l += "  - On the server: git clone git@$(Gitlab-Primary):<group>/<project>.git, https://$(Gitlab-Primary), ... work as on"
    $l += "    your PC while at least one developer is connected with the config below$(if ($CFG.GITLAB_DIRECT -eq 'y') { ' (or directly, when nobody is)' })."
    $l += '    With your own Git, use Windows'' OpenSSH (it has the GitLab mapping), once:'
    $l += '        git config --global core.sshCommand C:/Windows/System32/OpenSSH/ssh.exe'
  }
  if ($CFG.FORWARDS) { $l += "  - Office services work on the server the same way: $($CFG.FORWARDS)" }
  $l += '  - Desktops: vps-setup rdp enable   |   Remote Desktop (mstsc) to localhost:13389 while connected'
  $l += '  - Manage: vps-setup help   |   status: vps-setup status'
  return $l
}

function Write-Report([string]$what = '') { # the whole report, from the current state
  $l = New-Object System.Collections.ArrayList
  $head = "vps-setup $SCRIPT_VERSION - $(Host-Alias), updated $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
  if ($what) { $head += " (after: $what)" }
  [void]$l.Add($head)
  $last = Read-Text $LAST_SETUP
  if ($last.Trim()) { [void]$l.Add(''); [void]$l.Add($last.TrimEnd()) }
  [void]$l.Add(''); [void]$l.Add('Users now:')
  foreach ($r in @(Users-Table)) { [void]$l.Add("  $r") }
  [void]$l.Add(''); [void]$l.Add('Services now:')
  foreach ($r in @(Services-Summary)) { [void]$l.Add("  $r") }
  [void]$l.Add('')
  foreach ($r in @(Connect-Help)) { [void]$l.Add($r) }
  [void]$l.Add(''); [void]$l.Add("Each user has a sheet with their own config: $USERS_DIR\<user>.txt")
  foreach ($u in @(Server-Users)) { [void]$l.Add(''); [void]$l.Add((Client-Config $u)) }
  if (Reboot-Pending) { [void]$l.Add(''); [void]$l.Add('A reboot is required to finish the updates / the rename: Restart-Computer') }
  Write-Text "$REPORT_FILE.new" (($l -join "`r`n") + "`r`n")
  Move-Item -LiteralPath "$REPORT_FILE.new" -Destination $REPORT_FILE -Force
}

function Latest-Creds([string]$u) { # the newest value of each credential vps-setup made
  $f = "$CRED_DIR\$u.txt"
  if (-not (Test-Path -LiteralPath $f)) { return @() }
  $order = @(); $val = @{}; $at = @{}
  foreach ($line in @(Get-Content -LiteralPath $f)) {
    if ($line.Length -lt 38) { continue }   # "YYYY-MM-DD HH:MM:SS  <what, 16 wide> <value>"
    $w = $line.Substring(21, 16).Trim()
    if ($order -notcontains $w) { $order += $w }
    $val[$w] = $line.Substring(38)
    $at[$w] = $line.Substring(0, 19)
  }
  return @($order | ForEach-Object { '  {0,-16} {1}   ({2})' -f $_, $val[$_], $at[$_] })
}

function Write-UserSheet([string]$u) { # everything one user needs - administrators only
  $h = Home-Of $u
  $role = 'developer'
  if (Is-Admin $u) { $role = 'admin (Administrators)' }
  $l = New-Object System.Collections.ArrayList
  [void]$l.Add("$u on $(Host-Alias) - updated $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
  [void]$l.Add("Hand this to $u privately (it can hold passwords), then delete the credentials")
  [void]$l.Add("part from $CRED_DIR once they have changed them.")
  [void]$l.Add('')
  [void]$l.Add("Account:          $u, $role, profile $h")
  [void]$l.Add("Windows password: $(if (User-HasPassword $u) { 'set (RDP and the lock screen - never SSH); change it with Ctrl+Alt+End in RDP' } else { 'none' })")
  [void]$l.Add("SSH keys:         $(@(Keys-Of $u).Count)")
  [void]$l.Add("RDP desktop:      $(if (User-MayRdp $u) { 'yes - Remote Desktop to localhost:13389 while connected' } else { 'no' })")
  [void]$l.Add("Claude Code:      $(if ($h -and (Claude-Installed $h)) { 'installed' } else { 'not yet - see below' })")
  $mine = @(Fwd-ForUser $u)
  [void]$l.Add("Office services:  $(if ($mine.Count) { $mine -join ' ' } else { '(none)' })")
  $creds = @(Latest-Creds $u)
  if ($creds.Count -gt 0) { [void]$l.Add(''); [void]$l.Add('Credentials made by vps-setup (newest of each):'); foreach ($c in $creds) { [void]$l.Add($c) } }
  [void]$l.Add('')
  foreach ($r in @(Connect-Help)) { [void]$l.Add($r) }
  [void]$l.Add('')
  [void]$l.Add((Client-Config $u))
  Write-Text "$USERS_DIR\$u.txt.new" (($l -join "`r`n") + "`r`n")
  Move-Item -LiteralPath "$USERS_DIR\$u.txt.new" -Destination "$USERS_DIR\$u.txt" -Force
}

function Refresh-Files([string]$what = '') { # the report and every user sheet
  Write-Report $what
  New-Dir $USERS_DIR
  $users = @(Server-Users)
  foreach ($u in $users) { Write-UserSheet $u }
  foreach ($f in @(Get-ChildItem -LiteralPath $USERS_DIR -Filter '*.txt' -ErrorAction SilentlyContinue)) {
    if ($users -notcontains $f.BaseName) { Remove-Item -LiteralPath $f.FullName -Force }   # removed users
  }
}

function Print-Report {
  $l = @("Last full setup: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')", '', 'Steps:')
  foreach ($row in $script:RESULTS) { $f = $row -split "`t", 2; $l += ('  {0,-8} {1}' -f $f[0].ToUpper(), $f[1]) }
  $notes = Read-Text $RUN_NOTES
  if ($notes.Trim()) { $l += ''; $l += 'Details:'; foreach ($n in @($notes -split "`r?`n" | Where-Object { $_ })) { $l += "  - $n" } }
  Write-Text $LAST_SETUP (($l -join "`r`n") + "`r`n")
  Refresh-Files 'setup'

  Step 'Result'
  $failed = 0
  foreach ($row in $script:RESULTS) {
    $f = $row -split "`t", 2
    $color = 'Yellow'
    if ($f[0] -eq 'ok') { $color = 'Green' } elseif ($f[0] -eq 'FAILED') { $color = 'Red'; $failed++ }
    Write-Host '    ' -NoNewline; Write-Host ('{0,-8}' -f $f[0].ToUpper()) -ForegroundColor $color -NoNewline; Write-Host " $($f[1])"
  }
  $show = $false
  Write-Host ''
  foreach ($line in @((Read-Text $REPORT_FILE) -split "`r?`n")) {
    if ($line -like 'Details:*' -or $line -like 'Connect from*') { $show = $true }
    if ($show) { Write-Host $line }
  }
  Print-Credentials
  Write-Host ''
  Info "This report (without credentials): $REPORT_FILE     Full log: $LOG_FILE"
  Info "One sheet per user (their config + any new passwords; administrators only): $USERS_DIR\<user>.txt"
  if (Reboot-Pending) { Warn 'A reboot is needed to finish (rename, Windows features or updates): Restart-Computer' }
  if ($failed -gt 0) {
    Warn "$failed step(s) failed - fix the cause and run 'vps-setup setup' again (it is safe to re-run)."
    $script:EXIT_CODE = 1
  }
}

function Cmd-Setup {
  Need-Tty
  Check-OS
  if ($env:SSH_CONNECTION) {
    Warn 'You are running this over SSH: the SSH step restarts sshd, which ends this session, and a'
    Warn 'dropped connection stops the setup half-way. Run it from an RDP session or the console.'
    if ((Prompt-YN 'Continue over SSH anyway?' 'n') -ne 'y') { return }
  }
  Install-Self
  Write-Host ''
  Write-Host "Claude Code dev server setup - vps-setup $SCRIPT_VERSION" -ForegroundColor Cyan
  $os = Get-CimInstance Win32_OperatingSystem
  Info ('{0} (build {1}), {2} CPU, {3:N1} GB RAM' -f $os.Caption, $os.BuildNumber, [Environment]::ProcessorCount, ($os.TotalVisibleMemorySize / 1MB))
  if ($CFG.SETUP_DONE -eq 'y') {
    if ((Prompt-YN "This server is already set up (admin: $($CFG.ADMIN_USER)). Run the setup again and update everything in place?" 'n') -ne 'y') { return }
  }
  Collect-Answers
  if ((Prompt-YN 'Apply this now? (every step runs; failures are reported at the end)' 'y') -ne 'y') { Die 'Aborted - nothing was changed.' }
  Log-File "setup started by $env:USERNAME"
  $script:IN_SETUP = $true
  Save-Config

  Try-Step 'Hostname and timezone' { Apply-HostnameTimezone }
  Try-Step 'OpenSSH server' { Install-OpenSsh }
  if (Step-Ok 'OpenSSH server') { Try-Step 'Users and SSH keys' { Step-Users } }
  else { Skip-Step 'Users and SSH keys' 'the OpenSSH step failed' }
  Try-Step 'Shell defaults (PowerShell profile)' { Apply-ShellDefaults }
  Try-Step 'System hardening and tuning' { Apply-SystemTuning }
  Try-Step 'Fair resource sharing between users' { Apply-FairShare }
  Try-Step 'Firewall' { Step-Firewall }
  Try-Step 'SSH brute-force guard' { Apply-Ban }
  if ($CFG.GITLAB_HOST) { Try-Step "Internal GitLab ($($CFG.GITLAB_HOST))" { Gitlab-Apply } }
  elseif (Get-Service $GW_SERVICE -ErrorAction SilentlyContinue) {
    if (@(Fwd-Targets).Count -eq 0) { Try-Step 'Remove the gateway' { Gw-Remove } }
  }
  if (@(Fwd-Targets).Count -gt 0) {
    $what = $CFG.FORWARDS
    if (-not $what) { $what = 'personal only' }
    Try-Step "Office services ($what)" { Fwd-Apply }
  }
  if ($CFG.RDP_ENABLED -eq 'y') { Try-Step 'RDP desktops' { Cmd-Rdp @('enable') } }

  if ((Step-Ok 'Users and SSH keys') -and (Step-Ok 'Firewall')) {
    Try-Step "SSH hardening (ports $($CFG.SSH_PORTS), auto-rollback)" { Ssh-Apply @(Words $CFG.SSH_PORTS | ForEach-Object { [int]$_ }) }
  } else {
    Skip-Step 'SSH hardening' 'users or firewall step failed - SSH left unchanged so you are not locked out'
  }
  $CFG.SETUP_DONE = 'y'
  Save-Config
  Print-Report
}

# ----------------------------------------------------------------------------
# Other commands
# ----------------------------------------------------------------------------
function Cmd-AddUser([string[]]$a) {
  Need-Tty
  $u = ''; $role = 'dev'; $fwds = ''; $fwdsSet = $false; $rdp = ''
  for ($i = 0; $i -lt $a.Count; $i++) {
    $x = $a[$i]
    switch -Wildcard ($x) {   # -Wildcard runs every matching case: each one ends with break
      '--admin' { $role = 'admin'; break }
      '--rdp' { $rdp = 'y'; break }
      '--forward' { $i++; if ($i -lt $a.Count) { $fwds = $a[$i] }; $fwdsSet = $true; break }
      '--forward=*' { $fwds = $x.Substring(10); $fwdsSet = $true; break }
      '-*' { Die "Unknown option $x" }
      default { $u = $x }
    }
  }
  if (-not $u) { $u = Prompt-Value 'Username' '' 'Valid-Username' }
  if (-not (Valid-Username $u)) { $script:EXIT_CODE = 1; return }
  if ($role -eq 'dev' -and -not $rdp) {
    $d = 'n'; if ($CFG.RDP_ENABLED -eq 'y') { $d = 'y' }
    $rdp = Prompt-YN "An RDP desktop for ${u}?" $d
  }
  if ($fwdsSet) { if (-not (Valid-ForwardList $fwds)) { $script:EXIT_CODE = 1; return } }
  else { $fwds = Prompt-Value "Office services only for $u (host:port or URL; empty = none; for everyone: vps-setup forward add)" '' 'Valid-ForwardList' }
  Ensure-Group $SSH_GROUP 'May log in over SSH (vps-setup)'
  Ensure-Group $DEV_GROUP 'Developers - no admin rights (vps-setup)'
  Collect-Keys $u
  $keys = $script:KEYS_OUT
  $pw = ''; $gen = 'n'
  if ($role -eq 'admin' -and -not (User-Exists $u)) { $pw = Prompt-Password "Password for $u (Windows logon, RDP)"; $gen = $script:PW_GENERATED }
  Ensure-User $u $role $pw $gen
  Apply-Keys $u $keys
  if ($role -eq 'dev' -and $rdp -eq 'y') { Add-ToGroup $u $script:RDP_GROUP }
  if ($fwds -or (Gw-Needed)) {
    foreach ($n in @(Words (Fwd-Normalize $fwds))) { if (@(Words $CFG.FORWARDS) -notcontains $n) { $CFG.FORWARDS_USER = Uniq-Words $CFG.FORWARDS_USER "$u=$n" } }
    Save-Config
    try { Gw-Apply } catch { Show-Error $_; Warn 'The gateway failed - retry: vps-setup forward apply' }   # the new user's tunnels
  }
  Ok "$u added as $role."
  Write-Host ''
  Write-Host (Client-Config $u)
  Print-Credentials
}

function Cmd-RemoveUser([string]$u) {
  Need-Tty
  if (-not $u) { Die 'usage: vps-setup remove-user <user>' }
  if (-not (User-Exists $u)) { Die "No user '$u'." }
  if (-not (Is-HumanUser $u)) { Die "'$u' is a system account." }
  if ($u -eq $CFG.ADMIN_USER) { Die "$u is the primary admin of this setup." }
  if ($u -ieq $env:USERNAME) { Die "You can't remove yourself." }
  if ((Prompt-Value "Type '$u' again to delete this user" '' 'Accept-Any') -ne $u) { Die 'Aborted.' }
  $keep = Prompt-YN "Archive $u's profile folder to $ARCHIVE_DIR first?" 'y'
  $sid = Sid-Of $u
  $h = Home-Of $u
  # sign them out (RDP desktops) and stop everything they run
  $procs = @(Get-Process -IncludeUserName -ErrorAction SilentlyContinue | Where-Object { $_.UserName -and ($_.UserName -split '\\')[-1] -ieq $u })
  foreach ($s in @($procs | ForEach-Object { $_.SessionId } | Sort-Object -Unique | Where-Object { $_ -gt 0 })) { [void](Native-Out 'logoff.exe' @("$s")) }
  Start-Sleep -Seconds 2
  foreach ($p in $procs) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Seconds 1
  if ($keep -eq 'y' -and $h -and (Test-Path -LiteralPath $h)) {
    New-Dir $ARCHIVE_DIR
    $arc = "$ARCHIVE_DIR\$u-$(Get-Date -Format 'yyyyMMdd-HHmmss').tar.gz"
    if (Run-Soft -Desc "Archiving $h" -Exe 'tar.exe' -ArgList @('-czf', $arc, '-C', (Split-Path $h), (Split-Path $h -Leaf)) -OkCodes @(0, 1)) { Info "Archived to $arc." }
    else { if ((Prompt-YN 'The archive is incomplete. Delete the user anyway?' 'n') -ne 'y') { Die 'Aborted - nothing was deleted.' } }
  }
  Remove-AdminKeys $u
  Remove-LocalUser -Name $u
  Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object { $_.SID -eq $sid } | Remove-CimInstance -ErrorAction SilentlyContinue
  if ($h -and (Test-Path -LiteralPath $h)) { Remove-Item -LiteralPath $h -Recurse -Force -ErrorAction SilentlyContinue }
  Remove-Item -Path "$CRED_DIR\$u.*" -Force -ErrorAction SilentlyContinue
  Free-Slot $u
  $CFG.FORWARDS_USER = (@(Words $CFG.FORWARDS_USER) | Where-Object { ($_ -split '=', 2)[0] -ne $u }) -join ' '
  Save-Config
  if (Gw-Needed) { try { Gw-Apply } catch { Show-Error $_; Warn 'Could not update the gateway - run: vps-setup forward apply' } }
  Ok "Removed $u."
}

function Cmd-AddKey([string]$u) {
  Need-Tty
  if (-not $u -or -not (User-Exists $u)) { Die 'usage: vps-setup add-key <existing user>' }
  Collect-Keys $u -RequireNew
  Apply-Keys $u $script:KEYS_OUT
  Ok "Key added for $u."
  Print-Credentials
}

function Cmd-Password([string]$u) {
  Need-Tty
  if (-not $u) { Die 'usage: vps-setup password <user>' }
  if (-not (User-Exists $u)) { Die "No user '$u'." }
  if (-not (Is-HumanUser $u)) { Die "'$u' is a system account." }
  $pw = Prompt-Password "New password for $u"
  Set-UserPassword $u $pw $script:PW_GENERATED
  Ok "Password set for $u (Windows logon and RDP - SSH stays key-only). In RDP they change it with Ctrl+Alt+End."
  Print-Credentials
}

function Cmd-Ssh([string[]]$a) {
  Need-Tty
  $ports = ''
  for ($i = 0; $i -lt $a.Count; $i++) {
    if ($a[$i] -eq '--ports' -or $a[$i] -eq '--port') { $i++; if ($i -ge $a.Count) { Die "$($a[$i - 1]) needs a value" }; $ports = $a[$i] }
    else { Die 'usage: vps-setup ssh [--ports "22 9011"]' }
  }
  if (-not $CFG.ADMIN_USER) { Die 'Run the setup first.' }
  if (-not $ports) { $def = $CFG.SSH_PORTS; if (-not $def) { $def = '22' }; $ports = Prompt-Value 'SSH ports (space-separated)' $def 'Valid-SshPorts' }
  if (-not (Valid-SshPorts $ports)) { $script:EXIT_CODE = 1; return }
  Ssh-Apply @(Words $ports | ForEach-Object { [int]$_ })
  Print-Credentials
}

function Cmd-Gitlab([string[]]$a) {
  $x = ''
  if ($a.Count -gt 0) { $x = $a[0] }
  switch ($x) {
    'disable' { Gitlab-Disable }
    { @('', 'apply') -contains $_ } {
      if (-not $CFG.GITLAB_HOST) { Die "No GitLab configured - run 'vps-setup setup' or set GITLAB_HOST/GITLAB_SSH_PORT/GITLAB_PORTS in $CONF_FILE." }
      Gitlab-Apply
      Info 'Re-send each user their config: vps-setup client-config <user>'
    }
    default { Die 'usage: vps-setup gitlab [apply|disable]' }
  }
}

# ----------------------------------------------------------------------------
# Resource usage per user: every process a user runs is counted - SSH/VS Code sessions,
# Claude, their RDP desktop and everything started from it.
# ----------------------------------------------------------------------------
function Usage-Sample { # pid -> user and counters
  $owner = @{}
  foreach ($p in @(Get-Process -IncludeUserName -ErrorAction SilentlyContinue)) {
    $n = ''
    if ($p.UserName) { $n = ($p.UserName -split '\\')[-1].ToLower() }
    $owner[[int]$p.Id] = $n
  }
  $s = @{}
  foreach ($w in @(Get-CimInstance Win32_Process -Property ProcessId, Name, CreationDate, KernelModeTime, UserModeTime, WorkingSetSize, PrivatePageCount, ReadTransferCount, WriteTransferCount -ErrorAction SilentlyContinue)) {
    $id = [int]$w.ProcessId
    $s[$id] = @{
      u = [string]$owner[$id]; name = [string]$w.Name; created = [string]$w.CreationDate
      cpu = [double]$w.KernelModeTime + [double]$w.UserModeTime; ws = [double]$w.WorkingSetSize; priv = [double]$w.PrivatePageCount
      r = [double]$w.ReadTransferCount; wr = [double]$w.WriteTransferCount
    }
  }
  return $s
}

function Usage-Rows([int]$secs, [string]$only = '') { # per user: CPU/disk measured over <secs>, memory now
  $humans = @(Human-Users)
  $s1 = Usage-Sample
  Start-Sleep -Seconds $secs
  $s2 = Usage-Sample
  $agg = @{}
  $procs = @()
  foreach ($id in @($s2.Keys)) {
    $b = $s2[$id]
    $u = $b.u
    if ($humans -notcontains $u) { $u = '(system services)' }
    if ($only -and $u -ne $only) { continue }
    $cpu = 0.0; $rd = 0.0; $wrd = 0.0
    if ($s1.ContainsKey($id) -and $s1[$id].created -eq $b.created) {
      $a = $s1[$id]
      $cpu = [math]::Max(0, $b.cpu - $a.cpu); $rd = [math]::Max(0, $b.r - $a.r); $wrd = [math]::Max(0, $b.wr - $a.wr)
    }
    if (-not $agg.ContainsKey($u)) { $agg[$u] = @{ cpu = 0.0; ws = 0.0; priv = 0.0; r = 0.0; w = 0.0; n = 0 } }
    $x = $agg[$u]
    $x.cpu += $cpu; $x.ws += $b.ws; $x.priv += $b.priv; $x.r += $rd; $x.w += $wrd; $x.n++
    $procs += @{ u = $u; id = $id; name = $b.name; cpu = $cpu; ws = $b.ws }
  }
  return @{ agg = $agg; procs = $procs }
}

function Usage-Table([int]$secs, [string]$sort, [string]$only = '') {
  $d = Usage-Rows $secs $only
  $ncpu = [Environment]::ProcessorCount
  $lines = @(('{0,-18} {1,7} {2,7} {3,8} {4,10} {5,8} {6,8} {7,6}' -f 'USER', 'CPU%', 'SERVER', 'RAM MB', 'PRIVATE MB', 'READ/s', 'WRITE/s', 'PROCS'))
  $rows = @()
  foreach ($u in @($d.agg.Keys)) {
    $x = $d.agg[$u]
    $cpu = $x.cpu / ($secs * 1e7) * 100   # 100 = one full core
    $key = $cpu
    if ($sort -eq 'mem') { $key = $x.ws }
    $rows += [pscustomobject]@{ sys = [int]($u -like '(*'); key = $key; line = ('{0,-18} {1,7:N1} {2,6:N1}% {3,8:N0} {4,10:N0} {5,8:N1} {6,8:N1} {7,6}' -f $u, $cpu, ($cpu / $ncpu), ($x.ws / 1MB), ($x.priv / 1MB), ($x.r / $secs / 1MB), ($x.w / $secs / 1MB), $x.n) }
  }
  $lines += @($rows | Sort-Object -Property @{ Expression = 'sys'; Ascending = $true }, @{ Expression = 'key'; Descending = $true } | ForEach-Object { $_.line })
  return @{ lines = $lines; data = $d }
}

function Dir-Size([string]$root) { # without following junctions (profiles are full of them)
  $total = [int64]0
  $stack = New-Object System.Collections.Stack
  $stack.Push((New-Object IO.DirectoryInfo $root))
  while ($stack.Count -gt 0) {
    $dir = $stack.Pop()
    try {
      foreach ($e in $dir.EnumerateFileSystemInfos()) {
        if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        if ($e -is [IO.DirectoryInfo]) { $stack.Push($e) } else { $total += $e.Length }
      }
    } catch { }
  }
  return $total
}

function Cmd-Usage([string[]]$a) {
  $secs = 3; $sort = 'cpu'; $watch = $false; $disk = $false; $u = ''
  for ($i = 0; $i -lt $a.Count; $i++) {
    $x = $a[$i]
    if ($x -eq '--watch' -or $x -eq '-w') { $watch = $true; if ($i + 1 -lt $a.Count -and $a[$i + 1] -match '^[0-9]+$') { $i++; $secs = [int]$a[$i] } }
    elseif ($x -eq '--mem') { $sort = 'mem' }
    elseif ($x -eq '--disk') { $disk = $true }
    elseif ($x.StartsWith('-')) { Die 'usage: vps-setup usage [<user>] [--mem] [--watch [seconds]] [--disk]' }
    else { $u = $x.ToLower() }
  }
  try { (Get-Process -Id $PID).PriorityClass = 'AboveNormal' } catch { }   # stays responsive on a busy server
  if ($u) {
    if (-not (User-Exists $u)) { Die "No user '$u'." }
    $t = Usage-Table 2 'cpu' $u
    $t.lines | ForEach-Object { Write-Host $_ }
    Write-Host ''
    Write-Host "Top processes of $u right now (CPU over 2 s; 100 = one core):"
    Write-Host ('  {0,-8} {1,7} {2,8}  {3}' -f 'PID', 'CPU%', 'RAM MB', 'NAME')
    @($t.data.procs | Sort-Object -Property @{ Expression = { $_.cpu }; Descending = $true } | Select-Object -First 15) | ForEach-Object {
      Write-Host ('  {0,-8} {1,7:N1} {2,8:N0}  {3}' -f $_.id, ($_.cpu / 2e7 * 100), ($_.ws / 1MB), $_.name)
    }
    return
  }
  if ($disk) {
    Write-Host ('{0,-18} {1}' -f 'USER', 'PROFILE SIZE')
    foreach ($x in @(Server-Users)) {
      $h = Home-Of $x
      $size = 0
      if ($h -and (Test-Path -LiteralPath $h)) { $size = Dir-Size $h }
      Write-Host ('{0,-18} {1:N1} GB' -f $x, ($size / 1GB))
    }
    $c = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'"
    Write-Host ('disk {0} {1:N1} GB used of {2:N1} GB, {3:N1} GB free' -f $env:SystemDrive, (($c.Size - $c.FreeSpace) / 1GB), ($c.Size / 1GB), ($c.FreeSpace / 1GB))
    return
  }
  if ($watch) {
    while ($true) {
      $t = Usage-Table $secs $sort
      Clear-Host
      Write-Host ('Per-user usage on {0}, every {1} s (Ctrl-C to stop)   {2} CPUs' -f (Host-Alias), $secs, [Environment]::ProcessorCount)
      Write-Host ''
      $t.lines | ForEach-Object { Write-Host $_ }
    }
  }
  (Usage-Table $secs $sort).lines | ForEach-Object { Write-Host $_ }
  Write-Host ''
  Write-Host ('CPU%: 100 = one full core ({0} cores = {1}); SERVER: share of the whole CPU.' -f [Environment]::ProcessorCount, ([Environment]::ProcessorCount * 100))
  Write-Host 'RAM: working sets; PRIVATE: memory the programs own (incl. paged out). READ/WRITE:'
  Write-Host "disk and other I/O in MB/s. Measured over $secs s."
  Write-Host 'More: vps-setup usage <user> | --mem | --watch | --disk'
}

function Cmd-Status {
  Step 'Users'
  foreach ($r in @(Users-Table)) { Write-Host "    $r" }

  Step 'SSH'
  $svc = Get-Service sshd -ErrorAction SilentlyContinue
  if (-not $svc) { Warn 'OpenSSH server not installed: vps-setup setup' }
  else {
    Info "sshd: $($svc.Status), OpenSSH $(Sshd-Version)"
    $eff = Sshd-Effective
    if ($eff) { Info (@($eff | Where-Object { $_ -match '^(port|passwordauthentication|allowgroups) ' }) -join '  ') }
    $sp = @(Words $CFG.SSH_PORTS | ForEach-Object { [int]$_ })
    if ($sp.Count -eq 0) { $sp = @(22) }
    if (Ssh-Verify $sp -Quiet) { Ok 'Effective sshd config matches the hardening.' } else { Warn 'sshd config differs from the hardening - run: vps-setup ssh' }
    foreach ($p in $sp) { if (Port-Listening $p) { Info "port ${p}: listening" } else { Warn "port ${p}: NOT listening" } }
    if (Ssh-ChangePending) { Warn "An SSH change is waiting for $($CFG.ADMIN_USER)'s first login (auto-rollback pending)." }
  }

  Step 'Internal GitLab'
  if ($CFG.GITLAB_HOST) {
    $g = Get-Service $GW_SERVICE -ErrorAction SilentlyContinue
    if ($g -and $g.Status -eq 'Running') { Ok "Gateway running: $($CFG.GITLAB_HOST) -> $GITLAB_IP, ports $((Gitlab-Ports) -join ' '), direct fallback: $(if ($CFG.GITLAB_DIRECT) { $CFG.GITLAB_DIRECT } else { 'n' })" }
    else { Warn 'Gateway NOT running: vps-setup gitlab' }
    Info "Tunnels open (user:port): $(Gitlab-Tunnels)"
  } else { Info 'not configured' }

  Step 'Office services'
  Fwd-List

  Step 'Resource sharing'
  $q = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Quota System' -ErrorAction SilentlyContinue).EnableCpuQuota
  Info "Dynamic fair share for CPU: $(if ($q -eq 1) { 'on' } else { 'off (vps-setup setup)' })   per-user numbers: vps-setup usage"

  Step 'Firewall'
  foreach ($p in @(Get-NetFirewallProfile -ErrorAction SilentlyContinue)) { Info ('{0,-8} enabled {1}, inbound {2}' -f $p.Name, $p.Enabled, $p.DefaultInboundAction) }
  foreach ($r in @(Get-NetFirewallRule -Group $FW_GROUP -ErrorAction SilentlyContinue | Where-Object { [string]$_.Enabled -eq 'True' })) { Info "  $($r.DisplayName)" }
  $n = @(Other-InboundRules).Count
  if ($n -gt 0) { Info "  + $n other inbound rule(s) not managed by vps-setup" }
  if (@(Inbound-AllowRulesForPort "$RDP_LOCAL_PORT").Count -gt 0) { Warn "  RDP ($RDP_LOCAL_PORT) is open to the internet$(if ($CFG.RDP_PUBLIC -ne 'y') { ' - closed once the SSH login is confirmed' })" }

  Step 'SSH brute-force guard'
  $t = Get-ScheduledTask -TaskName $BAN_TASK -TaskPath $TASK_PATH -ErrorAction SilentlyContinue
  if ($t) { Info "task: $($t.State)" } else { Warn 'not set up: vps-setup setup' }
  $bans = @(Ban-List)
  Info "Blocked now: $(if ($bans.Count) { $bans -join ', ' } else { '(none)' })"

  Step 'Remote desktop'
  $deny = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -ErrorAction SilentlyContinue).fDenyTSConnections
  Info "RDP: $(if ($deny -eq 0) { 'on' } else { 'off' }); developers: $(if ($CFG.RDP_ENABLED -eq 'y') { 'yes' } else { 'no' }); RDS role: $(if ((Get-WindowsFeature -Name RDS-RD-Server -ErrorAction SilentlyContinue).Installed) { 'yes' } else { 'no (2 desktops at a time)' })"

  Step 'System'
  $os = Get-CimInstance Win32_OperatingSystem
  $up = (Get-Date) - $os.LastBootUpTime
  Info ('{0}, up {1}d {2}h {3}m' -f $os.Caption, $up.Days, $up.Hours, $up.Minutes)
  Info ('memory: {0:N1} GB of {1:N1} GB used' -f (($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1MB), ($os.TotalVisibleMemorySize / 1MB))
  $c = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'"
  Info ('disk {0} {1:N1} GB used of {2:N1} GB' -f $env:SystemDrive, (($c.Size - $c.FreeSpace) / 1GB), ($c.Size / 1GB))
  if (Reboot-Pending) { Warn 'Reboot required (rename, features or updates): Restart-Computer' }
}

function Usage {
  @"
vps-setup $SCRIPT_VERSION - shared Claude Code dev server on Windows Server

  setup                        First-time setup (interactive). Runs every step, reports
                               failures at the end. Safe to re-run.
  status                       Users, SSH, GitLab gateway, firewall, SSH guard, desktops.

  add-user <name> [--admin] [--rdp] [--forward "host:port ..."]
                               Add a developer (or an administrator), optionally with an RDP
                               desktop and personal office services (asked when not given).
  remove-user <name>           Remove a user (their profile is archived first).
  add-key <name>               Add another SSH public key for a user.
  password <name>              Set or reset a Windows password (RDP, lock screen - never SSH).
  client-config <name>         Print the ~/.ssh/config block for that user's computer
                               (several server ports with fallback + the tunnels).

  rdp enable [--multi]|disable [--off]
                               An RDP desktop of their own for every user, through an SSH
                               tunnel. --multi adds the RDS role (more than 2 at a time;
                               needs RDS licenses after 120 days).
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
                               CPU, RAM, disk I/O and processes per user; one user in
                               detail; profile sizes.
  report                       Rewrite $REPORT_FILE and $USERS_DIR\<user>.txt
                               (done by itself after every change).

  ssh [--ports "22 9011"]      Re-apply the SSH hardening or change its ports (auto-rollback).
  confirm                      Keep a pending SSH change now (otherwise it is kept on the
                               admin's first login, or rolled back after $ROLLBACK_MINUTES minutes).
  help                         This text.

Only Windows Server's own features are used - nothing is downloaded or installed. Developers
have no admin rights: they install their own tools (Claude Code, Git, Node...) into their
profile, and ask the admin for system-wide programs.

Differences from the Ubuntu version (what Windows Server has instead):
  - ufw -> Windows Defender Firewall. fail2ban -> a Task Scheduler task reads the OpenSSH
    event log every minute and blocks offenders in the firewall.
  - apt packages and the per-user toolchains -> none; every user installs their own.
  - tmux / claude-session -> none. A Windows SSH session ends when you disconnect - run long
    Claude tasks in your RDP desktop (a disconnected desktop keeps running).
  - VNC desktops -> every user gets their own RDP desktop (vps-setup rdp enable).
  - Docker -> not part of Windows Server (it needs a separate download) - left out.
  - Fair sharing -> Windows' dynamic fair share between RDP sessions; no per-user memory part.
  - Unix-socket tunnels + NAT -> every user has their own loopback ports; the gateway (built
    by Windows' own C# compiler) only uses a port the user's own SSH session holds.
  - The login shell is Windows PowerShell.
"@
}

function Main([string[]]$argv) {
  $cmd = ''
  $rest = @()
  if ($argv.Count -gt 0) { $cmd = $argv[0] }
  if ($argv.Count -gt 1) { $rest = @($argv[1..($argv.Count - 1)]) }
  if (@('help', '-h', '--help', '/?') -contains $cmd) { Write-Host (Usage); return }
  if (-not (Is-Elevated)) {
    $c = $cmd
    if (-not $c) { $c = 'status' }
    Die "This needs an administrator. Run it from an elevated PowerShell ('Run as administrator') or over SSH as the admin:  vps-setup $c $($rest -join ' ')"
  }
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  Init-State
  if (-not $cmd) { if ($CFG.SETUP_DONE -eq 'y') { $cmd = 'status' } else { $cmd = 'setup' } }
  if ($cmd -eq '_ssh-rollback') {
    # Fired by the task: keep the change if the admin logged in through it, else undo it.
    if (Ssh-ChangePending) {
      if (Ssh-LoginSeen) { Ssh-Finalize }
      else {
        Ssh-Restore
        [void](Native-Out 'msg.exe' @('*', "vps-setup: an SSH change saw no login by $($CFG.ADMIN_USER) within $ROLLBACK_MINUTES minutes and was rolled back."))
      }
    }
    Cancel-Rollback
    return
  }
  if ($cmd -eq '_ban') { Cmd-Ban; return }

  $mutex = $null
  if (@('status', 'client-config', 'usage') -notcontains $cmd) {
    # one changing run at a time
    $mutex = New-Object System.Threading.Mutex($false, 'Global\vps-setup')
    $got = $false
    try { $got = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $got = $true }
    if (-not $got) { Die 'Another vps-setup run is still going (another window or SSH session).' }
  }
  if (@('setup', 'status', 'client-config', 'report', 'usage') -notcontains $cmd) {
    if ($cmd -eq 'forward') { if ($rest.Count -gt 0 -and $rest[0] -ne 'list') { $script:REFRESH_FOR = "$cmd $($rest -join ' ')" } }
    else { $script:REFRESH_FOR = "$cmd $($rest -join ' ')".Trim() }
  }
  Begin-Run
  try {
    $arg1 = ''
    if ($rest.Count -gt 0) { $arg1 = $rest[0] }
    switch ($cmd) {
      'setup' { Cmd-Setup }
      'status' { Cmd-Status }
      'add-user' { Cmd-AddUser $rest }
      'remove-user' { Cmd-RemoveUser $arg1 }
      'add-key' { Cmd-AddKey $arg1 }
      'password' { Cmd-Password $arg1 }
      'client-config' { Cmd-ClientConfig $arg1 }
      'rdp' { Cmd-Rdp $rest }
      'vnc' { Die 'Windows Server has no VNC - every user gets their own RDP desktop: vps-setup rdp enable' }
      'gitlab' { Cmd-Gitlab $rest }
      'forward' { Cmd-Forward $rest }
      'usage' { Cmd-Usage $rest }
      'report' { Refresh-Files 'report'; Ok "Updated: $REPORT_FILE and $USERS_DIR\<user>.txt" }
      'ssh' { Cmd-Ssh $rest }
      'confirm' {
        if (-not (Ssh-ChangePending)) { Die 'No SSH change is pending.' }
        Ssh-Finalize
        Ok "SSH change kept (ports $($CFG.SSH_PORTS))."
      }
      default { Write-Host (Usage); $script:EXIT_CODE = 2 }
    }
  } finally {
    End-Run
    if ($mutex) { try { $mutex.ReleaseMutex() } catch { } }
  }
}

try {
  Main @($args)
  exit $script:EXIT_CODE
} catch {
  Show-Error $_
  exit 1
}
