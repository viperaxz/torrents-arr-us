# test_llm_block.ps1 — renders the LLM Caddy block from 01_webserver.ps1 under
# several config scenarios and (when caddy.exe is available) validates the output.
# Read-only: touches no services, no config files, no install state.
param(
    [switch]$SkipCaddyValidate
)

$ErrorActionPreference = 'Stop'
$WebServer = Join-Path $PSScriptRoot '..\scripts\01_webserver.ps1'
if (-not (Test-Path $WebServer)) { throw "01_webserver.ps1 not found at $WebServer" }

$src = Get-Content $WebServer -Raw
$start = $src.IndexOf('# -- LLM reverse proxy block (rendered only when LLM.Enabled)')
$end   = $src.IndexOf('$Content = Get-Content -Raw -Path $TemplatePath -Encoding UTF8')
if ($start -lt 0 -or $end -lt 0 -or $end -le $start) { throw 'LLM block markers not found in 01_webserver.ps1' }
$snippet = $src.Substring($start, $end - $start)

function Write-DebugLog { param([string]$a, [string]$b) }   # stub used by the snippet

function Get-LlmBlock {
    param($Mode, $Enabled, $ApiKey, $ExposeUi, $Port = 8081)
    $script:DomainMode = $Mode
    $script:LlmEnabled = $Enabled
    $script:LlmApiKey = $ApiKey
    $script:LlmExposeUi = $ExposeUi
    $script:LlmSubdomain = 'llm'
    $script:LlmHost = '127.0.0.1'
    $script:LlmPort = $Port
    $script:SafeInstallDir = 'E:/MediaServer'
    $script:AdminUsername = 'admin'
    $script:AdminBcryptHash = '$2a$14$hashtest'
    $script:TlsBlock = 'tls test@example.com'
    $script:Config = [pscustomobject]@{ General = [pscustomobject]@{ Domain = 'example.com' } }
    $script:LlmBlock = $null
    Invoke-Expression $snippet
    return $LlmBlock
}

$scenarios = @(
    @{ Name = 'cloudflare-key-ui';    Mode = 'cloudflare'; Key = 'secret123'; Ui = $true  },
    @{ Name = 'cloudflare-nokey-noui'; Mode = 'cloudflare'; Key = '';          Ui = $false },
    @{ Name = 'cloudflare-nokey-ui';  Mode = 'cloudflare'; Key = '';          Ui = $true  },
    @{ Name = 'duckdns-key';          Mode = 'duckdns';    Key = 'secret123'; Ui = $true  },
    @{ Name = 'duckdns-nokey';        Mode = 'duckdns';    Key = '';          Ui = $true  }
)

$failures = 0
foreach ($s in $scenarios) {
    $block = Get-LlmBlock -Mode $s.Mode -Enabled $true -ApiKey $s.Key -ExposeUi $s.Ui
    Write-Host ""
    Write-Host "===== SCENARIO: $($s.Name) ====="
    Write-Host $block
    if ([string]::IsNullOrWhiteSpace($block)) { Write-Host "RESULT: FAIL (empty block)"; $failures++; continue }

    # build a validate-able Caddyfile around the block
    $tmp = Join-Path $env:TEMP "strata_llm_$($s.Name).Caddyfile"
    if ($s.Mode -eq 'cloudflare') {
        $full = $block
    } else {
        $full = "example.duckdns.org {`n    tls test@example.com`n$block    handle {`n        respond 200`n    }`n}`n"
    }
    [System.IO.File]::WriteAllText($tmp, $full, (New-Object System.Text.UTF8Encoding($false)))

    if ($SkipCaddyValidate) {
        Write-Host "RESULT: rendered only (validation skipped)"
        continue
    }
    $caddy = (Get-Command caddy.exe -ErrorAction SilentlyContinue).Source
    if (-not $caddy) { Write-Host "RESULT: SKIP (caddy.exe not found)"; continue }
    $savedEAP = $ErrorActionPreference
    $out = $null
    try {
        $ErrorActionPreference = 'Continue'
        $out = & $caddy validate --adapter caddyfile --config $tmp 2>&1 | Out-String
    } finally {
        $ErrorActionPreference = $savedEAP
    }
    if ($LASTEXITCODE -eq 0) { Write-Host "RESULT: PASS (caddy validate OK)" }
    else { Write-Host "RESULT: FAIL`n$out"; $failures++ }
}

# disabled case must render an empty block
$empty = Get-LlmBlock -Mode 'cloudflare' -Enabled $false -ApiKey '' -ExposeUi $true
Write-Host ""
if ([string]::IsNullOrWhiteSpace($empty)) { Write-Host "DISABLED: PASS (empty block)" }
else { Write-Host "DISABLED: FAIL (non-empty block)`n$empty"; $failures++ }

# port-conflict default sanity
if ($failures -eq 0) { Write-Host "`nALL SCENARIOS PASSED"; exit 0 }
Write-Host "`n$failures FAILURE(S)"; exit 1
