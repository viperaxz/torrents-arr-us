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

    # Regression guards for two Caddy semantics bugs found in live testing:
    #  1. site-level trailing directives (basic_auth/respond 404) wrap the handle
    #     routes, so the bearer-gated /v1 API would get a Basic challenge.
    #  2. the UI reverse_proxy must override Host to the backend (Strata rejects
    #     foreign Host headers with 403).
    if ($s.Mode -eq 'cloudflare') {
        $trailing = [regex]::Matches($block, '(?m)^    (basic_auth \{|respond 404)\s*$')
        if ($trailing.Count -gt 0) {
            Write-Host "RESULT: FAIL (site-level trailing directive: $($trailing[0].Value.Trim()))"
            $failures++; continue
        }
        $hostOverrides = ([regex]::Matches($block, 'header_up Host')).Count
        $expectedHost  = if ($s.Ui) { if ($s.Key) { 4 } else { 2 } } else { 1 }
        if ($hostOverrides -ne $expectedHost) {
            Write-Host "RESULT: FAIL (header_up Host count $hostOverrides, want $expectedHost)"
            $failures++; continue
        }
        if ($s.Ui) {
            if ($block -notmatch '(?m)^        basic_auth \{') { Write-Host 'RESULT: FAIL (basicauth not inside a handle block)'; $failures++; continue }
            if ($s.Key) {
                # the UI's own monitor calls (/metrics, /mcp) carry the Bearer key and must
                # bypass basicauth via a SIBLING handle (basic_auth runs before nested handles).
                if ($block -notmatch '(?m)^    @llmui header Authorization "Bearer secret123"') { Write-Host 'RESULT: FAIL (no site-level @llmui matcher for the UI)'; $failures++; continue }
                if ($block -notmatch '(?m)^    handle @llmui \{') { Write-Host 'RESULT: FAIL (no sibling handle for the UI bearer key)'; $failures++; continue }
            }
        } else {
            if ($block -notmatch '(?m)^        respond 404') { Write-Host 'RESULT: FAIL (404 not inside a handle block)'; $failures++; continue }
        }
    }

    # 3. CORS preflights (OPTIONS) never carry credentials, so a bearer-gated API
    #    must pass them through (Chatbox and other webview clients preflight).
    if ($s.Key) {
        if ($block -notmatch '@preflight method OPTIONS') { Write-Host 'RESULT: FAIL (no OPTIONS preflight passthrough on keyed API)'; $failures++; continue }
    }

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
