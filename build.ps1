<#
.SYNOPSIS
    Build the Muxlet package with version derived from git tags.
.DESCRIPTION
    Derives version from git tags, patches mfile, runs muddle, then restores
    mfile so the committed value stays clean.

    For release builds (exact git tag at HEAD):    version = "1.2.3"
    For dev builds (no exact tag):                version = "1.2.3-a3f91cd"

    Pass -Version to override (CI uses this).
.PARAMETER Version
    Override the version string. Derived from git tags when not specified.
.PARAMETER Profile
    If specified, deploy the built package to this Mudlet profile directory and
    write a rebuild stamp file (triggers mux reload within ~30 seconds).
.PARAMETER MudletConfigPath
    Override the Mudlet config directory. Auto-detected from APPDATA when not
    specified. Required on non-Windows or unusual Mudlet installs.
.EXAMPLE
    ./build.ps1
.EXAMPLE
    ./build.ps1 -Profile mux-dev
.EXAMPLE
    ./build.ps1 -Version "1.2.0"
#>

[CmdletBinding()]
param(
    [string]$Version          = "",
    [string]$Profile          = "",
    [string]$MudletConfigPath = ""
)

$ErrorActionPreference = "Stop"
$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Definition
$mfilePath  = Join-Path $scriptDir "mfile"
$srcPackage = Join-Path $scriptDir "build\Muxlet.mpackage"

Write-Host ""
Write-Host "=== Muxlet build ===" -ForegroundColor Cyan

# ── Derive version from git ───────────────────────────────────────────────────

if ($Version -eq "") {
    # Check if HEAD sits exactly on a version tag
    $exactTag = & git describe --tags --exact-match HEAD 2>$null
    if ($LASTEXITCODE -eq 0 -and $exactTag -match '^v(.+)$') {
        $Version = $Matches[1]
    } else {
        $lastTag = & git describe --tags --match "v*" --abbrev=0 2>$null
        $baseVersion = if ($LASTEXITCODE -eq 0 -and $lastTag) {
            $lastTag -replace '^v', ''
        } else {
            "0.0.0"
        }
        $shortSha = & git rev-parse --short HEAD 2>$null
        $Version  = "$baseVersion-$shortSha"
    }
}

Write-Host "Version       : $Version" -ForegroundColor Green

# ── Patch mfile temporarily ───────────────────────────────────────────────────

$originalMfile = Get-Content $mfilePath -Raw
$patchedMfile  = $originalMfile -replace '"version":\s*"[^"]*"', ('"version": "' + $Version + '"')
Set-Content $mfilePath $patchedMfile -NoNewline
Write-Host "mfile         : version set to $Version" -ForegroundColor Gray

# ── Run muddle ────────────────────────────────────────────────────────────────

try {
    & muddle
    if ($LASTEXITCODE -ne 0) { throw "muddle exited with code $LASTEXITCODE" }
    Write-Host "Output        : $srcPackage" -ForegroundColor Green
} finally {
    # Always restore mfile so the committed file stays version-neutral
    Set-Content $mfilePath $originalMfile -NoNewline
    Write-Host "mfile         : restored" -ForegroundColor Gray
}

# ── Deploy to profile (optional) ─────────────────────────────────────────────

if ($Profile -eq "") {
    Write-Host ""
    exit 0
}

Write-Host ""
Write-Host "=== Deploying to profile: $Profile ===" -ForegroundColor Cyan

# Find Mudlet config directory
if ($MudletConfigPath -eq "") {
    $candidates = @(
        "$env:APPDATA\Mudlet",
        "$env:USERPROFILE\.config\mudlet"
    )
    foreach ($candidate in $candidates) {
        if (Test-Path (Join-Path $candidate "profiles")) {
            $MudletConfigPath = $candidate
            break
        }
    }
}

if ($MudletConfigPath -eq "") {
    Write-Error ("Could not find Mudlet config directory.`n" +
                 "Launch Mudlet at least once, or pass -MudletConfigPath explicitly.")
}

Write-Host "Mudlet config : $MudletConfigPath"

$profileDir = Join-Path $MudletConfigPath "profiles\$Profile"
$firstTime  = $false

if (-not (Test-Path $profileDir)) {
    New-Item -ItemType Directory -Force $profileDir | Out-Null
    Write-Host "Created profile: $Profile"
    $firstTime = $true
} else {
    Write-Host "Profile       : $Profile"
}

if (-not (Test-Path $srcPackage)) {
    Write-Error "build/Muxlet.mpackage not found after build step."
}

$destPackage = Join-Path $profileDir "Muxlet.mpackage"
Copy-Item $srcPackage $destPackage -Force
Write-Host "Deployed      : $destPackage"

$stampPath = Join-Path $profileDir "Muxlet-rebuild.stamp"
[DateTimeOffset]::UtcNow.ToUnixTimeSeconds() | Set-Content $stampPath
Write-Host "Stamp written : $stampPath"

Write-Host ""

if ($firstTime) {
    Write-Host "FIRST-TIME SETUP:" -ForegroundColor Yellow
    Write-Host "  1. Open Mudlet"
    Write-Host "  2. Select profile: '$Profile'"
    Write-Host "     (no game connection needed — Muxlet is game-agnostic)"
    Write-Host "  3. Toolbox -> Package Manager -> Install from file:"
    Write-Host "     $destPackage"
    Write-Host ""
    Write-Host "After this one-time install, the auto-reload handles everything."
    Write-Host ""
}

Write-Host "WORKFLOW:" -ForegroundColor Cyan
Write-Host "  ./build.ps1 -Profile $Profile"
Write-Host "  Mudlet auto-reloads within ~30 seconds."
Write-Host "  Or type in Mudlet: mux reload   for an immediate reload."
Write-Host ""
