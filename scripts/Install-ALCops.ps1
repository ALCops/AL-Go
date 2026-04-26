<#
.SYNOPSIS
    Downloads and extracts analyzer DLLs from a NuGet package for use as AL custom code cops.

.PARAMETER packageName
    The NuGet package ID (e.g. "ALCops.Analyzers").

.PARAMETER packageVersion
    Version to download. Accepts:
      - ""        : latest stable release (no prerelease suffix)
      - "alpha"   : latest version tagged with -alpha
      - "beta"    : latest version tagged with -beta
      - "1.2.3"   : exact version

.PARAMETER targetFramework
    Target framework folder to extract from the NuGet lib folder (e.g. "net8.0").
    Mutually exclusive with artifactUrl.

.PARAMETER artifactUrl
    BC artifact URL to auto-detect the target framework from (e.g.
    "https://bcartifacts.azureedge.net/sandbox/26.0.12345.0/us").
    Uses @alcops/core via npx to detect the correct TFM.
    Mutually exclusive with targetFramework.

.PARAMETER copsFolder
    Destination folder for the extracted DLLs. Defaults to $ENV:GITHUB_WORKSPACE/.alcops/<targetFramework>.
#>
Param(
    [Parameter(Mandatory = $false)]
    [string] $packageName,

    [Parameter(Mandatory = $false)]
    [string] $packageVersion,

    [Parameter(Mandatory = $false)]
    [string] $targetFramework,

    [Parameter(Mandatory = $false)]
    [string] $artifactUrl,

    [Parameter(Mandatory = $false)]
    [string] $copsFolder
)

# Exit immediately when not running in GitHub Actions.
$githubActionsValue = $ENV:GITHUB_ACTIONS
if ([string]::IsNullOrWhiteSpace($githubActionsValue) -or ($githubActionsValue.Trim().ToLowerInvariant() -eq "false")) {
    return
}

$ErrorActionPreference = "Stop"
$ScriptVersion = "1.1.0"

Write-Host "Install-ALCops v$ScriptVersion"

# ── Validate mutually exclusive parameters ───────────────────────────
if ($targetFramework -and $artifactUrl) {
    throw "Parameters 'targetFramework' and 'artifactUrl' are mutually exclusive. Provide one or the other, not both."
}

# ── Resolve defaults ─────────────────────────────────────────────────
if (-not $packageName) {
    $packageName = "ALCops.Analyzers"
}

# ── Detect TFM from artifact URL ────────────────────────────────────
if ($artifactUrl) {
    Write-Host "Detecting target framework from BC artifact URL..."
    Write-Host "  Artifact URL: $artifactUrl"

    $npxStderr = $null
    $jsonOutput = npx --yes @alcops/core detect-tfm bc-artifact $artifactUrl 2>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) {
            $npxStderr += $_.ToString() + "`n"
        } else {
            $_
        }
    }
    if ($LASTEXITCODE -ne 0) {
        throw "TFM detection failed (exit code $LASTEXITCODE): $npxStderr $jsonOutput"
    }

    $detection = $jsonOutput | ConvertFrom-Json
    $targetFramework = $detection.tfm

    if (-not $targetFramework) {
        throw "TFM detection returned no 'tfm' value. Raw output: $jsonOutput"
    }

    Write-Host "  Detected TFM: $targetFramework (source: $($detection.source), details: $($detection.details))"
}

if (-not $targetFramework) {
    $targetFramework = "net8.0"
}

if (-not $copsFolder) {
    $copsFolder = Join-Path $ENV:GITHUB_WORKSPACE ".alcops"
}

