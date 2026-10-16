# bump_versions.ps1
# Maintainer tool: refreshes versions.json from upstream releases.
#
# For each app in the manifest, queries the matching upstream for the latest
# recommended version and rewrites versions.json when anything changed.
#
# Usage:
#   .\scripts\bump_versions.ps1 -DryRun          # print changes only
#   .\scripts\bump_versions.ps1                  # apply changes
#   .\scripts\bump_versions.ps1 -Skip Zurg,rclone
#   .\scripts\bump_versions.ps1 -Security Sonarr
#
# Default skip list: apps whose updates need manual re-verification before
# being recommended to users (Zurg: __all__ mount workaround).
param(
    [switch]$DryRun,
    [string[]]$Skip = @("Zurg"),
    [string[]]$Security = @()
)

$ErrorActionPreference = "Stop"

$ProjectRoot  = Split-Path -Parent $PSScriptRoot
$ManifestPath = Join-Path $ProjectRoot "versions.json"
if (-not (Test-Path $ManifestPath)) {
    Write-Error "versions.json not found at $ManifestPath"
    exit 1
}
$Manifest = Get-Content -Raw -Path $ManifestPath | ConvertFrom-Json

$Headers = @{ "User-Agent" = "win-seedbox-maintainer" }

function Get-LatestGithubTag {
    param([Parameter(Mandatory = $true)][string]$Repo)
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" `
                   -Headers $Headers -UseBasicParsing -ErrorAction Stop
    return $release.tag_name
}

function Get-LatestChocoVersion {
    param([Parameter(Mandatory = $true)][string]$Package)
    # Method 1: OData filter (fast; pagination followed when the first page
    # contains no matching entry).
    $urls = [System.Collections.Generic.List[string]]::new()
    $urls.Add("https://community.chocolatey.org/api/v2/Packages()?`$filter=IsLatestVersion and Id eq '$Package'")
    $i = 0
    while ($i -lt $urls.Count) {
        $url = $urls[$i]
        $i++
        $raw = (Invoke-WebRequest -Uri $url -UseBasicParsing -ErrorAction Stop).Content
        $m = [regex]::Match($raw, "Version='([^']+)'")
        if ($m.Success) { return $m.Groups[1].Value }
        $next = [regex]::Match($raw, 'rel="next" href="([^"]+)"')
        if ($next.Success) {
            $urls.Add([System.Net.WebUtility]::HtmlDecode($next.Groups[1].Value))
        }
    }

    # Method 2: Search endpoint fallback (some packages do not surface through
    # the Packages() filter).  Match entries by exact package title.
    $raw = (Invoke-WebRequest "https://community.chocolatey.org/api/v2/Search()?searchTerm='$Package'&targetFramework=''&includePrerelease=false" `
                -UseBasicParsing -ErrorAction Stop).Content
    $entries = [regex]::Matches($raw, '<entry>(?s:.*?)</entry>')
    foreach ($e in $entries) {
        $block = $e.Value
        if ($block -notmatch "<title type=""text"">$([regex]::Escape($Package))</title>") { continue }
        $vm = [regex]::Match($block, "<d:Version[^>]*>([^<]+)</d:Version>")
        if ($vm.Success) { return $vm.Groups[1].Value }
    }
    throw "No version found for choco package $Package"
}

function Get-LatestGrafanaStable {
    $info = Invoke-RestMethod -Uri "https://grafana.com/api/grafana/versions/stable" -UseBasicParsing -ErrorAction Stop
    return $info.version
}

Write-Host "Bump check for versions.json (schema $($Manifest.schema))..." -ForegroundColor Cyan

$changes = [System.Collections.Generic.List[object]]::new()

foreach ($prop in $Manifest.apps.PSObject.Properties) {
    $app   = $prop.Name
    $entry = $prop.Value
    if ($app -in $Skip) {
        Write-Host ("  {0,-18} skipped (default skip list)" -f $app) -ForegroundColor DarkGray
        continue
    }

    $current = $entry.version
    $latest  = $null
    try {
        switch ($entry.source) {
            "github"         { $latest = Get-LatestGithubTag $entry.repo }
            "github_source"  { $latest = Get-LatestGithubTag $entry.repo }
            "chocolatey"     { $latest = Get-LatestChocoVersion $entry.package }
            "dl.grafana.com" { $latest = Get-LatestGrafanaStable }
            default          { Write-Host ("  {0,-18} unknown source '{1}'" -f $app, $entry.source) -ForegroundColor DarkGray }
        }
    } catch {
        Write-Warning "Could not query $app : $_"
        continue
    }
    if (-not $latest) { continue }

    if ($latest -ne $current) {
        $changes.Add([PSCustomObject]@{ App = $app; Old = $current; New = $latest })
        $entry.version = $latest
    } else {
        Write-Host ("  {0,-18} current: {1}" -f $app, $current) -ForegroundColor DarkGray
    }
}

# -- Security flags -----------------------------------------------------------
foreach ($prop in $Manifest.apps.PSObject.Properties) {
    $entry = $prop.Value
    $flag  = ($prop.Name -in $Security)
    if ($entry.PSObject.Properties["security"]) {
        $entry.security = $flag
    } elseif ($flag) {
        $entry | Add-Member -MemberType NoteProperty -Name "security" -Value $true -Force
    }
}

if ($changes.Count -eq 0) {
    Write-Host ""
    Write-Host "No version changes." -ForegroundColor Green
    exit 0
}

Write-Host ""
Write-Host "Version changes:" -ForegroundColor Yellow
foreach ($c in $changes) {
    Write-Host ("  {0,-18} {1} -> {2}" -f $c.App, $c.Old, $c.New) -ForegroundColor Yellow
}
$Manifest.updated = Get-Date -Format "yyyy-MM-dd"

if ($DryRun) {
    Write-Host ""
    Write-Host "Dry run: no changes written." -ForegroundColor Yellow
    exit 0
}

$json = $Manifest | ConvertTo-Json -Depth 6
[System.IO.File]::WriteAllText($ManifestPath, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))
Write-Host ""
Write-Host "versions.json updated (schema $($Manifest.schema), updated $($Manifest.updated))." -ForegroundColor Green
