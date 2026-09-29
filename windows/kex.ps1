#Requires -Version 5.1
# kex for Windows: XFCE desktop on a cloud VM through an SSH tunnel, opened in Remote Desktop.
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command = 'start',
    [Parameter(Position = 1)][string]$Name = ''
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$KexVersion = '0.1.0'
$ConfDir = Join-Path $env:APPDATA 'kex'
$ProfileDir = Join-Path $ConfDir 'profiles'
$RunDir = Join-Path $ConfDir 'run'

$ServerScript = @(
    (Join-Path $PSScriptRoot 'kex-server.sh'),
    (Join-Path $PSScriptRoot '..\server\kex-server.sh')
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

function Fail([string]$msg) {
    Write-Host "kex: $msg" -ForegroundColor Red
    exit 1
}

function Test-Name([string]$n) { return $n -cmatch '^[a-z0-9][a-z0-9_-]{0,31}$' }
function Test-SshHost([string]$h) { return ($h -match '^([A-Za-z0-9._-]+@)?[A-Za-z0-9._:-]+$') -and -not $h.StartsWith('-') }
function Test-Port($p) {
    $n = 0
    return ([int]::TryParse([string]$p, [ref]$n) -and $n -ge 1024 -and $n -le 65535)
}

function Initialize-Dirs {
    foreach ($d in @($ConfDir, $ProfileDir, $RunDir)) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
    }
}

function Get-SshExe {
    $cmd = Get-Command ssh.exe -ErrorAction SilentlyContinue
    if (-not $cmd) {
        Fail "OpenSSH client not found. Install it: Settings > System > Optional features > OpenSSH Client."
    }
    return $cmd.Source
}

# Quote one argument using the rules the Windows C runtime uses to split command lines.
function ConvertTo-Arg([string]$a) {
    if ($a -eq '') { return '""' }
    if ($a -notmatch '[\s"]') { return $a }
    $escaped = $a -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Get-ProfilePath([string]$n) { return Join-Path $ProfileDir "$n.json" }

function Get-ProfileNames {
    if (-not (Test-Path -LiteralPath $ProfileDir)) { return @() }
    return @(Get-ChildItem -LiteralPath $ProfileDir -Filter '*.json' | ForEach-Object { $_.BaseName })
}

function Read-KexProfile([string]$n) {
    if (-not (Test-Name $n)) { Fail "invalid profile name '$n'" }
    $path = Get-ProfilePath $n
    if (-not (Test-Path -LiteralPath $path)) { Fail "no profile named '$n'. See 'kex list'." }
    $p = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if (-not (Test-SshHost $p.host) -or -not (Test-Port $p.remote_port) -or -not (Test-Port $p.local_port)) {
        Fail "profile '$n' is corrupt; run 'kex setup' again"
    }
    if ($p.key -and -not (Test-Path -LiteralPath $p.key)) { Fail "SSH key '$($p.key)' for profile '$n' is missing" }
    $p | Add-Member -NotePropertyName name -NotePropertyValue $n -Force
    return $p
}

function Resolve-ProfileName([string]$n) {
    if ($n) { return $n }
    $names = @(Get-ProfileNames)
    if ($names.Count -eq 0) { return $null }
    if ($names.Count -eq 1) { return $names[0] }
    Fail "you have several profiles ($($names -join ', ')); say which: kex $Command <name>"
}

function Get-SshOptions($p) {
    $opts = @('-o', 'ServerAliveInterval=30', '-o', 'ServerAliveCountMax=3')
    if ($p.key) { $opts += @('-i', $p.key, '-o', 'IdentitiesOnly=yes') }
    return $opts
}

function Test-LocalPortFree([int]$port) {
    $listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, $port)
    try { $listener.Start(); return $true } catch { return $false } finally { $listener.Stop() }
}

function Test-LocalPortOpen([int]$port) {
    $client = New-Object System.Net.Sockets.TcpClient
    try { $client.Connect('127.0.0.1', $port); return $true } catch { return $false } finally { $client.Close() }
}

function Get-FreeLocalPort {
    $used = @(Get-ProfileNames | ForEach-Object { [int](Get-Content -LiteralPath (Get-ProfilePath $_) -Raw | ConvertFrom-Json).local_port })
    foreach ($port in 3391..3499) {
        if ($used -contains $port) { continue }
        if (Test-LocalPortFree $port) { return $port }
    }
    Fail 'no free local port between 3391 and 3499'
}

function Invoke-RemoteServer($p, [string]$serverArgs) {
    if (-not $ServerScript) { Fail 'kex-server.sh is missing next to kex.ps1; reinstall kex' }
    $text = [System.IO.File]::ReadAllText($ServerScript) -replace "`r`n", "`n"
    $b64 = [Convert]::ToBase64String((New-Object System.Text.UTF8Encoding $false).GetBytes($text))
    # No double quotes in here, so PowerShell passes it to ssh.exe as one clean argument.
    $remote = 'f=$(mktemp) && echo ' + $b64 + ' | base64 -d > $f && bash $f ' + $serverArgs + '; r=$?; rm -f $f; exit $r'
    $ssh = Get-SshExe
    $opts = Get-SshOptions $p
    & $ssh @opts -t -- $p.host $remote
    return ($LASTEXITCODE -eq 0)
}

