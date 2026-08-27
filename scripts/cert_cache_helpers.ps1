# cert_cache_helpers.ps1
# AES-256-CBC encrypt/decrypt of a directory tree for cert caching.
# File format: [16 bytes random PBKDF2-SHA256 salt][AES-256-CBC encrypted zip]
# Key = PBKDF2(password, salt, 100000, SHA256)[0:32]
# IV  = PBKDF2(password, salt, 100000, SHA256)[32:48]
#
# Dot-source this file; then call Protect-CaddyData or Restore-CaddyData.

function Protect-CaddyData {
    param(
        [string]$SourceDir,
        [string]$DestFile,
        [string]$Password
    )
    Write-DebugLog "INFO" "Protect-CaddyData: sourceDir=$SourceDir destFile=$DestFile"
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $tmpZip = [System.IO.Path]::Combine(
        [System.IO.Path]::GetTempPath(),
        [System.Guid]::NewGuid().ToString("N") + ".zip"
    )
    Write-DebugLog "VAR tmpZip=$tmpZip"
    try {
        Write-DebugLog "INFO" "Zipping $SourceDir -> $tmpZip"
        [System.IO.Compression.ZipFile]::CreateFromDirectory($SourceDir, $tmpZip)
        $zipBytes = [System.IO.File]::ReadAllBytes($tmpZip)
        Write-DebugLog "VAR zip size=$($zipBytes.Length) bytes"
    } finally {
        Remove-Item $tmpZip -Force -ErrorAction SilentlyContinue
    }

    Write-DebugLog "INFO" "Generating random 16-byte PBKDF2 salt..."
    $salt = New-Object byte[] 16
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($salt)
    $kdf     = New-Object System.Security.Cryptography.Rfc2898DeriveBytes(
                   $Password, $salt, 100000,
                   [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    $aes     = [System.Security.Cryptography.Aes]::Create()
    $aes.Key = $kdf.GetBytes(32)
    $aes.IV  = $kdf.GetBytes(16)
    Write-DebugLog "VAR AES-256-CBC key and IV derived from PBKDF2 (password=[REDACTED] iterations=100000)"

    $ms = New-Object System.IO.MemoryStream
    $cs = New-Object System.Security.Cryptography.CryptoStream(
              $ms, $aes.CreateEncryptor(),
              [System.Security.Cryptography.CryptoStreamMode]::Write)
    try {
        $cs.Write($zipBytes, 0, $zipBytes.Length)
        $cs.FlushFinalBlock()
    } finally {
        $cs.Dispose()
    }
    # NOTE: $ms (MemoryStream) and $aes must NOT be disposed until after
    # ToArray() is called. Disposing the CryptoStream is safe -- it only
    # finalises the transform; the underlying MemoryStream buffer survives.
    $encBytes = $ms.ToArray()
    $ms.Dispose()
    $aes.Dispose()
    $kdf.Dispose()
    Write-DebugLog "VAR encrypted output size=$($encBytes.Length) bytes"

    $out = New-Object byte[] (16 + $encBytes.Length)
    [System.Buffer]::BlockCopy($salt,     0, $out, 0,  16)
    [System.Buffer]::BlockCopy($encBytes, 0, $out, 16, $encBytes.Length)

    $cacheDir = Split-Path $DestFile
    if (-not (Test-Path $cacheDir)) {
        New-Item -Path $cacheDir -ItemType Directory -Force | Out-Null
        Write-DebugLog "INFO" "Created cache directory: $cacheDir"
    }
    [System.IO.File]::WriteAllBytes($DestFile, $out)
    Write-DebugLog "INFO" "Protect-CaddyData complete. Output file=$DestFile size=$($out.Length) bytes (16-byte salt + ciphertext)"
}

function Restore-CaddyData {
    param(
        [string]$SourceFile,
        [string]$DestDir,
        [string]$Password
    )
    Write-DebugLog "INFO" "Restore-CaddyData: sourceFile=$SourceFile destDir=$DestDir"
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $in = [System.IO.File]::ReadAllBytes($SourceFile)
    Write-DebugLog "VAR input file size=$($in.Length) bytes"
    if ($in.Length -lt 48) {
        Write-DebugLog "ERROR" "Cache file is too small to be valid (size=$($in.Length))"
        throw "Cache file is too small to be valid."
    }

    $salt = New-Object byte[] 16
    [System.Buffer]::BlockCopy($in, 0, $salt, 0, 16)
    $enc = New-Object byte[] ($in.Length - 16)
    [System.Buffer]::BlockCopy($in, 16, $enc, 0, $enc.Length)
    Write-DebugLog "VAR salt extracted (16 bytes), ciphertext size=$($enc.Length) bytes"

    Write-DebugLog "INFO" "Deriving AES key from PBKDF2 (password=[REDACTED] iterations=100000)..."
    $kdf     = New-Object System.Security.Cryptography.Rfc2898DeriveBytes(
                   $Password, $salt, 100000,
                   [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    $aes     = [System.Security.Cryptography.Aes]::Create()
    $aes.Key = $kdf.GetBytes(32)
    $aes.IV  = $kdf.GetBytes(16)

    $ms  = [System.IO.MemoryStream]::new($enc)
    $cs  = New-Object System.Security.Cryptography.CryptoStream(
               $ms, $aes.CreateDecryptor(),
               [System.Security.Cryptography.CryptoStreamMode]::Read)
    $out = New-Object System.IO.MemoryStream
    try {
        $cs.CopyTo($out)
    } finally {
        $cs.Dispose()
        $ms.Dispose()
        $aes.Dispose()
        $kdf.Dispose()
    }
    $zipBytes = $out.ToArray()
    $out.Dispose()
    Write-DebugLog "VAR decrypted zip size=$($zipBytes.Length) bytes"

    $tmpZip = [System.IO.Path]::Combine(
        [System.IO.Path]::GetTempPath(),
        [System.Guid]::NewGuid().ToString("N") + ".zip"
    )
    Write-DebugLog "VAR tmpZip=$tmpZip"
    try {
        [System.IO.File]::WriteAllBytes($tmpZip, $zipBytes)
        $destExists = Test-Path $DestDir
        Write-DebugLog "VAR DestDir=$DestDir exists=$destExists  --  will be removed before extraction"
        if ($destExists) { Remove-Item -Path $DestDir -Recurse -Force }
        New-Item -Path $DestDir -ItemType Directory -Force | Out-Null
        Write-DebugLog "INFO" "Extracting decrypted zip to $DestDir..."
        [System.IO.Compression.ZipFile]::ExtractToDirectory($tmpZip, $DestDir)
        $restoredFiles = (Get-ChildItem $DestDir -Recurse -ErrorAction SilentlyContinue).Count
        Write-DebugLog "INFO" "Restore-CaddyData complete. Files restored to $DestDir count=$restoredFiles"
    } finally {
        Remove-Item $tmpZip -Force -ErrorAction SilentlyContinue
        Write-DebugLog "VAR tmpZip removed"
    }
}
