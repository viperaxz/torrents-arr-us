param(
    [string]$Vendor = "",    # optional filter: "nvidia" | "amd" | "intel"
    [switch]$Quiet           # suppress informational output; only emit the slug
)

# -- helpers ------------------------------------------------------------------

function Get-NvidiaFamily([string]$name) {
    switch -Regex ($name) {
        'RTX\s*50\d\d|GeForce\s*RTX\s*5\d\d\d' { return 'nvidia_blackwell' }
        'RTX\s*40\d\d|GeForce\s*RTX\s*4\d\d\d' { return 'nvidia_ada'       }
        'RTX\s*30\d\d|GeForce\s*RTX\s*3\d\d\d' { return 'nvidia_ampere'    }
        'RTX\s*20\d\d|GTX\s*16\d\d'               { return 'nvidia_turing'    }
        'GTX\s*10\d\d'                           { return 'nvidia_pascal'    }
        'GTX\s*9[0-9]\d|GTX\s*750'              { return 'nvidia_maxwell'   }
        default                                  { return 'nvidia_pascal'    }
    }
}

function Get-AmdFamily([string]$name) {
    # First match wins, so the specific RX model ranges come before the broad ones.
    switch -Regex ($name) {
        # RDNA 4 - RX 9000 series (Navi 4x)
        'RX\s*9\d\d\d'                          { return 'amd_rdna4' }
        # RDNA 3 / 3.5 - RX 7000 series (Navi 3x) and Radeon 700M/800M iGPUs (Phoenix/Strix)
        'RX\s*7\d\d\d|Radeon.*\b(7\d\dM|8\d\dM|80\d\dS)\b' { return 'amd_rdna3' }
        # RDNA 2 - RX 6000 series (Navi 2x) and Radeon 600M iGPUs (Rembrandt/Mendocino)
        'RX\s*6\d\d\d|Radeon.*\b6\d\dM\b'       { return 'amd_rdna2' }
        # RDNA 1 - RX 5300 and RX 5500-5700 (Navi 1x); must precede the RX 4xx/5xx GCN rule
        'RX\s*53\d\d|RX\s*5[5-9]\d\d'           { return 'amd_rdna1' }
        # GCN 4th gen (Polaris) - RX 400/500 series: H.264 encode only, no HEVC encode
        'RX\s*[45]\d\d'                         { return 'amd_gcn4'  }
        # Vega (GCN 5th gen / VCN 1.0) and Radeon VII - no AV1, kept on the conservative profile
        'Vega|Radeon\s*VII'                     { return 'amd_gcn4'  }
        # Unmatched AMD (generic "Radeon Graphics", pre-GCN, OEM renames): assume the oldest
        # supported generation. amd_rdna1 would promise HEVC encode the card may not have.
        default                                 { return 'amd_gcn4'  }
    }
}

function Get-IntelFamily([string]$name) {
    # First match wins. Newer/more specific families (Arc, Iris Xe = 11th gen, UHD 7xx =
    # 12th gen) are listed before the older ones; the legacy "Iris ... Graphics <number>"
    # rule is listed before the unnumbered Ice Lake "Iris Plus" rule so 8th/9th gen Iris
    # CPU parts still resolve to intel_uhd_8th. Intel inserts "(R)"/"(TM)" tokens and a
    # "Graphics" infix into adapter names, so the patterns tolerate both.
    switch -Regex ($name) {
        'Arc'                                   { return 'intel_arc'      }
        'Iris(\(R\)|\(TM\))?\s*Xe'              { return 'intel_uhd_11th' }
        'UHD\s*(Graphics\s*)?7[0-9]\d'          { return 'intel_uhd_12th' }
        'Iris.*Graphics\s*\d'                   { return 'intel_uhd_8th'  }
        'Iris.*Plus'                            { return 'intel_uhd_10th' }
        'UHD\s*(Graphics\s*)?6[2-9]\d'          { return 'intel_uhd_8th'  }
        'HD\s*[56]\d\d'                         { return 'intel_hd'       }
        default                                 { return 'intel_uhd_8th'  }
    }
}

