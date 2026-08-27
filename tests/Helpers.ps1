# tests/Helpers.ps1 -- shared utilities for the win-seedbox test suite
# Dot-sourced by test-suite.ps1 and by each Test-*.ps1 module (safe to dot-source multiple times).

function New-TestResult {
    param(
        [string]$Service,
        [int]$Layer,
        [string]$Test,
        [ValidateSet('PASS','FAIL','WARN','SKIP')]
        [string]$Status,
        [string]$Message = '',
        [int]$DurationMs = 0
    )
    [PSCustomObject]@{
        service     = $Service
        layer       = $Layer
        test        = $Test
        status      = $Status
        message     = $Message
        duration_ms = $DurationMs
    }
}

# Async TCP connect with timeout (does not require netstat or admin rights)
function Test-TcpPort {
    param([int]$Port, [int]$TimeoutMs = 2000)
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $ar  = $tcp.BeginConnect('127.0.0.1', $Port, $null, $null)
        $ok  = $ar.AsyncWaitHandle.WaitOne($TimeoutMs)
        if ($ok -and $tcp.Connected) { $tcp.EndConnect($ar); $tcp.Close(); return $true }
        $tcp.Close()
        return $false
    } catch { return $false }
}

# Timed REST GET -- returns {ok, latency_ms, data, error}
function Invoke-ApiCheck {
    param(
        [string]$Uri,
        [hashtable]$Headers  = @{},
        [int]$TimeoutSec     = 5,
        [string]$Method      = 'GET',
        [string]$Body        = $null,
        [string]$ContentType = 'application/json'
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $params = @{
            Uri             = $Uri
            Method          = $Method
            Headers         = $Headers
            UseBasicParsing = $true
            TimeoutSec      = $TimeoutSec
            ErrorAction     = 'Stop'
        }
        if ($Body) { $params.Body = $Body; $params.ContentType = $ContentType }
        $r = Invoke-RestMethod @params
        $sw.Stop()
        return [PSCustomObject]@{ ok = $true;  latency_ms = [int]$sw.ElapsedMilliseconds; data = $r;    error = $null }
    } catch {
        $sw.Stop()
        return [PSCustomObject]@{ ok = $false; latency_ms = [int]$sw.ElapsedMilliseconds; data = $null; error = $_.Exception.Message }
    }
}

# Read API key from *Arr config.xml
function Get-XmlApiKey {
    param([string]$Path)
    try { return ([xml](Get-Content $Path -ErrorAction Stop)).Config.ApiKey } catch { return $null }
}

# Read Bazarr API key from config.yaml
function Get-BazarrApiKey {
    param([string]$Path = 'C:\ProgramData\Bazarr\config\config.yaml')
    try {
        $yaml = Get-Content $Path -Raw -ErrorAction Stop
        if ($yaml -match '(?m)^\s*apikey\s*:\s*["'']?([^"''\r\n]+)["'']?') { return $Matches[1].Trim() }
    } catch {}
    return $null
}

# Returns "" or "/sonarr" etc. depending on DomainMode
function Get-AppUrlBase {
    param([string]$AppName, [string]$DomainMode)
    if ($DomainMode -eq 'duckdns') { return "/$($AppName.ToLower())" } else { return '' }
}

# Record current end-of-file position before running tests
function Get-LogPosition {
    param([string]$LogPath)
    if (Test-Path $LogPath) { try { return (Get-Item $LogPath -ErrorAction Stop).Length } catch {} }
    return 0
}

# Return lines added to the log since the recorded position that contain ERROR/FATAL/CRITICAL
function Get-NewLogErrors {
    param([string]$LogPath, [long]$Position)
    if (-not (Test-Path $LogPath)) { return @() }
    try {
        $size = (Get-Item $LogPath -ErrorAction Stop).Length
        if ($size -le $Position) { return @() }
        $fs     = [System.IO.File]::Open($LogPath, 'Open', 'Read', 'ReadWrite')
        $null   = $fs.Seek($Position, 'Begin')
        $reader = New-Object System.IO.StreamReader($fs)
        $text   = $reader.ReadToEnd()
        $reader.Close(); $fs.Close()
        return @($text -split "`n" | Where-Object { $_ -match 'ERROR|FATAL|CRITICAL' -and $_.Trim() })
    } catch { return @() }
}

# Query Loki for error lines from a specific job since a given time
function Invoke-LokiQuery {
    param(
        [string]$Job,
        [datetime]$Since,
        [string]$Filter    = 'ERROR|FATAL|CRITICAL',
        [string]$LokiUrl   = 'http://127.0.0.1:3100',
        [int]$TimeoutSec   = 5
    )
    try {
        $startNs = [string]([long]([DateTimeOffset]::new($Since.ToUniversalTime(), [TimeSpan]::Zero).ToUnixTimeMilliseconds()) * 1000000)
        $endNs   = [string]([long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) * 1000000)
        $q       = '{job="' + $Job + '"} |~ "' + $Filter + '"'
        $resp    = Invoke-RestMethod "$LokiUrl/loki/api/v1/query_range" `
                       -Body @{ query = $q; start = $startNs; end = $endNs; limit = 100 } `
                       -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
        return @($resp.data.result | ForEach-Object { $_.values } | ForEach-Object { $_[1] })
    } catch { return @() }
}

