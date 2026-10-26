<#
.SYNOPSIS
    Intune Remediation - detects Dell update tools / bloatware.

.DESCRIPTION
    Looks for Dell tools that install drivers/BIOS on their own and trigger restarts
    (SupportAssist, Command | Update, Optimizer, Digital Delivery, Core Services).
    Drivers and firmware are delivered centrally through Windows Update / Intune.

    Exit 0 = nothing found (compliant)
    Exit 1 = found, remediation needed

    If Remediate-DellBloatware.ps1 has run before, its summary (removed / failed) is appended
    to the output, so it shows up in "Post-remediation detection output" in Intune.

    Intune settings: Run as logged-on credentials = No, Run in 64-bit PowerShell = Yes.
#>

# Keep this list identical to the one in Remediate-DellBloatware.ps1
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

# Summary of the last remediation run (keep identical in both scripts)
$SummaryKey = 'HKLM:\SOFTWARE\Remediations\DellBloatware'

# Intune truncates output at 2048 characters
$MaxOutputLength = 2000

$found = @()

$found += Get-ItemProperty -Path $UninstallKeys -ErrorAction SilentlyContinue |
    Where-Object {
        $name = $_.DisplayName
        $name -and ($AppPatterns | Where-Object { $name -like $_ })
    } |
    ForEach-Object { $_.DisplayName }

try {
    $found += Get-AppxProvisionedPackage -Online -ErrorAction Stop |
        Where-Object { $AppxPatterns -contains $_.DisplayName } |
        ForEach-Object { "Appx: $($_.DisplayName)" }
}
catch {
    # The Appx check is supplementary; don't fail on it
}

$found = $found | Sort-Object -Unique

if ($found) {
    $output = "Found: $($found -join '; ')"
}
else {
    $output = 'No Dell update tools / bloatware found'
}

$summary = Get-ItemProperty -Path $SummaryKey -ErrorAction SilentlyContinue
if ($summary) {
    $output += " | Last remediation $($summary.LastRun) - Removed: $($summary.Removed) | Failed: $($summary.Failed)"
}

if ($output.Length -gt $MaxOutputLength) {
    $output = $output.Substring(0, $MaxOutputLength - 3) + '...'
}

Write-Output $output
if ($found) { exit 1 }
exit 0
