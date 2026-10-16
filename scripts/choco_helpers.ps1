# choco_helpers.ps1 -- shared Chocolatey helpers.
#
# Dot-source this from any script that shells out to choco:
#     . (Join-Path $PSScriptRoot "choco_helpers.ps1")
#
# Two problems it solves, both hit for real on a live install:
#
# 1. PATH. A shell opened BEFORE Chocolatey was installed does not see
#    chocolatey\bin even though the Machine PATH now names it, because a process
#    reads PATH only at startup. `choco` then dies with
#    "The term 'choco' is not recognized" and aborts the caller mid-phase --
#    master_uninstall.ps1 aborted at step 7 of 8 for exactly this reason.
#    Resolve-ChocoExe looks at the known install path and re-reads the registry
#    instead of trusting $env:Path.
#
# 2. Transient feed failures. community.chocolatey.org is CDN-fronted and
#    intermittently answers 503 Service Unavailable / 504 Gateway Timeout, or
#    stops responding on its OData query endpoints entirely. `choco install
#    <id>` needs that query to resolve a package, so a ~30 second upstream blip
#    aborts an otherwise healthy 40-minute install. Worse, Chocolatey prints
#    "Chocolatey installed 0/0 packages." and still exits 0 in that situation,
#    so the exit code alone must never be trusted -- the caller has to verify.
#    Invoke-Choco retries the transient class with exponential backoff and
#    captures the output, which the installers previously discarded with
#    "| Out-Null" so the real reason never reached the debug log.

function Resolve-ChocoExe {
    # Returns the full path to choco.exe, or $null when Chocolatey is absent.
    param([string]$Explicit)

    if ($Explicit -and (Test-Path -LiteralPath $Explicit)) { return $Explicit }

    $cmd = Get-Command choco.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    # Standard install location. ChocolateyInstall is process-scoped, so it is
    # only set in a shell that the installer itself started.
    $candidates = @(
        (Join-Path $env:ProgramData 'chocolatey\bin\choco.exe')
        'C:\ProgramData\chocolatey\bin\choco.exe'
    )
    if ($env:ChocolateyInstall) {
        $candidates += (Join-Path $env:ChocolateyInstall 'bin\choco.exe')
    }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }

    # Last resort: rebuild PATH from the registry (Machine + User) and retry.
    try {
        $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
        $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
        $cmd = Get-Command choco.exe -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    } catch {
        # Non-fatal: fall through and report absence.
    }
    return $null
}

function Test-ChocoOutputTransient {
    # True when choco's output looks like a retryable upstream/CDN failure
    # rather than a genuine packaging error.
    #
    # Every pattern here was taken from the REAL choco client's output, not
    # invented. Two signatures matter most:
    #   * "Failed to fetch results from V2 feed ... 503 (Service Unavailable)"
    #     -- the actual outage that broke the install.
    #   * "Unable to load the service index for source ..." + "A connection
    #     attempt failed ..." -- emitted when the feed is entirely unreachable.
    #     Verified against a blackholed source: choco prints both lines and
    #     STILL EXITS 0, so pattern matching is the only signal available.
    # Deliberately absent: bad package id, checksum mismatch, and install-script
    # errors, all of which must fail fast instead of being retried.
    param([string]$Output)
    if ([string]::IsNullOrWhiteSpace($Output)) { return $false }

    $patterns = @(
        '\b50[234]\b'                          # 502/503/504, e.g. "503 (Service Unavailable)"
        'Service Unavailable'
        'Bad Gateway'
        'Gateway Timeout'
        '\b429\b'
        'Too Many Requests'
        'Failed to fetch results from V2 feed'
        'Unable to load the service index'
        'A connection attempt failed'
        'failed to respond after a period of time'
        'connected host has failed to respond'
        'Unable to connect to the remote server'
        'No connection could be made'
        'actively refused it'
        'The underlying connection was closed'
        'An error occurred while sending the request'
        'The operation has timed out'
        'could not be resolved'
        'The SSL connection could not be established'
        'The request was aborted'
        'Unable to obtain a new version'
    )
    foreach ($p in $patterns) {
        if ($Output -match $p) { return $true }
    }
    return $false
}

function Test-ChocoRetryable {
    # Decides whether a choco run is worth repeating.
    #
    # Retries the known-transient class. Also retries a failure whose output is
    # EMPTY: during the real outage `choco install caddy` exited 1 and produced
    # no captured output at all (the installer's own "VAR choco caddy output="
    # debug line was blank), so there was nothing to pattern-match on. Repeating
    # is the only sensible move when we have no evidence either way, and a
    # genuinely permanent failure merely costs a few bounded sleeps before the
    # caller's post-install verification reports it as it already does.
    param([string]$Output, [int]$ExitCode = 0)
    if (Test-ChocoOutputTransient -Output $Output) { return $true }
    if ($ExitCode -ne 0 -and [string]::IsNullOrWhiteSpace($Output)) { return $true }
    return $false
}

