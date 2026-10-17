# tests/Test-Jellyfin.ps1 -- Jellyfin media server test module

param([int]$LayerFilter = 0)

$svc  = 'Jellyfin'
$port = $Config.Ports.Jellyfin
$base = Get-AppUrlBase 'jellyfin' $Config.General.DomainMode
# Jellyfin's log directory is <Server>\log (singular). Its default Serilog file sink is
# date-rolled (log_YYYYMMDD.log); the Alloy/Grafana override switches it to a fixed
# jellyfin.log. Resolve whichever exists, newest first.
$logDir = 'C:\ProgramData\Jellyfin\Server\log'
$log    = $null
foreach ($logPattern in @('jellyfin.log', 'log_*.log')) {
    $candidate = Get-ChildItem -Path $logDir -Filter $logPattern -File -ErrorAction SilentlyContinue |
                 Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($candidate) { $log = $candidate.FullName; break }
}
if (-not $log) { $log = Join-Path $logDir 'jellyfin.log' }

# -- Layer 1: Health -----------------------------------------------------------
if ($LayerFilter -eq 0 -or $LayerFilter -eq 1) {
    $pos = Get-LogPosition $log
    $t0  = Get-Date

    $portOk = Test-TcpPort $port
    $Script:Results.Add((New-TestResult $svc 1 'PortOpen' $(if ($portOk) { 'PASS' } else { 'FAIL' }) "TCP :$port"))

    $info = Invoke-ApiCheck "http://127.0.0.1:$port${base}/System/Info/Public" -TimeoutSec 8
    $Script:Results.Add((New-TestResult $svc 1 'InfoPublic' $(if ($info.ok) { 'PASS' } else { 'FAIL' }) $info.error $info.latency_ms))

    if ($info.ok) {
        $Script:Results.Add((New-TestResult $svc 1 'ServerName' 'PASS' "ProductName=$($info.data.ProductName) Version=$($info.data.Version)"))
    }

    # Chocolatey may register the service as JellyfinServer, jellyfin or Jellyfin
    $nssm = $null
    foreach ($candidate in @('JellyfinServer', 'jellyfin', 'Jellyfin')) {
        $nssm = Get-Service $candidate -ErrorAction SilentlyContinue
        if ($nssm) { break }
    }
    $Script:Results.Add((New-TestResult $svc 1 'ServiceRunning' $(if ($nssm -and $nssm.Status -eq 'Running') { 'PASS' } else { 'FAIL' }) 'Service state'))

    Get-LogValidationResult $svc 1 $log $pos 'jellyfin' $t0 $Script:LokiEnabled
}

