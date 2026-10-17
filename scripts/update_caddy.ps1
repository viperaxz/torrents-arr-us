# update_caddy.ps1
# Per-app update script: Caddy (Chocolatey + config validate/restart).
# The Caddyfile, CrowdSec integration, cert cache, and DNS updater tasks live
# outside the choco package, so a plain upgrade is safe: the existing Caddyfile
# stays valid across Caddy minor/patch bumps.  The new build validates it before
# the service is restarted, and the running process is probed afterwards.
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$InstallDir,
    [Parameter(Mandatory = $true)][string]$BinDir,
    [object]$Config,
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "update_common.ps1")
# Bounded stop/start: nssm services wedge in Stop Pending and Restart-Service waits
# on that indefinitely.  Same helpers the install path uses.
. (Join-Path $PSScriptRoot "service_helpers.ps1")
$Config = Initialize-UpdateScript -Config $Config

$AppName = "Caddy"

function Invoke-CaddyDowngrade {
    # Restores the previously installed build.  Chocolatey has already replaced the
    # binary on disk by the time a failure is detected, so only a downgrade makes the
    # next service start come up on a build that actually works.
    param([string]$Version)
    if (-not $Version -or $Version -ieq "unknown" -or -not (Test-VersionLike -Value $Version)) {
        Write-UcLog "WARN" "No usable previous version recorded; cannot roll back"
        return $false
    }
    $result = Invoke-Choco -Arguments @('install', 'caddy', '--version', $Version, '--allow-downgrade', '-y', '--no-progress')
    if (-not $result.Ran -or $result.ExitCode -ne 0) {
        Write-UcLog "ERROR" "Downgrade to caddy $Version failed (exit $($result.ExitCode))"
        return $false
    }
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path", "User")
    Write-UcLog "INFO" "Downgraded caddy to $Version"
    return $true
}

function Test-CaddyHealth {
    # The admin API (127.0.0.1:2019 by default) answers only once the process has
    # started and loaded its config, which is what "Running" cannot tell us.  A
    # Caddyfile with 'admin off' has no admin API, so fall back to a TCP probe on
    # :443 -- a crash-looping caddy.exe never binds it either.
    param([int]$BudgetSeconds = 20)
    $deadline = (Get-Date).AddSeconds($BudgetSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $probe = Invoke-WebRequest -Uri "http://127.0.0.1:2019/config/" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
            if ($probe.StatusCode -ge 200 -and $probe.StatusCode -lt 300) { return $true }
        } catch {}
        Start-Sleep -Seconds 2
    }
    $client = New-Object System.Net.Sockets.TcpClient
    $listening = $false
    try {
        $async = $client.BeginConnect("127.0.0.1", 443, $null, $null)
        $listening = [bool]($async.AsyncWaitHandle.WaitOne(2000) -and $client.Connected)
    } catch {
        $listening = $false
    } finally {
        $client.Close()
    }
    if (-not $listening) { Write-UcLog "WARN" "Caddy admin API and :443 both silent after the upgrade" }
    return $listening
}

$installed = Get-InstalledVersion -InstallDir $InstallDir -AppName $AppName

if ($WhatIf) {
    return [PSCustomObject]@{ App = $AppName; Status = "DRYRUN"; Installed = $installed; Target = $Version; Detail = "choco upgrade caddy + restart service" }
}
if (-not $installed -or $installed -ieq "unknown") {
    return [PSCustomObject]@{ App = $AppName; Status = "SKIPPED"; Installed = $installed; Target = $Version; Detail = "not installed or installed version unknown" }
}