function Get-TunnelFile([string]$n) { return Join-Path $RunDir "$n.json" }

# Returns the running tunnel's ssh process, or $null. Matches PID *and* start time so a reused PID is never touched.
function Get-TunnelProcess([string]$n) {
    $file = Get-TunnelFile $n
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    $t = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
    $proc = Get-Process -Id $t.pid -ErrorAction SilentlyContinue
    if ($proc -and $proc.ProcessName -eq 'ssh' -and $proc.StartTime.ToUniversalTime().ToString('o') -eq $t.started) {
        return $proc
    }
    Remove-Item -LiteralPath $file -Force
    return $null
}

function Open-Rdp([int]$port) {
    Start-Process -FilePath 'mstsc.exe' -ArgumentList "/v:127.0.0.1:$port"
    Write-Host "Opening Remote Desktop -> 127.0.0.1:$port"
}

function Invoke-Setup {
    Initialize-Dirs
    $ssh = Get-SshExe
    if (-not $ServerScript) { Fail 'kex-server.sh is missing next to kex.ps1; reinstall kex' }

    Write-Host 'Set up a desktop on a cloud VM (EC2, Google Cloud, Oracle, ...) over SSH.'
    Write-Host '(For a desktop inside WSL2, run kex setup from your WSL terminal instead.)'
    $sshHost = (Read-Host 'SSH login for the VM (e.g. ubuntu@203.0.113.10 or a Host from ~/.ssh/config)').Trim()
    if (-not (Test-SshHost $sshHost)) { Fail "'$sshHost' doesn't look like user@host" }

    $key = (Read-Host 'Path to the SSH private key (.pem) - leave empty to use your SSH agent/config').Trim().Trim('"')
    if ($key) {
        if (-not (Test-Path -LiteralPath $key -PathType Leaf)) { Fail "can't find $key" }
        $key = (Resolve-Path -LiteralPath $key).ProviderPath
    }

    $defaultName = (($sshHost -replace '^.*@', '').ToLower() -replace '[.:]', '-') -replace '[^a-z0-9_-]', ''
    if ($defaultName.Length -gt 32) { $defaultName = $defaultName.Substring(0, 32) }
    if (-not $defaultName) { $defaultName = 'vm' }
    $n = (Read-Host "Name for this profile [$defaultName]").Trim()
    if (-not $n) { $n = $defaultName }
    if (-not (Test-Name $n)) { Fail 'profile names use lowercase letters, digits, - and _' }

    $rport = (Read-Host 'xrdp port on the VM [3389]').Trim()
    if (-not $rport) { $rport = '3389' }
    if (-not (Test-Port $rport)) { Fail 'invalid port' }

    $full = (Read-Host 'Also install extra XFCE apps (xfce4-goodies, bigger download)? [y/N]').Trim() -match '^[yY]'

    $p = [pscustomobject]@{ host = $sshHost; key = $key; remote_port = [int]$rport; local_port = (Get-FreeLocalPort) }
    $opts = Get-SshOptions $p

    Write-Host "Checking SSH access to $sshHost (confirm the host fingerprint if asked)..."
    & $ssh @opts -o ConnectTimeout=15 -- $sshHost true
    if ($LASTEXITCODE -ne 0) {
        Fail "couldn't SSH to $sshHost. Fix SSH access first (key, username, firewall allowing port 22)."
    }

    Write-Host "Setting up the desktop on $sshHost (you may be asked for your sudo password there)..."
    $serverArgs = "--mode vm --port $rport --install"
    if ($full) { $serverArgs += ' --full' }
    if (-not (Invoke-RemoteServer $p $serverArgs)) { Fail 'setup on the VM failed (see above)' }

    $p | ConvertTo-Json | Set-Content -LiteralPath (Get-ProfilePath $n) -Encoding UTF8
    Write-Host ''
    Write-Host "Done. Connect with: kex start $n"
    Write-Host "Only SSH (port 22) needs to be open in the VM's firewall. Do NOT open port $rport."
}

