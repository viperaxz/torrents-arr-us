<#
.SYNOPSIS
    Mirrors new Caddy access-log lines into a file CrowdSec reliably consumes.

.DESCRIPTION
    Caddy holds D:\MediaServer\logs\caddy-access.log open for writing, and CrowdSec's
    file acquisition on Windows does not notice bytes appended through that handle:
    measured repeatedly, `cscli metrics` stayed at "0 lines read" while the log grew
    with real requests, and only jumped to 8/8 parsed the moment a *different* process
    appended to the same file. A plain share-all no-op touch was not enough either --
    it takes actual bytes written by another handle.

    Rather than fight that, this task copies every complete line Caddy has written
    since the last run into caddy-access-relay.log. CrowdSec tails the relay file, and
    because the bytes are written by this process its tail wakes up every cycle.

    The offset is persisted so a run copies only what is new, and it resets when the
    source file shrinks (the installer and Caddy's own rolling both recreate it).

.EXAMPLE
    .\relay_caddy_log.ps1 -InstallDir D:\MediaServer
#>
param(
    [string]$InstallDir = "D:\MediaServer"
)

$ErrorActionPreference = "Stop"

$logDir    = Join-Path $InstallDir "logs"
$source    = Join-Path $logDir "caddy-access.log"
$relay     = Join-Path $logDir "caddy-access-relay.log"
$offsetFile = Join-Path $logDir ".caddy-relay-offset"

if (-not (Test-Path $source)) { exit 0 }

# Only complete lines: a partial trailing line is left for the next run so CrowdSec
# never receives half a JSON record.
$share = [System.IO.FileShare]::ReadWrite
$stream = $null
try {
    $stream = [System.IO.File]::Open($source, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
} catch {
    # Caddy can hold the file briefly during a roll; the next run picks it up.
    exit 0
}

try {
    $offset = 0
    if (Test-Path $offsetFile) {
        $raw = (Get-Content -LiteralPath $offsetFile -Raw -ErrorAction SilentlyContinue)
        if ($raw -match '^\d+$') { $offset = [int64]$raw }
    }

    $length = $stream.Length
    if ($length -lt $offset) { $offset = 0 }        # recreated or truncated
    if ($length -eq $offset) { exit 0 }

    $null = $stream.Seek($offset, [System.IO.SeekOrigin]::Begin)
    $buffer = New-Object byte[] ($length - $offset)
    $read = $stream.Read($buffer, 0, $buffer.Length)
    if ($read -le 0) { exit 0 }

    # Keep only up to the last newline; carry the remainder forward.
    $lastNewline = -1
    for ($i = $read - 1; $i -ge 0; $i--) {
        if ($buffer[$i] -eq 10) { $lastNewline = $i; break }
    }
    if ($lastNewline -lt 0) { exit 0 }

    $chunk = New-Object byte[] ($lastNewline + 1)
    [Array]::Copy($buffer, 0, $chunk, 0, $lastNewline + 1)

    $out = [System.IO.File]::Open($relay, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write,
        ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
    try {
        $out.Write($chunk, 0, $chunk.Length)
        $out.Flush()
    } finally { $out.Dispose() }

    Set-Content -LiteralPath $offsetFile -Value ([string]($offset + $lastNewline + 1)) -Encoding ASCII -NoNewline
} catch {
    exit 0
} finally {
    if ($stream) { $stream.Dispose() }
}