try {
    Invoke-ChocoUpgrade -Package "caddy" -Version $Version

    $caddyExe = (Get-Command caddy.exe -ErrorAction SilentlyContinue).Source
    if (-not $caddyExe) { throw "caddy.exe not found in PATH after upgrade" }

    # Locate the existing Caddyfile (untouched by choco).
    $caddyfile = Join-Path $InstallDir "Caddy\Caddyfile"
    if (-not (Test-Path $caddyfile)) {
        throw "Caddyfile not found at $caddyfile -- re-run .\master_install.ps1 to regenerate it"
    }

    # Validate with the build that was just installed, before anything is restarted.
    # caddy writes JSON logs to stderr even on success, so stderr is captured rather
    # than surfaced as a NativeCommandError under EAP=Stop.
    # The service check below cannot catch a config error: NSSM keeps restarting a
    # crashing caddy.exe and the service still reports Running, so an upgrade that
    # rejects the existing Caddyfile would be recorded as successful with Caddy down.
    $savedEap    = $ErrorActionPreference
    $validateOut = ""
    $validateExit = 1
    try {
        $ErrorActionPreference = "Continue"
        $validateOut  = (& $caddyExe validate --adapter caddyfile --config $caddyfile 2>&1 | Out-String).Trim()
        $validateExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedEap
    }
    if ($validateExit -ne 0) {
        $detail = "caddy $Version rejects the Caddyfile (validate exit $validateExit): $validateOut"
        Write-UcLog "ERROR" $detail
        if (Invoke-CaddyDowngrade -Version $installed) {
            return [PSCustomObject]@{ App = $AppName; Status = "ROLLBACK"; Installed = $installed; Target = $Version; Detail = "$detail -- previous build $installed restored" }
        }
        throw "$detail -- and the downgrade to $installed failed"
    }

    # Chocolatey only swaps caddy.exe on disk -- the NSSM service keeps running the
    # old image, so the running process has to be replaced for the upgrade to take
    # effect.  Bounded, because a wedged stop otherwise hangs the whole update run.
    if (-not (Restart-ServiceBounded -Name "Caddy" -StopTimeoutSeconds 60 -StartTimeoutSeconds 90)) {
        $detail = "Caddy service did not reach Running after the upgrade"
        Write-UcLog "ERROR" $detail
        if (Invoke-CaddyDowngrade -Version $installed) {
            $recovered = Restart-ServiceBounded -Name "Caddy" -StopTimeoutSeconds 60 -StartTimeoutSeconds 90
            $status    = if ($recovered) { "ROLLBACK" } else { "FAILED" }
            $note      = if ($recovered) { "previous build $installed restored" } else { "previous build $installed restored but the service did not come back" }
            return [PSCustomObject]@{ App = $AppName; Status = $status; Installed = $installed; Target = $Version; Detail = "$detail -- $note" }
        }
        throw $detail
    }

    # Running is not healthy: probe the new process, and roll back when it never
    # comes up.  Without this a rejected Caddyfile or an unbindable port is recorded
    # as a successful upgrade.
    if (-not (Test-CaddyHealth)) {
        $detail = "Caddy did not answer on its admin API or :443 after the upgrade"
        Write-UcLog "ERROR" $detail
        if (Invoke-CaddyDowngrade -Version $installed) {
            $recovered = Restart-ServiceBounded -Name "Caddy" -StopTimeoutSeconds 60 -StartTimeoutSeconds 90
            $status    = if ($recovered) { "ROLLBACK" } else { "FAILED" }
            $note      = if ($recovered) { "previous build $installed restored" } else { "previous build $installed restored but the service did not come back" }
            return [PSCustomObject]@{ App = $AppName; Status = $status; Installed = $installed; Target = $Version; Detail = "$detail -- $note" }
        }
        throw $detail
    }

    Set-InstalledVersion -InstallDir $InstallDir -AppName $AppName -Version $Version
    return [PSCustomObject]@{ App = $AppName; Status = "OK"; Installed = $installed; Target = $Version; Detail = "" }
} catch {
    return [PSCustomObject]@{ App = $AppName; Status = "FAILED"; Installed = $installed; Target = $Version; Detail = $_.Exception.Message }
}
