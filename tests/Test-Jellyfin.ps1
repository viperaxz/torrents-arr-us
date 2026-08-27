# tests/Test-Jellyfin.ps1 -- Jellyfin media server test module

param([int]$LayerFilter = 0)

$svc  = 'Jellyfin'
$port = $Config.Ports.Jellyfin
$base = Get-AppUrlBase 'jellyfin' $Config.General.DomainMode
$log  = 'C:\ProgramData\Jellyfin\Server\logs\jellyfin.log'

# -- Layer 1: Health -----------------------------------------------------------
if ($LayerFilter -eq 0 -or $LayerFilter -eq 1) {
    $pos = Get-LogPosition $log
    $t0  = Get-Date

    $portOk = Test-TcpPort $port
    $Script:Results.Add((New-TestResult $svc 1 'PortOpen' $(if ($portOk) { 'PASS' } else { 'FAIL' }) "TCP :$port"))

    $info = Invoke-ApiCheck "http://127.0.0.1:$port/System/Info/Public" -TimeoutSec 8
    $Script:Results.Add((New-TestResult $svc 1 'InfoPublic' $(if ($info.ok) { 'PASS' } else { 'FAIL' }) $info.error $info.latency_ms))

    if ($info.ok) {
        $Script:Results.Add((New-TestResult $svc 1 'ServerName' 'PASS' "ProductName=$($info.data.ProductName) Version=$($info.data.Version)"))
    }

    $nssm = Get-Service 'JellyfinServer' -ErrorAction SilentlyContinue
    $Script:Results.Add((New-TestResult $svc 1 'ServiceRunning' $(if ($nssm -and $nssm.Status -eq 'Running') { 'PASS' } else { 'FAIL' }) 'NSSM service state'))

    Get-LogValidationResult $svc 1 $log $pos '' $t0 $Script:LokiEnabled
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
        $libs = Invoke-ApiCheck "http://127.0.0.1:$port${base}/Library/VirtualFolders" @{'X-Emby-Authorization'="MediaBrowser Token=`"$apiKey`""} -TimeoutSec 8
        if ($libs.ok -and $libs.data -is [array]) {
            $Script:Results.Add((New-TestResult $svc 2 'LibrariesPresent' $(if ($libs.data.Count -gt 0) { 'PASS' } else { 'WARN' }) "$($libs.data.Count) virtual folder(s) found"))
        } elseif ($libs.ok) {
            $Script:Results.Add((New-TestResult $svc 2 'LibrariesPresent' 'FAIL' 'API returned unexpected data (not a JSON array)'))
        } else {
            $Script:Results.Add((New-TestResult $svc 2 'LibrariesPresent' 'FAIL' $libs.error))
        }

        $users = Invoke-ApiCheck "http://127.0.0.1:$port${base}/Users" @{'X-Emby-Authorization'="MediaBrowser Token=`"$apiKey`""} -TimeoutSec 8
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
        $enc = Invoke-ApiCheck "http://127.0.0.1:$port${base}/System/Configuration/encoding" @{'X-Emby-Authorization'="MediaBrowser Token=`"$apiKey`""} -TimeoutSec 8
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