# -- enumerate adapters -------------------------------------------------------

$adapters = Get-WmiObject Win32_VideoController -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notmatch 'Microsoft|Remote|Virtual|Hyper-V|Basic Display' }

if (-not $adapters) {
    if (-not $Quiet) { Write-Host "  [detect_gpu] No video controllers found. Falling back to CPU." -ForegroundColor Yellow }
    'cpu'
    return
}

# -- classify each adapter ----------------------------------------------------

$classified = foreach ($a in $adapters) {
    $vendorId = ''
    if ($a.PNPDeviceID -match 'VEN_10DE') { $vendorId = 'nvidia' }
    elseif ($a.PNPDeviceID -match 'VEN_1002') { $vendorId = 'amd'    }
    elseif ($a.PNPDeviceID -match 'VEN_8086') { $vendorId = 'intel'  }
    else { $vendorId = 'unknown' }

    $isDedicated = ($vendorId -in @('nvidia','amd')) -or
                   ($vendorId -eq 'intel' -and $a.Name -match 'Arc')

    $vram = [long]$a.AdapterRAM   # caps at 4 GB on older WMI; unreliable for >4 GB

    [PSCustomObject]@{
        Name        = $a.Name
        Vendor      = $vendorId
        IsDedicated = $isDedicated
        Vram        = $vram
        Adapter     = $a
    }
}

# -- filter by vendor hint if provided ----------------------------------------

if ($Vendor) {
    $filtered = $classified | Where-Object { $_.Vendor -eq $Vendor.ToLower() }
    if ($filtered) { $classified = $filtered }
}

# -- select the best GPU -------------------------------------------------------
# Priority: dedicated > integrated, then VRAM descending, then NVIDIA > AMD > Intel

$priority = @{ nvidia = 0; amd = 1; intel = 2; unknown = 3 }

$best = $classified |
    Sort-Object -Property @(
        @{ Expression = { if ($_.IsDedicated) { 0 } else { 1 } } },
        @{ Expression = { $_.Vram }; Descending = $true },
        @{ Expression = { $priority[$_.Vendor] } }
    ) |
    Select-Object -First 1

if (-not $best) {
    if (-not $Quiet) { Write-Host "  [detect_gpu] No suitable GPU found after filtering. Falling back to CPU." -ForegroundColor Yellow }
    'cpu'
    return
}

# -- identify family from model name ------------------------------------------

$family = switch ($best.Vendor) {
    'nvidia' { Get-NvidiaFamily $best.Name }
    'amd'    { Get-AmdFamily    $best.Name }
    'intel'  { Get-IntelFamily  $best.Name }
    default  { 'cpu' }
}

# -- display summary (human-readable) -----------------------------------------

if (-not $Quiet) {
    $vramMb = if ($best.Vram -gt 0) { " ($([math]::Round($best.Vram / 1MB)) MB VRAM)" } else { "" }
    $kind   = if ($best.IsDedicated) { "dedicated" } else { "integrated" }
    Write-Host "  [detect_gpu] Detected: $($best.Name)$vramMb ($kind)" -ForegroundColor Cyan
    Write-Host "  [detect_gpu] Family slug: $family" -ForegroundColor Cyan

    $profilePath = Join-Path $PSScriptRoot "..\profiles\gpu\$family.json"
    if (Test-Path $profilePath) {
        $p = Get-Content $profilePath -Raw | ConvertFrom-Json
        $av1enc = if ($p.AllowAv1Encoding)    { 'AV1 encode + decode' }
                  elseif ($p.HardwareDecodingCodecs -contains 'av1') { 'AV1 decode only' }
                  else { 'no AV1' }
        $hevc   = if ($p.AllowHevcEncoding)   { 'HEVC encode + decode' } else { 'HEVC decode only' }
        Write-Host "  [detect_gpu] Capabilities: H.264  $hevc  $av1enc" -ForegroundColor DarkCyan
    }
}

# -- emit the slug as pipeline output -----------------------------------------
$family
