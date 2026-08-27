# Claude Code — Project Instructions

## CRITICAL: No non-ASCII characters in PowerShell string literals

PowerShell 5.1 (Windows) reads `.ps1` files **without a UTF-8 BOM** as Windows-1252 (CP1252).
Any multi-byte UTF-8 character in a **string literal** will be **mis-decoded**, silently
corrupting the script or causing a parse error at runtime.

**The codebase is now 100% ASCII — every character in every .ps1 file is in the 0x00–0x7F range. This must never regress.**

### PRIMARY RULE: never use non-ASCII anywhere in a .ps1 file

Use ASCII equivalents for ALL decorative characters:

| Banned | Use instead |
|---|---|
| `—` (em-dash, U+2014) | ` -- ` (space, two hyphens, space) |
| `─` (box-draw light, U+2500) | `-` (ASCII hyphen) |
| `═` (box-draw double, U+2550) | `=` (ASCII equals) |
| `✓` (check mark, U+2713) | `[OK]` |
| `⚠` (warning, U+26A0) | `[WARN]` |
| `╔╗║╚╝` (box-drawing) | `+`, `|`, `=` for ASCII box art |

The most common failure mode (when this rule is violated):
- Em-dash `—` (U+2014) is encoded in UTF-8 as bytes `E2 80 94`
- CP1252 decodes those three bytes as `a` + `EUR` + `"` (RIGHT DOUBLE QUOTATION MARK, U+201D)
- PowerShell treats U+201D as a string terminator -> the string closes early -> parse error

### Verify: no non-ASCII anywhere across the entire project

```powershell
# Must return zero matches:
Get-ChildItem -Recurse -Filter *.ps1 | ForEach-Object {
    $txt = [System.IO.File]::ReadAllText($_.FullName, [System.Text.Encoding]::UTF8)
    if ($txt -match '[^\x00-\x7F]') {
        Write-Host "FAIL: $($_.Name) contains non-ASCII" -ForegroundColor Red
    }
}
```

### SECONDARY RULE: after every Write to a `.ps1` file, add the BOM

Even though we avoid non-ASCII in strings, always add the BOM as a defense-in-depth measure
(in case a non-ASCII character slips through, or for future PowerShell Core compatibility).

```powershell
$path = 'scripts\my_script.ps1'
$utf8bom = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText(
    $path,
    [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8),
    $utf8bom
)
```

Run this right after the Write call — never skip it.

To verify the BOM was applied (first 3 bytes must be `EF BB BF`):

```powershell
$b = [System.IO.File]::ReadAllBytes($path) | Select-Object -First 3
($b | ForEach-Object { '{0:X2}' -f $_ }) -join ' '   # expect: EF BB BF
```

To verify no parse errors remain:

```powershell
$e = $null; $t = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$t, [ref]$e)
if ($e.Count) { "FAIL: $($e[0].Message) at L$($e[0].Extent.StartLineNumber)" } else { "OK" }
```

---