function Invoke-Start([string]$n) {
    $n = Resolve-ProfileName $n
    if (-not $n) {
        Write-Host 'No desktop configured yet - starting setup.'
        Invoke-Setup
        return
    }
    $p = Read-KexProfile $n
    Initialize-Dirs
    $ssh = Get-SshExe

    if (Get-TunnelProcess $n) {
        Write-Host "Tunnel to $($p.host) already open."
        Open-Rdp $p.local_port
        return
    }
    if (-not (Test-LocalPortFree $p.local_port)) { Fail "local port $($p.local_port) is already in use by another program" }

    $opts = Get-SshOptions $p
    $tunnelArgs = $opts + @('-N', '-o', 'ExitOnForwardFailure=yes',
        '-L', "127.0.0.1:$($p.local_port):127.0.0.1:$($p.remote_port)", '--', $p.host)
    $argLine = ($tunnelArgs | ForEach-Object { ConvertTo-Arg $_ }) -join ' '

    # Run hidden when no prompt is needed; otherwise show the window so a key passphrase can be typed.
    # LogLevel=QUIET instead of 2>$null: in Windows PowerShell 5.1, redirecting native stderr throws under 'Stop'.
    & $ssh @opts -o BatchMode=yes -o LogLevel=QUIET -o ConnectTimeout=15 -- $p.host exit
    $style = 'Hidden'
    if ($LASTEXITCODE -ne 0) {
        $style = 'Normal'
        Write-Host 'SSH needs input (passphrase or host key). Answer it in the window that opens; leave that window open while you use the desktop.'
    }

    Write-Host "Opening SSH tunnel to $($p.host)..."
    $proc = Start-Process -FilePath $ssh -ArgumentList $argLine -WindowStyle $style -PassThru
    $deadline = (Get-Date).AddSeconds(90)
    while (-not (Test-LocalPortOpen $p.local_port)) {
        if ($proc.HasExited) { Fail 'the SSH tunnel exited; check SSH access with: ssh <your host>' }
        if ((Get-Date) -gt $deadline) {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            Fail 'timed out waiting for the SSH tunnel'
        }
        Start-Sleep -Milliseconds 500
    }

    @{ pid = $proc.Id; started = $proc.StartTime.ToUniversalTime().ToString('o') } |
        ConvertTo-Json | Set-Content -LiteralPath (Get-TunnelFile $n) -Encoding UTF8
    Open-Rdp $p.local_port
}

function Invoke-Stop([string]$n) {
    $n = Resolve-ProfileName $n
    if (-not $n) { Fail 'nothing configured' }
    $p = Read-KexProfile $n
    $proc = Get-TunnelProcess $n
    if ($proc) {
        Stop-Process -Id $proc.Id -Force
        Remove-Item -LiteralPath (Get-TunnelFile $n) -Force -ErrorAction SilentlyContinue
    }
    Write-Host "Tunnel to $($p.host) closed. (The desktop keeps running on the VM, reachable only through SSH.)"
}

function Write-StatusLine([string]$n) {
    $p = Read-KexProfile $n
    if (Get-TunnelProcess $n) {
        Write-Host "$n  [vm $($p.host)]  connected -> 127.0.0.1:$($p.local_port)"
    } else {
        Write-Host "$n  [vm $($p.host)]  not connected"
    }
}

function Invoke-Status([string]$n) {
    if ($n) { Write-StatusLine $n; return }
    $names = @(Get-ProfileNames)
    if ($names.Count -eq 0) { Write-Host "No desktops configured. Run 'kex setup'."; return }
    foreach ($x in $names) { Write-StatusLine $x }
}

function Invoke-Remove([string]$n) {
    if (-not $n) { Fail 'usage: kex remove <name>' }
    $p = Read-KexProfile $n
    $ans = Read-Host "Uninstall xrdp from '$n' and delete the profile? [y/N]"
    if ($ans -notmatch '^[yY]') { return }
    Invoke-Stop $n
    if (-not (Invoke-RemoteServer $p '--mode vm --uninstall')) { Fail 'uninstall on the VM failed; profile kept' }
    Remove-Item -LiteralPath (Get-ProfilePath $n) -Force
    Write-Host "Profile '$n' removed."
}

function Show-Usage {
    Write-Host @"
kex $KexVersion - desktop on a cloud VM, from Windows

  kex setup            set up a desktop on a cloud VM
  kex [start] [name]   open the SSH tunnel and Remote Desktop
  kex stop [name]      close the tunnel (alias: kexit)
  kex status [name]    show connections (alias: kstatus)
  kex list             list profiles
  kex remove <name>    uninstall from the VM and delete the profile
"@
}

switch ($Command) {
    'setup' { Invoke-Setup }
    'start' { Invoke-Start $Name }
    'stop' { Invoke-Stop $Name }
    'status' { Invoke-Status $Name }
    'list' { Get-ProfileNames }
    { $_ -in 'remove', 'uninstall' } { Invoke-Remove $Name }
    { $_ -in 'version', '--version' } { Write-Host "kex $KexVersion" }
    { $_ -in 'help', '-h', '--help' } { Show-Usage }
    default {
        if ((Test-Name $Command) -and (Test-Path -LiteralPath (Get-ProfilePath $Command))) {
            Invoke-Start $Command
        } else {
            Show-Usage
            exit 2
        }
    }
}
