<#
.SYNOPSIS
    Deploy Muxlet to a Mudlet dev profile.
.DESCRIPTION
    Copies the built package to a Mudlet profile directory and writes a stamp
    file that the in-package auto-reload timer watches.

    Run after every build:
        muddle && ./devmode.ps1

    Within ~30 seconds, Mudlet auto-reloads. For an immediate reload, type
    "mux reload" in Mudlet.
.PARAMETER Profile
    Mudlet profile name (default: mux-dev)
.PARAMETER MudletConfigPath
    Override the Mudlet config directory (auto-detected if not specified).
    Run Mudlet at least once before using auto-detection.
.EXAMPLE
    ./devmode.ps1
.EXAMPLE
    ./devmode.ps1 -Profile my-test
.EXAMPLE
    ./devmode.ps1 -MudletConfigPath "C:\Users\you\AppData\Roaming\Mudlet"
#>
param(
    [string] $Profile         = "mux-dev",
    [string] $MudletConfigPath = ""
)

$ErrorActionPreference = "Stop"
$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Definition
$srcPackage = Join-Path $scriptDir "build\Muxlet.mpackage"

Write-Host ""
Write-Host "=== Muxlet devmode deploy ==="
Write-Host ""

# ── Find Mudlet config directory ──────────────────────────────────────────────

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
                 "Launch Mudlet at least once, then re-run this script.`n" +
                 "Or pass -MudletConfigPath explicitly.")
}

Write-Host "Mudlet config : $MudletConfigPath"

# ── Set up profile directory ──────────────────────────────────────────────────

$profileDir = Join-Path $MudletConfigPath "profiles\$Profile"
$firstTime  = $false

if (-not (Test-Path $profileDir)) {
    New-Item -ItemType Directory -Force $profileDir | Out-Null
    Write-Host "Created profile: $Profile"
    $firstTime = $true
} else {
    Write-Host "Profile       : $Profile"
}

# ── Copy package ──────────────────────────────────────────────────────────────

if (-not (Test-Path $srcPackage)) {
    Write-Error ("build/Muxlet.mpackage not found.`n" +
                 "Run `muddle` first, then re-run this script.")
}

$destPackage = Join-Path $profileDir "Muxlet.mpackage"
Copy-Item $srcPackage $destPackage -Force
Write-Host "Deployed      : $destPackage"

# ── Write stamp file ──────────────────────────────────────────────────────────

$stampPath = Join-Path $profileDir "Muxlet-rebuild.stamp"
[DateTimeOffset]::UtcNow.ToUnixTimeSeconds() | Set-Content $stampPath
Write-Host "Stamp written : $stampPath"

Write-Host ""

if ($firstTime) {
    Write-Host "FIRST-TIME SETUP:"
    Write-Host "  1. Open Mudlet"
    Write-Host "  2. Select profile: '$Profile'"
    Write-Host "     (no game connection needed - Muxlet is game-agnostic)"
    Write-Host "  3. Toolbox -> Package Manager -> Install from file:"
    Write-Host "     $destPackage"
    Write-Host ""
    Write-Host "After this one-time install, the auto-reload handles everything."
    Write-Host ""
}

Write-Host "ONGOING WORKFLOW:"
Write-Host "  muddle && ./devmode.ps1"
Write-Host "  Mudlet auto-reloads within ~30 seconds."
Write-Host "  Or type in Mudlet: mux reload   for an immediate reload."
Write-Host ""