# -- Layer 2: Libraries and users match config ----------------------------------
if ($LayerFilter -eq 0 -or $LayerFilter -eq 2) {
    $apiKey = $null
    try {
        $tokenPath = Join-Path $InstallDir 'secrets\jellyfin_api_key.txt'
        if (Test-Path $tokenPath) {
            $apiKey = ([System.IO.File]::ReadAllText($tokenPath, [System.Text.Encoding]::UTF8)).TrimStart([char]0xFEFF).Trim()
        }
    } catch {}

    if ($apiKey) {
        # Jellyfin 12.x answers 401 for X-Emby-Authorization / X-Emby-Token, with an
        # API key just as with a user token; only the Authorization header carrying
        # the MediaBrowser client string plus Token= is accepted. Same format as
        # collect_status.ps1 and configure_layer2_jellyfin_libraries.ps1.
        $jfClient = 'MediaBrowser Client="seedbox-tests", Device="test-suite", DeviceId="seedbox-tests", Version="1.0.0"'
        $jfAuth   = @{ 'Authorization' = ($jfClient + ', Token="' + $apiKey + '"') }
        $libs = Invoke-ApiCheck "http://127.0.0.1:$port${base}/Library/VirtualFolders" $jfAuth -TimeoutSec 8
        if ($libs.ok) {
            # @() matters: a single virtual folder deserialises to one object, not an array,
            # and the old "-is [array]" test reported a healthy single-library box as
            # "unexpected data (not a JSON array)".
            $libCount = @($libs.data).Count
            $Script:Results.Add((New-TestResult $svc 2 'LibrariesPresent' $(if ($libCount -gt 0) { 'PASS' } else { 'WARN' }) "$libCount virtual folder(s) found"))
        } else {
            $Script:Results.Add((New-TestResult $svc 2 'LibrariesPresent' 'FAIL' $libs.error))
        }

        $users = Invoke-ApiCheck "http://127.0.0.1:$port${base}/Users" $jfAuth -TimeoutSec 8
        if ($users.ok) {
            $cfgUsers = @($Config.Users | Where-Object { $_.Username } | ForEach-Object { $_.Username.ToLower() })
            $jfUsers  = @($users.data   | Where-Object { $_.Name }     | ForEach-Object { $_.Name.ToLower() })
            $missing  = $cfgUsers | Where-Object { $_ -notin $jfUsers }
            if ($missing) {
                $Script:Results.Add((New-TestResult $svc 2 'UsersProvisioned' 'FAIL' "Missing in Jellyfin: $($missing -join ', ')"))
            } else {
                $Script:Results.Add((New-TestResult $svc 2 'UsersProvisioned' 'PASS' "$($cfgUsers.Count) config user(s) found in Jellyfin"))
            }
        } else {
            $Script:Results.Add((New-TestResult $svc 2 'UsersProvisioned' 'FAIL' $users.error))
        }
    } else {
        $Script:Results.Add((New-TestResult $svc 2 'LibrariesPresent' 'SKIP' 'No API key found at secrets\jellyfin_api_key.txt'))
        $Script:Results.Add((New-TestResult $svc 2 'UsersProvisioned'  'SKIP' 'No API key found'))
    }
}

# -- Layer 3: GPU transcoding profile applied ----------------------------------
if ($LayerFilter -eq 0 -or $LayerFilter -eq 3) {
    $apiKey = $null
    try {
        $tokenPath = Join-Path $InstallDir 'secrets\jellyfin_api_key.txt'
        if (Test-Path $tokenPath) { $apiKey = ([System.IO.File]::ReadAllText($tokenPath, [System.Text.Encoding]::UTF8)).TrimStart([char]0xFEFF).Trim() }
    } catch {}

    $cfgGpu = $Config.Layer2.Jellyfin.GPU
    if (-not $cfgGpu) {
        $Script:Results.Add((New-TestResult $svc 3 'GpuProfile' 'SKIP' 'GPU profile not configured (CPU fallback)'))
    } elseif ($apiKey) {
        # Rebuilt here as well: a -Layer 3-only run never executes the Layer 2 block
        # above, so $jfAuth would be $null and every admin request would 401.
        $jfClient = 'MediaBrowser Client="seedbox-tests", Device="test-suite", DeviceId="seedbox-tests", Version="1.0.0"'
        $jfAuth   = @{ 'Authorization' = ($jfClient + ', Token="' + $apiKey + '"') }
        $enc = Invoke-ApiCheck "http://127.0.0.1:$port${base}/System/Configuration/encoding" $jfAuth -TimeoutSec 8
        if ($enc.ok) {
            $hwAccel = $enc.data.HardwareAccelerationType
            if ($hwAccel -and $hwAccel -ne 'none') {
                $Script:Results.Add((New-TestResult $svc 3 'GpuProfile' 'PASS' "HardwareAccelerationType=$hwAccel"))
            } else {
                $Script:Results.Add((New-TestResult $svc 3 'GpuProfile' 'WARN' "HardwareAccelerationType=$hwAccel but config GPU=$cfgGpu"))
            }
        } else {
            $Script:Results.Add((New-TestResult $svc 3 'GpuProfile' 'FAIL' $enc.error))
        }
    } else {
        $Script:Results.Add((New-TestResult $svc 3 'GpuProfile' 'SKIP' 'No API key found'))
    }
}
