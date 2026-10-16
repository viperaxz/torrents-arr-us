# Background daily update checker  --  runs as a scheduled task under the interactive user.
# Shows a Windows toast notification when app or project updates are available.
# Does NOT apply any updates automatically.

$ErrorActionPreference = "SilentlyContinue"

# -- Locate project root and config --------------------------------------------
# Walk up from the script's own directory until we find config.json and
# master_install.ps1 (both must exist at the project root).
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = $ScriptRoot
while ($ProjectRoot -and -not (
    (Test-Path (Join-Path $ProjectRoot "config.json")) -and
    (Test-Path (Join-Path $ProjectRoot "master_install.ps1"))
)) {
    $parent = Split-Path $ProjectRoot -Parent
    if ($parent -eq $ProjectRoot) { $ProjectRoot = $null; break }
    $ProjectRoot = $parent
}
if (-not $ProjectRoot) {
    # Fall back to the original assumption: script is at <root>/scripts/
    $ProjectRoot = Split-Path -Parent $ScriptRoot
}
$ConfigPath  = Join-Path $ProjectRoot "config.json"

if (-not (Test-Path $ConfigPath)) { exit 0 }
$Config      = Get-Content -Raw $ConfigPath | ConvertFrom-Json
$InstallDir  = $Config.General.InstallDir

# -- Load local versions.json --------------------------------------------------
$LocalVersionsPath = Join-Path $ProjectRoot "versions.json"
if (-not (Test-Path $LocalVersionsPath)) { exit 0 }
$LocalVersions = Get-Content -Raw $LocalVersionsPath | ConvertFrom-Json

. (Join-Path $ProjectRoot "scripts\update_common.ps1")

# -- Fetch remote versions.json (helper parses text/plain JSON) ----------------
$RemoteVersions = Get-RemoteManifest -LocalManifest $LocalVersions
if ([object]::ReferenceEquals($RemoteVersions, $LocalVersions)) { exit 0 }

# -- Check for project script updates (git) ------------------------------------
$projectUpdateAvailable = $false
$isGitRepo = Test-Path (Join-Path $ProjectRoot ".git")
if ($isGitRepo) {
    try {
        & git -C $ProjectRoot fetch origin main --quiet 2>&1 | Out-Null
        $localSha  = (& git -C $ProjectRoot rev-parse HEAD 2>&1).Trim()
        $remoteSha = (& git -C $ProjectRoot rev-parse origin/main 2>&1).Trim()
        $projectUpdateAvailable = ($localSha -ne $remoteSha -and $remoteSha -ne "")
    } catch { }
}

# -- Compare app versions vs manifest (shared, data-driven plan) ----------------
$pendingApps     = [System.Collections.Generic.List[string]]::new()
$manualApps      = [System.Collections.Generic.List[string]]::new()
$securityPending = $false
$securityNote    = ""

$ScriptsDir = Join-Path $ProjectRoot "scripts"
$plan = @(Get-UpdatePlan -Manifest $RemoteVersions -InstallDir $InstallDir -ScriptsDir $ScriptsDir)

foreach ($item in $plan) {
    if ($item.State -eq "unknown" -or $item.State -eq "notinstalled") {
        # Self-heal: try to detect the real installed version and record it
        # (covers legacy lock values and apps without any lock file).
        $detected = Detect-InstalledVersion -AppName $item.App -Entry $item.Entry -InstallDir $InstallDir
        if ($detected) {
            Set-InstalledVersion -InstallDir $InstallDir -AppName $item.App -Version $detected
        }
    } elseif ($item.State -eq "update") {
        $pendingApps.Add($item.App)
        if ($item.Security) {
            $securityPending = $true
            if ($item.SecurityNote) { $securityNote = "$($item.App) - $($item.SecurityNote)" }
        }
    } elseif ($item.State -eq "manual") {
        $manualApps.Add($item.App)
    }
}

# -- Nothing to report  --  exit silently ----------------------------------------
if ($pendingApps.Count -eq 0 -and $manualApps.Count -eq 0 -and -not $projectUpdateAvailable) { exit 0 }

# -- Build toast notification --------------------------------------------------
function Show-ToastNotification {
    param([string]$Title, [string]$Body)

    # Method 1: WinRT toast API (best UX, requires registered AUMID).
    # A plain .ps1 script has no AUMID and this will throw. We try anyway
    # because a future box.cmd launcher may register one.
    $toastOk = $false
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]           | Out-Null

        $template = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent(
            [Windows.UI.Notifications.ToastTemplateType]::ToastText02
        )
        $template.SelectSingleNode("//text[@id='1']").AppendChild(
            $template.CreateTextNode($Title)
        ) | Out-Null
        $template.SelectSingleNode("//text[@id='2']").AppendChild(
            $template.CreateTextNode($Body)
        ) | Out-Null

        $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("win-seedbox")
        $notifier.Show([Windows.UI.Notifications.ToastNotification]::new($template))
        $toastOk = $true
    } catch {
        # Toast API not available -- expected when no AUMID is registered.
    }

    # Method 2: msg.exe pop-up (works in interactive sessions, no AUMID needed).
    if (-not $toastOk) {
        try {
            $msgBody = "$Title`n`n$Body"
            & msg.exe * $msgBody 2>$null | Out-Null
        } catch { }
    }

    # Method 3: Always write a notification file so the dashboard UI and
    # 'box check' can surface pending updates even when the user is logged out.
    try {
        $notifDir  = Join-Path $InstallDir "dashboard"
        $notifFile = Join-Path $notifDir "update_notification.json"
        if (-not (Test-Path $notifDir)) { New-Item -Path $notifDir -ItemType Directory -Force | Out-Null }
        $notifData = @{
            title      = $Title
            body       = $Body
            detectedAt = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
        } | ConvertTo-Json -Compress
        [System.IO.File]::WriteAllText($notifFile, $notifData, (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

if ($securityPending) {
    $title = "win-seedbox - SECURITY UPDATE"
    $body  = $securityNote
    if (-not $body) { $body = ($pendingApps -join ", ") + " - security fix available." }
    $body += " Run 'box update' immediately."
    Show-ToastNotification -Title $title -Body $body
} else {
    $parts = @()
    if ($pendingApps.Count -gt 0) { $parts += ($pendingApps -join ", ") }
    if ($manualApps.Count -gt 0)  { $parts += "manual: " + ($manualApps -join ", ") }
    $extra = if ($projectUpdateAvailable) { " + project scripts" } else { "" }
    $title = "win-seedbox - Updates available"
    $body  = "$($parts -join ' | ')$extra. Run 'box update' to apply."
    Show-ToastNotification -Title $title -Body $body
}

exit 0
