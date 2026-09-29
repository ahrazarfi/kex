# Installs kex for the current Windows user. No admin needed.
# Run from the repo:  powershell -ExecutionPolicy Bypass -File windows\install.ps1
$ErrorActionPreference = 'Stop'

$dest = Join-Path $env:LOCALAPPDATA 'kex'
New-Item -ItemType Directory -Force -Path $dest | Out-Null

$files = @('kex.ps1', 'kex.cmd', 'kexit.cmd', 'kstatus.cmd') | ForEach-Object { Join-Path $PSScriptRoot $_ }
$files += Join-Path $PSScriptRoot '..\server\kex-server.sh'
Copy-Item -LiteralPath $files -Destination $dest -Force
Get-ChildItem -LiteralPath $dest | Unblock-File

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not $userPath) { $userPath = '' }
if (($userPath -split ';') -notcontains $dest) {
    $newPath = (($userPath.TrimEnd(';'), $dest) | Where-Object { $_ }) -join ';'
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    Write-Host "Added $dest to your PATH. Open a new terminal before using kex."
}

if (-not (Get-Command ssh.exe -ErrorAction SilentlyContinue)) {
    Write-Host 'OpenSSH client is missing. Install it: Settings > System > Optional features > OpenSSH Client.' -ForegroundColor Yellow
}
Write-Host "Installed kex to $dest. Next: kex setup"