function Invoke-Choco {
    <#
    .SYNOPSIS
        Runs choco with retry-on-transient-failure and captured output.
    .DESCRIPTION
        Never throws for a non-zero exit code -- the caller decides what a
        failure means, because choco's exit code is not authoritative (it
        returns 0 after installing nothing when the feed is unreachable).
        The returned object is:
            ExitCode  : choco's exit code (or -1 when it could not be run)
            Output    : combined stdout+stderr, always captured
            Attempts  : how many runs were needed
            Transient : $true when the last failure looked retryable
            Ran       : $false when choco.exe could not be found

        Default MaxAttempts is 6 rather than 4 because the upstream flakiness is
        severe: measured against the live feed, one package query failed 5 times
        out of 8 for winfsp and 2 of 8 for python312. At that rate 4 attempts
        still fails ~15% of the time and 6 brings it under ~6%.

        Cost is asymmetric. A CDN blip (503/504) fails in about a second, so the
        retries are nearly free. A source that is entirely unreachable costs
        ~140s per attempt, because that wait is choco's own HTTP timeout, not
        something this helper controls -- so a blackholed feed takes roughly 14
        minutes before failing loudly. That is deliberate: loud and slow beats
        the alternative of silently installing nothing.
    #>
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [int]$MaxAttempts = 6,
        [int]$InitialDelaySec = 5,
        [int]$MaxDelaySec = 60,
        # Set to suppress the per-attempt notice for expected-failure probes
        # such as a version-detection query.
        [switch]$Quiet
    )

    $exe = Resolve-ChocoExe
    if (-not $exe) {
        return [PSCustomObject]@{
            ExitCode = -1; Output = 'choco.exe not found'; Attempts = 0
            Transient = $false; Ran = $false
        }
    }

    $delay    = $InitialDelaySec
    $attempt  = 0
    $output   = ''
    $code     = -1

    while ($attempt -lt $MaxAttempts) {
        $attempt++
        $attemptSw = [Diagnostics.Stopwatch]::StartNew()
        $savedEap = $ErrorActionPreference
        try {
            # choco writes warnings (pending reboot, deprecation notices) to
            # stderr on otherwise successful runs; under EAP=Stop that becomes a
            # terminating NativeCommandError, so relax it for the call.
            $ErrorActionPreference = 'Continue'
            $output = (& $exe @Arguments 2>&1 | Out-String)
            $code   = $LASTEXITCODE
        } catch {
            $output = "could not run choco: $($_.Exception.Message)"
            $code   = -1
        } finally {
            $ErrorActionPreference = $savedEap
        }
        $attemptSw.Stop()

        $retryable = Test-ChocoRetryable -Output $output -ExitCode $code
        if (-not $retryable -or $attempt -ge $MaxAttempts) { break }

        if (-not $Quiet) {
            # Report how long the failed attempt itself took. ~1s means the
            # fast CDN blip that broke the install and recovers immediately; a
            # ~140s attempt means the source is blackholed and the wait is
            # choco's own network timeout, not a hang.
            Write-Host "  choco: transient failure after $([math]::Round($attemptSw.Elapsed.TotalSeconds,1))s (attempt $attempt/$MaxAttempts) -- retrying in ${delay}s" -ForegroundColor Yellow
        }
        Start-Sleep -Seconds $delay
        $delay = [Math]::Min($delay * 2, $MaxDelaySec)
    }

    return [PSCustomObject]@{
        ExitCode  = $code
        Output    = $output
        Attempts  = $attempt
        Transient = (Test-ChocoRetryable -Output $output -ExitCode $code)
        Ran       = $true
    }
}

function Get-ChocoInstalledVersion {
    # Local-only lookup by exact package id. Always local: the remote query is
    # the part that breaks, and the callers all want "what is on this machine".
    # Returns "<version>", "unknown" (listed but unparseable) or $null (absent),
    # matching the contract the installers already depend on.
    param(
        [Parameter(Mandatory = $true)][string]$Package
    )
    $r = Invoke-Choco -Arguments @('list', '--local-only', '--exact', $Package, '-r') -Quiet -MaxAttempts 2
    if (-not $r.Ran) { return $null }
    $text = ($r.Output -split "`n" | Where-Object { $_ -match '\|' } | Select-Object -First 1)
    if (-not $text) { return $null }
    $parts = $text.Trim() -split '\|'
    if ($parts.Count -lt 2) { return 'unknown' }
    $v = $parts[1].Trim()
    if ([string]::IsNullOrWhiteSpace($v)) { return 'unknown' }
    return $v
}
