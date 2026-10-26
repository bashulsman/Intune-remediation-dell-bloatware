<#
.SYNOPSIS
    Intune Remediation - removes Dell update tools / bloatware.

.DESCRIPTION
    Removes Dell tools that install drivers/BIOS on their own and trigger restarts.
    Order: SupportAssist -> Command | Update -> Optimizer -> Digital Delivery -> Core Services
    (Core Services last, because the other tools depend on it).

    The device is NOT restarted; any pending restart happens at the next Windows Update cycle
    or when the user restarts.

    Log: C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\Remediate-DellBloatware.log
    (included in "Collect diagnostics" in Intune).

    Intune does not show the remediation script's own output. A summary of this run (removed /
    failed) is therefore stored in HKLM:\SOFTWARE\Remediations\DellBloatware; the detection
    script adds it to its output, so it shows up in "Post-remediation detection output".

    Intune settings: Run as logged-on credentials = No, Run in 64-bit PowerShell = Yes.
#>

# Keep this list identical to the one in Detect-DellBloatware.ps1 (order = removal order)
$AppPatterns = @(
    'Dell SupportAssist*'
    'SupportAssist Recovery Assistant*'
    'Dell Command | Update*'
    'Dell Update*'
    'Dell Optimizer*'
    'Dell.Digital.Delivery*'
    'Dell Digital Delivery*'
    'Dell Core Services*'
)

$AppxPatterns = @(
    'DellInc.DellSupportAssistforPCs'
    'DellInc.DellCommandUpdate'
    'DellInc.DellOptimizer'
    'DellInc.DellDigitalDelivery'
    'DellInc.DellUpdate'
)

$UninstallKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

# 0 = OK, 1605 = not installed, 1614 = already uninstalled, 1641/3010 = restart required (we don't restart)
$OkExitCodes = 0, 1605, 1614, 1641, 3010

$LogFile = 'C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\Remediate-DellBloatware.log'

# Summary of the last run, read by Detect-DellBloatware.ps1 (keep identical in both scripts)
$SummaryKey = 'HKLM:\SOFTWARE\Remediations\DellBloatware'

function Write-Log {
    param([string]$Message)
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

function Get-DellApps {
    param([string]$Pattern)
    Get-ItemProperty -Path $UninstallKeys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and $_.DisplayName -like $Pattern }
}

# Splits an uninstall string into executable and arguments
function Split-CommandLine {
    param([string]$CommandLine)
    $CommandLine = $CommandLine.Trim()
    if ($CommandLine -match '^"([^"]+)"\s*(.*)$') {
        return $Matches[1], $Matches[2]
    }
    if ($CommandLine -match '^(\S+\.exe)\s*(.*)$') {
        return $Matches[1], $Matches[2]
    }
    return $CommandLine, ''
}

# Returns a result object: Name, Result (OK / ERROR / SKIPPED), ExitCode
function Invoke-Uninstall {
    param($App)

    $name = $App.DisplayName
    $key  = $App.PSChildName
    $result = [pscustomobject]@{ Name = $name; Result = 'SKIPPED'; ExitCode = $null }

    if ($App.QuietUninstallString) {
        # Bundle installers (e.g. SupportAssist Remediation) with their own silent uninstall
        $exe, $arguments = Split-CommandLine $App.QuietUninstallString
        if ($arguments -notmatch 'norestart') { $arguments = "$arguments /norestart" }
    }
    elseif ($App.WindowsInstaller -eq 1 -and $key -match '^\{[0-9A-Fa-f-]{36}\}$') {
        $exe       = 'msiexec.exe'
        $arguments = "/x $key /qn /norestart"
    }
    elseif ($App.UninstallString -match 'InstallShield Installation Information') {
        # Dell Optimizer InstallShield wrapper
        $exe, $arguments = Split-CommandLine $App.UninstallString
        if ($arguments -notmatch 'silent') { $arguments = "$arguments -silent" }
    }
    else {
        Write-Log "SKIPPED: $name ($key) - no silent uninstall method. UninstallString: $($App.UninstallString)"
        return $result
    }

    if ($exe -ne 'msiexec.exe' -and -not (Test-Path -LiteralPath $exe)) {
        Write-Log "SKIPPED: $name ($key) - uninstaller not found: $exe"
        return $result
    }

    Write-Log "Removing: $name ($key) -> $exe $arguments"
    try {
        $proc = Start-Process -FilePath $exe -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
        $result.ExitCode = $proc.ExitCode
        if ($OkExitCodes -contains $proc.ExitCode) {
            $result.Result = 'OK'
            Write-Log "  OK: $name (exit code $($proc.ExitCode))"
        }
        else {
            $result.Result = 'ERROR'
            Write-Log "  ERROR: $name (exit code $($proc.ExitCode))"
        }
    }
    catch {
        $result.Result = 'ERROR'
        Write-Log "  ERROR: $name - $($_.Exception.Message)"
    }
    return $result
}