# ── Resolve NuGet package version ────────────────────────────────────
function Resolve-NuGetPackageVersion {
    param(
        [string] $id,
        [string] $requested
    )

    $indexUrl = "https://api.nuget.org/v3-flatcontainer/$($id.ToLowerInvariant())/index.json"
    Write-Host "Querying NuGet package index: $indexUrl"

    $response = Invoke-RestMethod -Uri $indexUrl -UseBasicParsing
    [string[]] $versions = $response.versions

    if (-not $versions -or $versions.Count -eq 0) {
        throw "Package '$id' not found on nuget.org."
    }

    switch -Exact ($requested.ToLowerInvariant()) {
        "" {
            # Latest stable: exclude any version containing a hyphen (prerelease)
            $stable = $versions | Where-Object { $_ -notmatch '-' }
            if (-not $stable) { throw "No stable version found for '$id'." }
            return ($stable | Select-Object -Last 1)
        }
        "alpha" {
            $matched = $versions | Where-Object { $_ -match '-alpha' }
            if (-not $matched) { throw "No alpha version found for '$id'." }
            return ($matched | Select-Object -Last 1)
        }
        "beta" {
            $matched = $versions | Where-Object { $_ -match '-beta' }
            if (-not $matched) { throw "No beta version found for '$id'." }
            return ($matched | Select-Object -Last 1)
        }
        default {
            # Exact version requested
            if ($versions -contains $requested.ToLowerInvariant()) {
                return $requested.ToLowerInvariant()
            }
            throw "Version '$requested' not found for '$id'. Available versions: $($versions[-5..-1] -join ', ') ..."
        }
    }
}

$resolvedVersion = Resolve-NuGetPackageVersion -id $packageName -requested $packageVersion
Write-Host "Resolved version: $resolvedVersion"

# ── Check if already downloaded ──────────────────────────────────────
$versionMarker = Join-Path $copsFolder ".version"
if ((Test-Path $versionMarker) -and ((Get-Content $versionMarker -Raw).Trim() -eq $resolvedVersion)) {
    Write-Host "ALCops $resolvedVersion already present in $copsFolder, skipping download."
    Get-ChildItem $copsFolder -Filter "*.dll" | ForEach-Object { Write-Host "  $_" }
    return
}

# ── Download .nupkg ──────────────────────────────────────────────────
$pkgIdLower = $packageName.ToLowerInvariant()
$nupkgUrl = "https://api.nuget.org/v3-flatcontainer/$pkgIdLower/$resolvedVersion/$pkgIdLower.$resolvedVersion.nupkg"
$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "alcops-$([guid]::NewGuid().ToString('N'))"
$nupkgPath = Join-Path $tempDir "$pkgIdLower.$resolvedVersion.nupkg"

New-Item -Path $tempDir -ItemType Directory -Force | Out-Null
Write-Host "Downloading $nupkgUrl ..."
Invoke-WebRequest -Uri $nupkgUrl -OutFile $nupkgPath -UseBasicParsing

# ── Extract and copy target framework DLLs ───────────────────────────
$extractPath = Join-Path $tempDir "extracted"
Write-Host "Extracting NuGet package..."
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::ExtractToDirectory($nupkgPath, $extractPath)

$libFolder = Join-Path $extractPath "lib/$targetFramework"
if (-not (Test-Path $libFolder)) {
    $availableFrameworks = @(Get-ChildItem (Join-Path $extractPath "lib") -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    Remove-Item $tempDir -Recurse -Force
    throw "Target framework '$targetFramework' not found in package. Available: $($availableFrameworks -join ', ')"
}

$dlls = @(Get-ChildItem $libFolder -Filter "*.dll")
if ($dlls.Count -eq 0) {
    Remove-Item $tempDir -Recurse -Force
    throw "No .dll files found in lib/$targetFramework."
}

# ── Copy to copsFolder (clean destination first) ─────────────────────
if (Test-Path $copsFolder) {
    Remove-Item $copsFolder -Recurse -Force
}
New-Item -Path $copsFolder -ItemType Directory -Force | Out-Null

Copy-Item -Path "$libFolder/*" -Destination $copsFolder -Recurse -Force

# Write version marker for cache detection
Set-Content -Path $versionMarker -Value $resolvedVersion -NoNewline

# ── Cleanup temp ─────────────────────────────────────────────────────
Remove-Item $tempDir -Recurse -Force

# ── Report ───────────────────────────────────────────────────────────
Write-Host "Installed $($dlls.Count) analyzer DLL(s) to $copsFolder :"
Get-ChildItem $copsFolder -Filter "*.dll" | ForEach-Object { Write-Host "  $($_.Name)" }