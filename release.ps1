# release.ps1 — build homeCtrl + update manifest.json + git commit/push
# Usage:
#   .\release.ps1 -Version 1.2.3
#   .\release.ps1 -Version 1.2.3 -Notes "Fix screenshot bug"
#   .\release.ps1 -Version 1.2.3 -SkipBuild        # only regenerate manifest for existing publish_out\homeCtrl.exe
#   .\release.ps1 -Version 1.2.3 -SkipUpload       # commit manifest only, upload exe manually later

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

# 1) Build (unless skipped)
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

# 2) SHA-256 + size
Write-Host "🔑 Computing SHA-256..." -ForegroundColor Cyan
$hash = (certutil -hashfile $exePath SHA256 | Select-Object -Index 1).Trim().ToLower()
$size = (Get-Item $exePath).Length
Write-Host "   sha256 = $hash"
Write-Host "   size   = $size bytes ($([math]::Round($size/1MB,1)) MB)"

# 3) Update manifest.json
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

# 4) Git commit manifest
Write-Host "📦 git add + commit + push manifest..." -ForegroundColor Cyan
Push-Location $manifestDir
try {
    git add manifest.json README.md .gitignore release.ps1 2>&1 | Out-Null
    $status = git status --porcelain
    if ($status) {
        git commit -m "release v$Version" | Out-Null
        git push
        if ($LASTEXITCODE -ne 0) { Fail "git push failed — set up remote and try again" }
        Write-Host "   -> pushed to $ghOwner/$ghRepo main" -ForegroundColor Green
    } else {
        Write-Host "   (no changes to commit)" -ForegroundColor Yellow
    }
}
finally { Pop-Location }

# 5) Create release + upload exe (needs gh CLI OR do manually)
if ($SkipUpload) {
    Write-Host "⏭ SkipUpload set — create the GitHub Release manually:" -ForegroundColor Yellow
    Write-Host "   1. Go to https://github.com/$ghOwner/$ghRepo/releases/new"
    Write-Host "   2. Tag: v$Version"
    Write-Host "   3. Attach binary: $exePath"
    exit 0
}

$gh = Get-Command gh -ErrorAction SilentlyContinue
if ($gh) {
    Write-Host "🚀 Creating GitHub Release v$Version + uploading exe via gh CLI..." -ForegroundColor Cyan
    $notesArg = if ([string]::IsNullOrWhiteSpace($Notes)) { "Release v$Version" } else { $Notes }
    gh release create "v$Version" $exePath --title "v$Version" --notes $notesArg
    if ($LASTEXITCODE -ne 0) { Fail "gh release create failed" }
    Write-Host "✅ Release v$Version live" -ForegroundColor Green
    Write-Host "   Agents should auto-update within autoUpdateIntervalMinutes." -ForegroundColor Green
} else {
    Write-Host "⚠ gh CLI not installed — install via 'winget install --id GitHub.cli' or upload exe manually:" -ForegroundColor Yellow
    Write-Host "   1. https://github.com/$ghOwner/$ghRepo/releases/new"
    Write-Host "   2. Tag: v$Version"
    Write-Host "   3. Attach: $exePath"
}
