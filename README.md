# Dell bloatware remediation for Intune

An Intune Remediation (detection + remediation script) that removes the preinstalled Dell update tools from Dell laptops and desktops.

## Why

Dell ships devices with tools such as **SupportAssist** and **Dell Command | Update**. These install drivers and BIOS updates on their own and prompt for restarts. When drivers and firmware are already delivered through **Windows Update / Intune**, you end up with:

- two sources that each want to install their own driver and BIOS versions;
- far more restarts than necessary, spread across the week;
- firmware that can flip back and forth between versions.

This remediation removes the Dell tools, so Windows Update / Intune is the only source for drivers and firmware.

## What gets removed

| Application | Type |
|---|---|
| Dell SupportAssist | MSI |
| Dell SupportAssist Remediation | Bundle (exe) + hidden MSI |
| SupportAssist Recovery Assistant | MSI |
| Dell Command \| Update (all variants) | MSI |
| Dell Update | MSI |
| Dell Optimizer | InstallShield wrapper + hidden MSI |
| Dell Digital Delivery | MSI |
| Dell Core Services | MSI |

The following Store (Appx) packages are also removed, including provisioned ones:
`DellInc.DellSupportAssistforPCs`, `DellInc.DellCommandUpdate`, `DellInc.DellOptimizer`, `DellInc.DellDigitalDelivery`, `DellInc.DellUpdate`.

Drivers, firmware and other Dell software (for example Dell Command | Configure or Dell Command | Monitor) are **not** touched.

## Files

| File | Purpose |
|---|---|
| `Detect-DellBloatware.ps1` | Detection script. Exits `1` if any of the tools is present, `0` if the device is clean. Adds the summary of the last remediation run to its output. |
| `Remediate-DellBloatware.ps1` | Remediation script. Removes everything silently, without restarting, verifies what is gone and stores a summary (removed / failed) in the registry. |

## How it works

- Applications are matched by **name** (DisplayName in the 64-bit and 32-bit Uninstall registry keys), not by GUID, so other models and versions are covered too.
- For each application the remediation script picks the best silent method:
  1. the application's own `QuietUninstallString` (bundles);
  2. `msiexec /x {GUID} /qn /norestart` for MSIs;
  3. `-remove -runfromtemp -silent` for the Dell Optimizer InstallShield wrapper.
- Wrappers are removed first, then any remaining MSIs. **Dell Core Services goes last**, because the other tools depend on it.
- Leftover InstallShield registrations whose uninstaller no longer exists are cleaned up.
- Exit codes `0`, `1605`, `1614`, `1641` and `3010` count as success.
- The script **never** restarts the device. That happens at the next Windows Update restart or when the user restarts.

## Deploying in Intune

1. Go to **Devices › Scripts and remediations › Create**.
2. Upload `Detect-DellBloatware.ps1` as the detection script and `Remediate-DellBloatware.ps1` as the remediation script.
3. Use these settings:

   | Setting | Value |
   |---|---|
   | Run this script using the logged-on credentials | **No** (runs as SYSTEM) |
   | Enforce script signature check | **No** (unless you sign the scripts yourself) |
   | Run script in 64-bit PowerShell | **Yes**, otherwise the script cannot see the 64-bit registry |

4. Assign the remediation to a group of Dell devices, for example a dynamic group with `device.deviceManufacturer -eq "Dell Inc."`.
5. Pick a schedule, for example **daily**.

> **Recommendation:** deploy to a small pilot group first and check the logs before rolling out broadly.

## Logging and monitoring

The remediation script logs to:

```
C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\Remediate-DellBloatware.log
```

This file is included when you use **Collect diagnostics** in Intune.

### Output in Intune

Intune only shows the output of the **detection** script (and errors written by the remediation script), not the regular output of the remediation script. To still see what the remediation did, the remediation script stores a summary of its last run in the registry:

```
HKLM:\SOFTWARE\Remediations\DellBloatware
    LastRun   e.g. 2026-10-26 14:05
    Removed   applications that were present at the start and are gone now
    Failed    applications that are still present, with the reason
```

The detection script appends this summary to its output. Per device you see:

| Intune column | Shows |
|---|---|
| Pre-remediation detection output | What was **found**: `Found: Dell SupportAssist; Dell Command \| Update; ...` |
| Post-remediation detection output | What is **still present** (if anything) plus the summary of the run: what was **removed** and what **failed** |

Example of a *Post-remediation detection output* where one application could not be removed:

```
Found: Dell Optimizer | Last remediation 2026-10-26 14:05 - Removed: Dell Command | Update for Windows Universal; Dell Core Services; Dell SupportAssist; Dell SupportAssist Remediation; Dell.Digital.Delivery-64Bit; SupportAssist Recovery Assistant | Failed: Dell Optimizer (exit code 1603)
```

On a clean device:

```
No Dell update tools / bloatware found | Last remediation 2026-10-26 14:05 - Removed: Dell Command | Update for Windows Universal; ... | Failed: -
```

Notes:

- *Removed* is based on what is actually gone after the run, not just on exit codes. Hidden components that a wrapper removed along with itself are also included.
- *Failed* shows the exit code, `error, see log`, `skipped, no silent uninstall` or `still present`.
- The summary stays in the registry, so on later detection runs it also shows up in *Pre-remediation detection output*. Check the `LastRun` timestamp.
- Intune truncates output at 2048 characters; the detection script cuts it off at 2000 characters.
- If you no longer want the summary, delete the `HKLM:\SOFTWARE\Remediations\DellBloatware` key.

## Customizing

The applications to remove are listed in `$AppPatterns` and `$AppxPatterns` at the top of **both** scripts. Keep these lists identical in both scripts.

The order of `$AppPatterns` is also the removal order. Keep `Dell Core Services*` last.

## Recommended Intune policy alongside this

This remediation only fixes the Dell side. To reduce restarts further:

- **Pick one source for drivers.** Let Windows Update / Autopatch deliver drivers and firmware, optionally with manual approval in the driver update policy, so BIOS updates don't arrive untested.
- **Set realistic deadlines** in the update ring, for example a 5–7 day deadline and a 2–3 day grace period, with sensible active hours. Restarts then get bundled instead of being forced every few days.

## Known limitations

- The silent uninstall of Dell Optimizer (`-silent`) may differ between versions. If it fails, "Dell Optimizer" shows up under `Failed` in the post-remediation detection output; check the log.
- Applications without a silent uninstall method are skipped and logged with `SKIPPED`.
- Dell may introduce new tools or rename existing ones. Review the `$AppPatterns` list from time to time.