function Get-RemainingApps {
    foreach ($pattern in $AppPatterns) { Get-DellApps -Pattern $pattern | ForEach-Object { $_.DisplayName } }
}

Write-Log '===== Start Dell bloatware remediation ====='

$initial = @(Get-RemainingApps | Sort-Object -Unique)
$results = @()
$removedAppx = @()

foreach ($pattern in $AppPatterns) {
    # Wrappers (bundle/InstallShield) first; they take their hidden MSI components with them.
    # Then any MSIs that are left.
    $apps = @(Get-DellApps -Pattern $pattern | Sort-Object { $_.WindowsInstaller -eq 1 })
    foreach ($app in $apps) {
        # May already have been removed by an earlier uninstall
        if (-not (Test-Path -LiteralPath $app.PSPath)) { continue }
        $results += Invoke-Uninstall -App $app
    }
}

# Clean up leftover InstallShield registrations whose uninstaller no longer exists
foreach ($pattern in $AppPatterns) {
    foreach ($app in @(Get-DellApps -Pattern $pattern)) {
        if ($app.UninstallString -match 'InstallShield Installation Information') {
            $exe, $null = Split-CommandLine $app.UninstallString
            if (-not (Test-Path -LiteralPath $exe)) {
                Write-Log "Removing orphaned registration: $($app.DisplayName) ($($app.PSChildName))"
                Remove-Item -LiteralPath $app.PSPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# Provisioned Appx packages (prevents them from coming back for new user profiles)
try {
    Get-AppxProvisionedPackage -Online -ErrorAction Stop |
        Where-Object { $AppxPatterns -contains $_.DisplayName } |
        ForEach-Object {
            Write-Log "Removing provisioned Appx: $($_.PackageName)"
            Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -AllUsers -ErrorAction SilentlyContinue | Out-Null
            $removedAppx += "Appx: $($_.DisplayName)"
        }
}
catch {
    Write-Log "Provisioned Appx cleanup failed: $($_.Exception.Message.Trim())"
}

# Installed Appx packages for existing users (separate, so a failure here doesn't skip the above)
try {
    Get-AppxPackage -AllUsers -ErrorAction Stop |
        Where-Object { $AppxPatterns -contains $_.Name } |
        ForEach-Object {
            Write-Log "Removing Appx: $($_.PackageFullName)"
            Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction SilentlyContinue
        }
}
catch {
    Write-Log "Appx cleanup for existing users failed: $($_.Exception.Message.Trim())"
}

# Final check
$remaining = @(Get-RemainingApps | Sort-Object -Unique)

# Removed = present at the start and gone now (also covers hidden MSIs a wrapper took with it)
$removed = @($initial | Where-Object { $remaining -notcontains $_ }) + $removedAppx

# Failed = still present, with the reason from the uninstall attempt
$failed = foreach ($name in $remaining) {
    $attempts = @($results | Where-Object { $_.Name -eq $name })
    $lastError = $attempts | Where-Object Result -eq 'ERROR' | Select-Object -Last 1
    if ($lastError -and $null -ne $lastError.ExitCode) { "$name (exit code $($lastError.ExitCode))" }
    elseif ($lastError)                                { "$name (error, see log)" }
    elseif ($attempts.Result -contains 'SKIPPED')      { "$name (skipped, no silent uninstall)" }
    else                                               { "$name (still present)" }
}

$summaryRemoved = if ($removed) { $removed -join '; ' } else { '-' }
$summaryFailed  = if ($failed)  { $failed -join '; ' }  else { '-' }

try {
    New-Item -Path $SummaryKey -Force -ErrorAction Stop | Out-Null
    Set-ItemProperty -Path $SummaryKey -Name 'LastRun' -Value (Get-Date -Format 'yyyy-MM-dd HH:mm') -ErrorAction Stop
    Set-ItemProperty -Path $SummaryKey -Name 'Removed' -Value $summaryRemoved -ErrorAction Stop
    Set-ItemProperty -Path $SummaryKey -Name 'Failed'  -Value $summaryFailed -ErrorAction Stop
}
catch {
    Write-Log "Could not write summary to ${SummaryKey}: $($_.Exception.Message)"
}

Write-Log "Removed: $summaryRemoved"
Write-Log "Failed: $summaryFailed"

if ($remaining) {
    Write-Log '===== End (incomplete) ====='
    Write-Output "Removed: $summaryRemoved | Failed: $summaryFailed"
    exit 1
}

Write-Log '===== End (all removed) ====='
Write-Output "Removed: $summaryRemoved"
exit 0