# Push test results to Loki as structured log lines (one stream per result)
function Push-TestResultsToLoki {
    param(
        [object[]]$Results,
        [string]$LokiUrl = 'http://127.0.0.1:3100',
        [int]$TimeoutSec = 8
    )
    if (-not $Results -or $Results.Count -eq 0) { return }
    try {
        $nowNs   = [string]([long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) * 1000000)
        $streams = @($Results | ForEach-Object {
            # Structured logfmt line so Grafana's | logfmt parser extracts
            # status/service/layer/test/message as fields (not just labels).
            $escMsg = (($_.message) -replace '[\r\n]+', ' ') -replace '([\\"])', '\$1'
            $msg  = "status=$($_.status) service=$($_.service) layer=$($_.layer) test=$($_.test) duration_ms=$($_.duration_ms)"
            $msg += ' message="' + $escMsg + '"'
            @{
                stream = @{ job = 'test-suite'; service = $_.service; layer = "$($_.layer)"; test = $_.test; status = $_.status }
                values = @(,@($nowNs, $msg))
            }
        })
        $body = @{ streams = $streams } | ConvertTo-Json -Depth 8 -Compress
        Invoke-RestMethod "$LokiUrl/loki/api/v1/push" -Method Post -Body $body `
            -ContentType 'application/json' -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop | Out-Null
    } catch {}
}

# Write test_results.json to the dashboard directory
function Export-TestResults {
    param(
        [object[]]$Results,
        [string]$OutputPath,
        [datetime]$StartTime
    )
    $pass = @($Results | Where-Object { $_.status -eq 'PASS' }).Count
    $fail = @($Results | Where-Object { $_.status -eq 'FAIL' }).Count
    $warn = @($Results | Where-Object { $_.status -eq 'WARN' }).Count
    $skip = @($Results | Where-Object { $_.status -eq 'SKIP' }).Count
    $out  = [ordered]@{
        timestamp        = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
        suite_duration_s = [int]((Get-Date) - $StartTime).TotalSeconds
        results          = $Results
        summary          = [ordered]@{ pass = $pass; fail = $fail; warn = $warn; skip = $skip; total = $Results.Count }
    }
    $dir = Split-Path $OutputPath -Parent
    if (-not (Test-Path $dir)) { New-Item $dir -ItemType Directory -Force | Out-Null }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($OutputPath, ($out | ConvertTo-Json -Depth 8), $utf8)
}

# Print a formatted summary table to the console
function Write-TestSummary {
    param([object[]]$Results)
    $pass = @($Results | Where-Object { $_.status -eq 'PASS' }).Count
    $fail = @($Results | Where-Object { $_.status -eq 'FAIL' }).Count
    $warn = @($Results | Where-Object { $_.status -eq 'WARN' }).Count
    $skip = @($Results | Where-Object { $_.status -eq 'SKIP' }).Count

    Write-Host ''
    $Results | Sort-Object service, layer, test | ForEach-Object {
        $col  = switch ($_.status) { 'PASS' { 'Green' } 'FAIL' { 'Red' } 'WARN' { 'Yellow' } default { 'DarkGray' } }
        $line = '  [{0}] {1,-14} L{2} {3}' -f $_.status.PadRight(4), $_.service, $_.layer, $_.test
        if ($_.message) { $line += " -- $($_.message)" }
        Write-Host $line -ForegroundColor $col
    }
    Write-Host ''
    Write-Host "  PASS:$pass  FAIL:$fail  WARN:$warn  SKIP:$skip  TOTAL:$($Results.Count)" -ForegroundColor Cyan
    Write-Host ''
}

# Add log-validation results directly to $Script:Results (avoids empty-array null unrolling in PS5.1).
# Checks file log for new errors since $LogPosition; optionally cross-checks Loki (60 s tolerance).
function Get-LogValidationResult {
    param(
        [string]$Service,
        [int]$Layer,
        [string]$LogPath,
        [long]$LogPosition,
        [string]$LokiJob       = '',
        [datetime]$LayerStart  = [datetime]::MinValue,
        [bool]$LokiEnabled     = $false
    )
    $fileErrors = Get-NewLogErrors -LogPath $LogPath -Position $LogPosition

    if ($fileErrors.Count -gt 0) {
        $sample = ($fileErrors | Select-Object -First 2) -join ' | '
        $Script:Results.Add((New-TestResult $Service $Layer 'LogErrors' WARN "$($fileErrors.Count) error(s) in log: $sample"))
    }

    if ($LokiEnabled -and $LokiJob -and $LayerStart -ne [datetime]::MinValue -and $fileErrors.Count -gt 0) {
        $lokiErrors = Invoke-LokiQuery -Job $LokiJob -Since $LayerStart
        if ($lokiErrors.Count -eq 0) {
            $Script:Results.Add((New-TestResult $Service $Layer 'LogDelivery' WARN 'Errors in file log not yet seen in Loki (>60 s delivery gap possible)'))
        } else {
            $Script:Results.Add((New-TestResult $Service $Layer 'LogDelivery' PASS "Loki received $($lokiErrors.Count) error line(s)"))
        }
    }
}
