# release.ps1 — build homeCtrl + update manifest.json + git commit/push + GitHub Release
# Auto-installs git, gh CLI, and dotnet SDK via winget if missing.
#
# Usage:
#   .\release.ps1 -Version 1.2.3
#   .\release.ps1 -Version 1.2.3 -Notes "Fix screenshot bug"
#   .\release.ps1 -Version 1.2.3 -SkipBuild
#   .\release.ps1 -Version 1.2.3 -SkipUpload

param(
    [Parameter(Mandatory=$true)] [string] $Version,
    [string] $Notes = "",
    [switch] $SkipBuild,
    [switch] $SkipUpload
)

$ErrorActionPreference = "Stop"

# Paths — adjust if repo layout changes
$agentSource = "C:\Users\mohba\OneDrive\Desktop\pranks\Agent\Source"
$exePath     = Join-Path $agentSource "publish_out\homeCtrl.exe"
$manifestDir = $PSScriptRoot
$manifestPath = Join-Path $manifestDir "manifest.json"

# GitHub repo (owner/name). Change if you fork or rename.
$ghOwner = "sayamuhbani59-collab"
$ghRepo  = "homectrl-updates"

function Fail($msg) { Write-Host "❌ $msg" -ForegroundColor Red; exit 1 }

function Refresh-Path {
    # Reload PATH from registry so freshly installed tools become findable in this session.
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

    Write-Host "🔧 $DisplayName nicht gefunden — installiere via winget ($WingetId)..." -ForegroundColor Yellow

    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        Fail "winget nicht verfügbar. Installiere $DisplayName manuell oder update Windows (App Installer)."
    }

    winget install --id $WingetId --exact --silent --accept-source-agreements --accept-package-agreements | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Fail "winget install $WingetId fehlgeschlagen (exit $LASTEXITCODE)"
    }

    Refresh-Path

    $recheck = Get-Command $Command -ErrorAction SilentlyContinue
    if (-not $recheck) {
        Fail "$DisplayName installiert, aber '$Command' immer noch nicht im PATH. Terminal/Session neu starten und nochmal versuchen."
    }
    Write-Host "✅ $DisplayName installiert" -ForegroundColor Green
}

# ---------------- Prerequisites (auto-install) ----------------
Write-Host "🔍 Checking prerequisites..." -ForegroundColor Cyan
Ensure-Tool -Command "git" -WingetId "Git.Git" -DisplayName "Git"
Ensure-Tool -Command "dotnet" -WingetId "Microsoft.DotNet.SDK.8" -DisplayName ".NET 8 SDK"
Ensure-Tool -Command "gh" -WingetId "GitHub.cli" -DisplayName "GitHub CLI"

# gh needs auth once — check
$ghStatus = & gh auth status 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "🔐 gh CLI nicht eingeloggt — starte 'gh auth login'..." -ForegroundColor Yellow
    Write-Host "   Wähle: GitHub.com → HTTPS → Yes (authenticate git) → Login with browser" -ForegroundColor Yellow
    gh auth login
    if ($LASTEXITCODE -ne 0) { Fail "gh auth login abgebrochen — kann kein Release erstellen." }
}

# ---------------- 1) Build ----------------
if (-not $SkipBuild) {
    Write-Host "🔨 Building homeCtrl.exe (self-contained, single-file, win-x64)..." -ForegroundColor Cyan
    Push-Location $agentSource
    try {
        dotnet publish -c Release -o .\publish_out -p:PublishSingleFile=true -r win-x64 --self-contained true | Out-Null
        if ($LASTEXITCODE -ne 0) { Fail "dotnet publish failed" }
    }
    finally { Pop-Location }
}

if (-not (Test-Path $exePath)) { Fail "exe not found: $exePath" }

# ---------------- 2) SHA-256 + size ----------------
Write-Host "🔑 Computing SHA-256..." -ForegroundColor Cyan
$hash = (certutil -hashfile $exePath SHA256 | Select-Object -Index 1).Trim().ToLower()
$size = (Get-Item $exePath).Length
Write-Host "   sha256 = $hash"
Write-Host "   size   = $size bytes ($([math]::Round($size/1MB,1)) MB)"

# ---------------- 3) Update manifest.json ----------------
Write-Host "📝 Updating manifest.json..." -ForegroundColor Cyan
$downloadUrl = "https://github.com/$ghOwner/$ghRepo/releases/download/v$Version/homeCtrl.exe"
$manifest = @{
    version = $Version
    sha256  = $hash
    url     = $downloadUrl
    notes   = $Notes
} | ConvertTo-Json -Depth 4
Set-Content -Path $manifestPath -Value $manifest -Encoding utf8
Write-Host "   -> $manifestPath"

# ---------------- 4) Git commit + push ----------------
Write-Host "📦 git add + commit + push manifest..." -ForegroundColor Cyan
Push-Location $manifestDir
try {
    git add manifest.json README.md .gitignore release.ps1 2>&1 | Out-Null
    $status = git status --porcelain
    if ($status) {
        git commit -m "release v$Version" | Out-Null
        git push
        if ($LASTEXITCODE -ne 0) { Fail "git push failed — remote/credentials prüfen" }
        Write-Host "   -> pushed to $ghOwner/$ghRepo main" -ForegroundColor Green
    } else {
        Write-Host "   (no changes to commit)" -ForegroundColor Yellow
    }
}
finally { Pop-Location }

# ---------------- 5) GitHub Release + Exe Upload ----------------
if ($SkipUpload) {
    Write-Host "⏭ SkipUpload gesetzt — Release manuell anlegen:" -ForegroundColor Yellow
    Write-Host "   https://github.com/$ghOwner/$ghRepo/releases/new  →  Tag v$Version  →  $exePath"
    exit 0
}

Write-Host "🚀 GitHub Release v$Version + Exe upload via gh CLI..." -ForegroundColor Cyan
$notesArg = if ([string]::IsNullOrWhiteSpace($Notes)) { "Release v$Version" } else { $Notes }
gh release create "v$Version" $exePath --title "v$Version" --notes $notesArg
if ($LASTEXITCODE -ne 0) { Fail "gh release create failed" }
Write-Host "✅ Release v$Version live" -ForegroundColor Green
Write-Host "   Agents pullen innerhalb autoUpdateIntervalMinutes. Sofort: /checkupdate force" -ForegroundColor Green
