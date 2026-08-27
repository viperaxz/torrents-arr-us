#Requires -RunAsAdministrator

# "Continue" (not "SilentlyContinue"): disabling should surface failures so
# the operator knows what could not be cleaned up. Each fallible call still
# uses -ErrorAction SilentlyContinue individually where a failure is non-fatal.
$ErrorActionPreference = "Continue"

$ConfigPath = Join-Path $PSScriptRoot "config.json"
if (Test-Path $ConfigPath) {
    $Config     = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    $InstallDir = $Config.General.InstallDir
    $DomainMode = $Config.General.DomainMode
} else {
    $InstallDir = "C:\MediaServer"
    $DomainMode = "cloudflare"
    $Config     = $null
    Write-Warning "config.json not found. Using default InstallDir: $InstallDir"
}

$LockFile = Join-Path $InstallDir ".locks\.grafana.lock"
if (-not (Test-Path $LockFile)) {
    Write-Host "Grafana is not installed. Nothing to disable." -ForegroundColor Yellow
    exit 0
}

Write-Host ""
Write-Host "Disabling Grafana + Loki + Alloy..." -ForegroundColor Cyan
Write-Host ""

# -- 1. Stop and remove NSSM services -----------------------------------------
foreach ($svcName in @("Grafana", "Loki", "Alloy")) {
    $svc = Get-Service $svcName -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Host "  -> $svcName : stopping..." -ForegroundColor Yellow
        Stop-Service $svcName -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        & nssm remove $svcName confirm 2>$null | Out-Null
        Write-Host "  -> $svcName : removed." -ForegroundColor Yellow
    }
}

# -- 2. Remove Grafana route from Caddyfile ------------------------------------
$caddyExe      = (Get-Command caddy.exe -ErrorAction SilentlyContinue).Source
$CaddyfilePath = Join-Path $InstallDir "Caddy\Caddyfile"

if ((Test-Path $CaddyfilePath) -and $caddyExe -and $Config) {
    $caddyContent = Get-Content $CaddyfilePath -Raw -Encoding UTF8

    if ($DomainMode -eq "cloudflare") {
        $Domain = $Config.General.Domain
        $before = $caddyContent.Length
        # Remove the entire grafana.domain server block including nested braces.
        # Parse line by line: track brace depth, drop from "# Grafana" through the
        # matching closing brace at depth 0.
        $lines    = $caddyContent -split '\r?\n'
        $out      = [System.Collections.Generic.List[string]]::new()
        $inBlock  = $false
        $depth    = 0
        $blockStartMarker = "# Grafana"
        foreach ($line in $lines) {
            if (-not $inBlock -and $line.Trim() -eq $blockStartMarker) {
                $inBlock = $true
                continue
            }
            if (-not $inBlock) {
                $out.Add($line)
                continue
            }
            # Count braces on this line to track nesting depth
            $opens  = ([regex]::Matches($line, '\{')).Count
            $closes = ([regex]::Matches($line, '\}')).Count
            $depth += $opens - $closes
            if ($depth -le 0) {
                $inBlock = $false
            }
        }
        $caddyContent = ($out -join "`r`n")
        if ($caddyContent.Length -ne $before) {
            Write-Host "  -> Grafana subdomain block removed from Caddyfile." -ForegroundColor Yellow
        }
    } else {
        $before = $caddyContent.Length
        # Remove handle /grafana* block (flat, no nested braces inside handle)
        $caddyContent = [regex]::Replace(
            $caddyContent,
            "(?ms)[ \t]*handle /grafana\* \{[ \t]*\r?\n[ \t]*reverse_proxy[^\r\n]+\r?\n[ \t]*\}\r?\n(\r?\n)?",
            ""
        )
        if ($caddyContent.Length -ne $before) {
            Write-Host "  -> Grafana handle removed from Caddyfile." -ForegroundColor Yellow
        }
    }

    # BOM-free -- parsed by Caddy (Go), see 01_webserver.ps1.
    [System.IO.File]::WriteAllText($CaddyfilePath, $caddyContent, (New-Object System.Text.UTF8Encoding($false)))
    try { & $caddyExe fmt --overwrite $CaddyfilePath 2>&1 | Out-Null } catch {}
    # Caddy writes JSON logs to stderr even on success; PS 5.1 with $ErrorActionPreference="Continue"
    # (set at the top of this script) won't throw, but the catch block is still needed in case
    # the user or a parent script sets EAP to "Stop".
    try { & $caddyExe reload --config $CaddyfilePath 2>&1 | Out-Null } catch {}
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "  -> Caddy reload failed (exit $LASTEXITCODE). Restarting Caddy service instead..."
        Restart-Service -Name "Caddy" -Force -ErrorAction SilentlyContinue
        $caddySvc = Get-Service -Name "Caddy" -ErrorAction SilentlyContinue
        if ($caddySvc -and $caddySvc.Status -eq "Running") {
            Write-Host "  -> Caddy restarted successfully." -ForegroundColor Yellow
        } else {
            Write-Warning "  -> Caddy restart may have failed. Check services manually."
        }
    } else {
        Write-Host "  -> Caddy reloaded." -ForegroundColor Yellow
    }
}

# -- 3. Remove grafana subdomain from Cloudflare DNS updater ------------------
if ($Config -and $DomainMode -eq "cloudflare") {
    $updaterPath = Join-Path $InstallDir "Update-CloudflareDNS.ps1"
    if ((Test-Path $updaterPath) -and ((Get-Content $updaterPath -Raw) -match '"grafana"')) {
        $u = Get-Content $updaterPath -Raw -Encoding UTF8
        $u = $u -replace ',"grafana"', '' -replace '"grafana",', ''
        Set-Content $updaterPath $u -Encoding UTF8
        Write-Host "  -> grafana removed from Cloudflare DNS updater." -ForegroundColor Yellow
    }
}

# -- 4. Remove app directories -------------------------------------------------
foreach ($sub in @("Grafana", "Grafana-data", "Loki", "Loki-data", "Alloy", "Alloy-data")) {
    $path = Join-Path $InstallDir $sub
    if (Test-Path $path) {
        Remove-Item $path -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  -> Removed: $path" -ForegroundColor Yellow
    }
}

# -- 5. Remove lock file -------------------------------------------------------
Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
Write-Host "  -> Lock file removed." -ForegroundColor Yellow

# -- 6. Update config.json: Apps.Grafana = false -------------------------------
if (Test-Path $ConfigPath) {
    $raw = Get-Content $ConfigPath -Raw -Encoding UTF8
    if ($raw -match '"Grafana"\s*:\s*(true|false)') {
        $raw = [regex]::Replace($raw, '"Grafana"\s*:\s*(true|false)', '"Grafana": false')
        # BOM-free: config.json is only read by ConvertFrom-Json. Consistent with
        # grafana_enable.ps1 which also writes config.json BOM-free.
        [System.IO.File]::WriteAllText($ConfigPath, $raw, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "  -> config.json: Apps.Grafana = false" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "Grafana disabled successfully." -ForegroundColor Green
