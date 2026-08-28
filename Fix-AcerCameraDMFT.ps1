<#
.SYNOPSIS
    Removes the Acer ART-AIMMX Device MFT from the Windows camera pipeline and
    puts the webcam back on the plain Microsoft stack (usbvideo.inf + platform DMFT).

.DESCRIPTION
    The problem
        AcerARTAIMMXDriverService (AAADSvc.exe) launches DetectCameraDMFT.exe, which
        writes CameraDeviceMftClsidChain / CameraDeviceMftClsid into the device
        interface keys of the camera. Media Foundation then loads the Acer DMFT
        (AcerMediaService.dll) right after the platform DMFT. When that DMFT stops
        handing over frames, every application gets a black picture while the device
        keeps reporting state OK with no error code anywhere.

        The registration is written again at every boot, so deleting the registry
        values is not a fix on its own. The writer has to be stopped as well - that
        is why the usual registry tweaks "work until you reboot".

    What this does
        1. inventory (always, read-only)
        2. optionally take the camera away from whoever is streaming (-Force)
        3. stop and disable the service that re-registers the DMFT
        4. drop the registration using the vendor's own UninstallAcerCameraDMFT.exe,
           or by deleting the values directly (-Manual)
        5. verify by reading the registry back
        6. restart the camera device so the pipeline gets rebuilt

    Reversible: -Rollback puts the services back to Automatic and the detector
    restores the registration at the next boot.

.PARAMETER Apply
    Actually change things. Without it the script only reports. This is the default.

.PARAMETER Force
    Do not give up when the camera is busy. Blocks camera access system wide,
    closes whatever is streaming, stops the frame server, and escalates the device
    restart to a remove-and-rescan if the ordinary disable/enable cycle fails.
    Meant for unattended runs where you cannot ask the user to hang up first.
    Camera access is always put back the way it was before the script exits.

.PARAMETER Manual
    Skip UninstallAcerCameraDMFT.exe and delete the registry values directly.
    Fallback for machines where the vendor binary is gone.

.PARAMETER DisableAllServices
    Disable every Acer camera service found instead of only the one that writes
    the registration. Needed only if the registration reappears after a reboot.

.PARAMETER Rollback
    Put the services back to Automatic and start them, and restore camera access
    if an interrupted run left it blocked.

.PARAMETER LogDir
    Where the log, the registry backup and the camera access state file go.
    Defaults to %ProgramData%\CameraFix.

.EXAMPLE
    .\Fix-AcerCameraDMFT.ps1
    Read-only inventory. Changes nothing. Start here.

.EXAMPLE
    .\Fix-AcerCameraDMFT.ps1 -Apply

.EXAMPLE
    .\Fix-AcerCameraDMFT.ps1 -Apply -Force
    Same, but does not stop at "the camera is in use".

.EXAMPLE
    .\Fix-AcerCameraDMFT.ps1 -Rollback -Apply

.NOTES
    Needs an elevated PowerShell. Written for Windows PowerShell 5.1 on
    Windows 11 (builds 26100 and 26200). See README.md for scope and caveats.

    Exit codes
        0  clean: no third party DMFT registration left
        1  registration still present
        2  not running elevated
        3  registration removed but the device could not be restarted (reboot)
#>

# Write-Host is deliberate: an operator standing at the machine has to see the
# colour-coded result, and every line also goes to the log file. -Apply is this
# script's own dry-run gate, so the internal helpers do not each need -WhatIf on
# top of it; adding it would only make the console output confusing.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Console output is the point; everything is also written to the log file.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'The script gates every change behind -Apply, which is documented in the help.')]
[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$Force,
    [switch]$Manual,
    [switch]$DisableAllServices,
    [switch]$Rollback,
    [string]$LogDir = "$env:ProgramData\CameraFix"
)

# ------------------------------------------------------------------ constants -

$ScriptVersion = '1.0.0'

# Device interface categories the Acer detector writes to. There are three of
# them, not one: the strings inside UninstallAcerCameraDMFT.exe list all three,
# and cleaning only KSCATEGORY_VIDEO_CAMERA leaves the DirectShow path poisoned.
$Categories = [ordered]@{
    '{e5323777-f976-4f5b-9b55-b94699c46e44}' = 'KSCATEGORY_VIDEO_CAMERA'
    '{65E8773D-8F56-11D0-A3B9-00A0C9223196}' = 'KSCATEGORY_CAPTURE'
    '{6994AD05-93EF-11D0-A3CC-00A0C9223196}' = 'KSCATEGORY_VIDEO'
}

$ValueNames    = @('CameraDeviceMftClsidChain', 'CameraDeviceMftClsid')
$WriterService = 'AcerARTAIMMXDriverService'          # AAADSvc.exe -> DetectCameraDMFT.exe
$KnownServices = @('AcerARTAIMMXDriverService', 'AcerARTAIMMXService', 'AcerPixyService')
$PackageGlobs  = @('acerartaimmxdrivercomponent.inf_amd64_*', 'acergaicameracomponent.inf_amd64_*')
$DriverStore   = "$env:SystemRoot\System32\DriverStore\FileRepository"
$AcerLogKey    = 'HKLM:\SOFTWARE\OEM\Acer ART-AIMMX Driver\Log'
$ConsentBase   = 'SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam'
$FrameServices = @('FrameServer', 'FrameServerMonitor')

# Processes we will never kill even if the consent store points at them.
$NeverKill = @('svchost', 'csrss', 'wininit', 'winlogon', 'services', 'lsass',
               'smss', 'explorer', 'dwm', 'fontdrvhost', 'system')

$stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'
$LogFile   = Join-Path $LogDir "camera-fix-$env:COMPUTERNAME-$stamp.log"
$StateFile = Join-Path $LogDir 'camera-access-state.json'

$script:PackageLocationCache = @{}

# -------------------------------------------------------------------- helpers -

function Write-CameraLog {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR','OK','STEP')][string]$Level = 'INFO')
    $line = '{0} [{1,-5}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    $color = switch ($Level) { 'ERROR' {'Red'} 'WARN' {'Yellow'} 'OK' {'Green'} 'STEP' {'Cyan'} default {'Gray'} }
    Write-Host $line -ForegroundColor $color
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-PnpUtil {
    param([string[]]$Arguments)
    $out = & pnputil.exe @Arguments 2>&1
    $code = $LASTEXITCODE
    $out | Where-Object { "$_" -match '\S' } | ForEach-Object { Write-CameraLog ("  pnputil: {0}" -f "$_".Trim()) }
    # 3010 is "done, reboot to finish", not a failure.
    ($code -eq 0 -or $code -eq 3010)
}

# --------------------------------------------------------------- registration -

# Device interface paths contain '?' and '#', which the PowerShell registry
# provider reads as wildcards: Get-ChildItem on them silently returns nothing.
# reg.exe treats them as literals, so that is what we use here.
function Get-DeviceInstanceIdFromKey {
    param([string]$Key)
    $seg = ($Key -split '\\') | Where-Object { $_.StartsWith('##?#') } | Select-Object -First 1
    if (-not $seg) { return $null }
    $seg = $seg -replace '^##\?#', '' -replace '#\{[0-9a-fA-F-]+\}$', ''
    $seg -replace '#', '\'
}

function Get-DmftRegistration {
    $found = @()
    foreach ($guid in $Categories.Keys) {
        $root = "HKLM\SYSTEM\CurrentControlSet\Control\DeviceClasses\$guid"
        $raw = & reg query $root /s 2>$null
        if (-not $raw) { continue }
        $curKey = ''
        foreach ($line in $raw) {
            if ($line -match '^HKEY_') { $curKey = $line.Trim(); continue }
            foreach ($vn in $ValueNames) {
                if ($line -match "^\s+$vn\s+REG_") {
                    $parts = $line.Trim() -split '\s{2,}', 3
                    $found += [pscustomobject]@{
                        Category   = $Categories[$guid]
                        Key        = $curKey
                        Name       = $parts[0]
                        Type       = $parts[1]
                        Data       = if ($parts.Count -ge 3) { $parts[2] } else { '' }
                        InstanceId = Get-DeviceInstanceIdFromKey $curKey
                    }
                }
            }
        }
    }
    $found
}

function Backup-Registration {
    # One file per category. Concatenating reg exports into a single file
    # produces something that will not import back, which defeats the purpose.
    $files = @()
    foreach ($guid in $Categories.Keys) {
        $root = "HKLM\SYSTEM\CurrentControlSet\Control\DeviceClasses\$guid"
        $file = Join-Path $LogDir ("dmft-backup-{0}-{1}-{2}.reg" -f $env:COMPUTERNAME, $stamp, $Categories[$guid])
        & reg export $root $file /y 2>$null | Out-Null
        if (Test-Path -LiteralPath $file) { $files += $file; Write-CameraLog "Registry backup: $file" 'OK' }
    }
    $files
}

# -------------------------------------------------------------------- services -

function Get-AcerCameraService {
    $svc = @()
    foreach ($name in $KnownServices) {
        $s = Get-CimInstance Win32_Service -Filter "Name='$name'" -ErrorAction SilentlyContinue
        if ($s) { $svc += $s }
    }
    # The same stack ships under a second family name on part of the range
    # (acergaicameracomponent.inf, "Acer GAI Camera Service"). Rather than keep
    # guessing service names, pick them up from where the binary lives.
    $extra = @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
               Where-Object { $_.PathName -match 'acerartaimmx|acergaicamera' })
    foreach ($e in $extra) {
        if (@($svc).Name -notcontains $e.Name) { $svc += $e }
    }
    $svc
}

# ------------------------------------------------------------- camera consent -

# The consent store is per user. When this runs as SYSTEM (RMM, Intune, scheduled
# task) HKCU is SYSTEM's own hive, which never holds a camera, so we walk every
# loaded user hive under HKEY_USERS instead.
function Initialize-HkuDrive {
    if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS -Scope Global -ErrorAction SilentlyContinue | Out-Null
    }
}

function Get-ConsentStoreRoot {
    $roots = @([pscustomobject]@{ Scope = 'Machine'; Path = "HKLM:\$ConsentBase" })
    Initialize-HkuDrive
    $sids = @(Get-ChildItem 'HKU:\' -ErrorAction SilentlyContinue |
              Where-Object { $_.PSChildName -match '^S-1-5-21-[\d\-]+$' })
    foreach ($s in $sids) {
        $p = "HKU:\$($s.PSChildName)\$ConsentBase"
        if (Test-Path -LiteralPath $p) { $roots += [pscustomobject]@{ Scope = $s.PSChildName; Path = $p } }
    }
    $roots
}

function Get-PackageInstallLocation {
    param([string]$FamilyName)
    if ($script:PackageLocationCache.ContainsKey($FamilyName)) { return $script:PackageLocationCache[$FamilyName] }
    $loc = $null
    try {
        $pkg = Get-AppxPackage -AllUsers -PackageTypeFilter Main -ErrorAction SilentlyContinue |
               Where-Object { $_.PackageFamilyName -eq $FamilyName } | Select-Object -First 1
        if ($pkg) { $loc = $pkg.InstallLocation }
    } catch {
        # No Appx cmdlets, or the package is not installed for any user. Not
        # fatal: without it we simply cannot name the process behind a
        # packaged app, and the consent store entry is reported on its own.
        Write-Verbose "Get-AppxPackage unavailable: $($_.Exception.Message)"
    }
    $script:PackageLocationCache[$FamilyName] = $loc
    $loc
}

# An app that is streaming right now has LastUsedTimeStart set and
# LastUsedTimeStop still at zero. This is the same data Task Manager and the
# taskbar camera indicator read.
function Get-CameraHolder {
    $procs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $held  = @()
    foreach ($root in Get-ConsentStoreRoot) {
        foreach ($branch in @($root.Path, (Join-Path $root.Path 'NonPackaged'))) {
            if (-not (Test-Path -LiteralPath $branch)) { continue }
            foreach ($k in @(Get-ChildItem -LiteralPath $branch -ErrorAction SilentlyContinue)) {
                if ($k.PSChildName -eq 'NonPackaged') { continue }
                $v = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
                if (-not $v -or $null -eq $v.LastUsedTimeStart) { continue }
                if ($v.LastUsedTimeStart -eq 0 -or $v.LastUsedTimeStop -ne 0) { continue }

                $packaged = -not $branch.EndsWith('NonPackaged')
                $exe = if ($packaged) { $null } else { $k.PSChildName -replace '#', '\' }

                $match = @()
                if ($exe) {
                    $match = $procs | Where-Object { $_.ExecutablePath -and $_.ExecutablePath -ieq $exe }
                } else {
                    $inst = Get-PackageInstallLocation $k.PSChildName
                    if ($inst) {
                        $match = $procs | Where-Object {
                            $_.ExecutablePath -and $_.ExecutablePath.StartsWith($inst, [StringComparison]::OrdinalIgnoreCase)
                        }
                    }
                }

                $held += [pscustomobject]@{
                    Scope     = $root.Scope
                    Id        = $k.PSChildName
                    Display   = if ($exe) { $exe } else { $k.PSChildName }
                    Processes = @($match)
                }
            }
        }
    }
    $held
}

function Lock-CameraAccess {
    # This is the switch behind Settings > Privacy & security > Camera >
    # "Camera access". Turning it off makes the frame server drop the streams
    # that are already running, which is exactly what we need before touching
    # the device node.
    $saved = @()
    foreach ($root in Get-ConsentStoreRoot) {
        foreach ($path in @($root.Path, (Join-Path $root.Path 'NonPackaged'))) {
            if (-not (Test-Path -LiteralPath $path)) { continue }
            $cur = (Get-ItemProperty -LiteralPath $path -Name Value -ErrorAction SilentlyContinue).Value
            if ($cur -eq 'Deny') { continue }
            $saved += [pscustomobject]@{ Path = $path; Previous = $cur }
        }
    }
    if (-not $saved.Count) { Write-CameraLog 'Camera access was already denied everywhere.' 'INFO'; return $false }

    # Write the state file first: if this run dies halfway, the next one (or
    # -Rollback) still knows what to put back.
    $saved | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $StateFile -Encoding UTF8
    foreach ($e in $saved) {
        try {
            Set-ItemProperty -LiteralPath $e.Path -Name Value -Value 'Deny' -Type String -Force -ErrorAction Stop
            Write-CameraLog ("Camera access blocked: {0} ({1} -> Deny)" -f $e.Path, $(if ($e.Previous) { $e.Previous } else { 'not set' })) 'OK'
        } catch {
            Write-CameraLog ("Could not block camera access on {0}: {1}" -f $e.Path, $_.Exception.Message) 'WARN'
        }
    }
    $true
}

function Unlock-CameraAccess {
    if (-not (Test-Path -LiteralPath $StateFile)) { return }
    Initialize-HkuDrive     # the state file can name HKU paths, and the drive is not there by default
    $saved = @()
    try { $saved = @(Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json) }
    catch { Write-CameraLog "Cannot read $StateFile : $($_.Exception.Message)" 'ERROR'; return }

    foreach ($e in $saved) {
        if (-not $e.Path -or -not (Test-Path -LiteralPath $e.Path)) { continue }
        if ([string]::IsNullOrEmpty($e.Previous)) {
            Remove-ItemProperty -LiteralPath $e.Path -Name Value -ErrorAction SilentlyContinue
            Write-CameraLog ("Camera access restored: {0} (value removed)" -f $e.Path) 'OK'
        } else {
            Set-ItemProperty -LiteralPath $e.Path -Name Value -Value $e.Previous -Type String -Force
            Write-CameraLog ("Camera access restored: {0} -> {1}" -f $e.Path, $e.Previous) 'OK'
        }
    }
    Remove-Item -LiteralPath $StateFile -Force -ErrorAction SilentlyContinue
}

function Stop-CameraHolder {
    # Chromium browsers keep the capture device in a dedicated utility process.
    # Killing that one drops the camera and leaves the tabs alone, which is a lot
    # kinder than shooting the whole browser; we only go after the application
    # itself if the camera is still held afterwards.
    $capture = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
                 Where-Object { $_.CommandLine -match 'utility-sub-type=video_capture' })
    foreach ($c in $capture) {
        Write-CameraLog ("Closing capture helper {0} (PID {1})" -f $c.Name, $c.ProcessId) 'OK'
        Stop-Process -Id $c.ProcessId -Force -ErrorAction SilentlyContinue
    }
    if ($capture.Count) { Start-Sleep -Seconds 2 }

    $still = @(Get-CameraHolder)
    if (-not $still.Count) { Write-CameraLog 'Camera released.' 'OK'; return }

    foreach ($h in $still) {
        if (-not $h.Processes.Count) {
            Write-CameraLog ("{0} still marked as streaming but no process matches it (stale entry)" -f $h.Display) 'WARN'
            continue
        }
        foreach ($p in $h.Processes) {
            $short = ($p.Name -replace '\.exe$', '').ToLower()
            if ($NeverKill -contains $short) { Write-CameraLog "Refusing to kill $($p.Name)" 'WARN'; continue }
            Write-CameraLog ("Closing {0} (PID {1}) - it is holding the camera" -f $p.Name, $p.ProcessId) 'WARN'
            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
    Start-Sleep -Seconds 2
}

function Stop-FrameServerStack {
    foreach ($n in $FrameServices) {
        $s = Get-Service -Name $n -ErrorAction SilentlyContinue
        if (-not $s -or $s.Status -eq 'Stopped') { continue }
        $stopped = $false
        try {
            Stop-Service -Name $n -Force -ErrorAction Stop
            Write-CameraLog "$n stopped" 'OK'
            $stopped = $true
        } catch {
            Write-CameraLog "$n would not stop: $($_.Exception.Message)" 'WARN'
        }
        if ($stopped) { continue }

        $svc = Get-CimInstance Win32_Service -Filter "Name='$n'" -ErrorAction SilentlyContinue
        if (-not $svc -or -not $svc.ProcessId) { continue }
        $siblings = @(Get-CimInstance Win32_Service -Filter "ProcessId=$($svc.ProcessId)" -ErrorAction SilentlyContinue |
                      Select-Object -ExpandProperty Name)
        $foreign = @($siblings | Where-Object { $FrameServices -notcontains $_ })
        if ($foreign.Count) {
            Write-CameraLog ("Leaving PID {0} alone, it also hosts {1}" -f $svc.ProcessId, ($foreign -join ', ')) 'WARN'
        } else {
            Stop-Process -Id $svc.ProcessId -Force -ErrorAction SilentlyContinue
            Write-CameraLog ("Killed the host process of {0} (PID {1})" -f $n, $svc.ProcessId) 'WARN'
        }
    }
    # Both are trigger-start services: Windows brings them back when an app asks
    # for a camera. Nothing to re-enable here.
}

# --------------------------------------------------------------- device reset -

function Test-CameraDeviceHealthy {
    param([string]$InstanceId)
    $d = Get-PnpDevice -InstanceId $InstanceId -ErrorAction SilentlyContinue
    ($null -ne $d -and $d.Status -eq 'OK')
}

function Reset-CameraDevice {
    param([string]$InstanceId, [switch]$Force)

    Write-CameraLog ("Restarting {0}" -f $InstanceId)

    # pnputil /restart-device exists on Windows 11 and is the cleanest of the
    # three. On Windows 10 it prints usage and exits non zero, so we fall through.
    if (Invoke-PnpUtil @('/restart-device', $InstanceId)) {
        if (Test-CameraDeviceHealthy $InstanceId) { Write-CameraLog 'Restarted with pnputil /restart-device' 'OK'; return $true }
    }

    try {
        Disable-PnpDevice -InstanceId $InstanceId -Confirm:$false -ErrorAction Stop
        Start-Sleep -Seconds 2
        Enable-PnpDevice -InstanceId $InstanceId -Confirm:$false -ErrorAction Stop
        Write-CameraLog 'Restarted with disable/enable' 'OK'
        return $true
    } catch {
        Write-CameraLog ("disable/enable failed: {0}" -f $_.Exception.Message) 'WARN'
    }

    if (-not $Force) {
        Write-CameraLog 'Device is in use. Re-run with -Force, or reboot: a reboot has the same effect.' 'WARN'
        return $false
    }

    # Last resort. Only for USB devices: those get re-enumerated by a rescan.
    # An internal MIPI camera on the SoC bus may not come back without a reboot,
    # and leaving a machine without a camera is worse than leaving the fix
    # pending until the next restart.
    if ($InstanceId -notlike 'USB\*') {
        Write-CameraLog "Not removing $InstanceId : remove and rescan is only safe on USB. Reboot instead." 'WARN'
        return $false
    }

    Write-CameraLog 'Removing the device node and rescanning.' 'WARN'
    Invoke-PnpUtil @('/remove-device', $InstanceId) | Out-Null
    Invoke-PnpUtil @('/scan-devices') | Out-Null
    for ($i = 1; $i -le 20; $i++) {
        if (Test-CameraDeviceHealthy $InstanceId) { Write-CameraLog 'Device came back after the rescan' 'OK'; return $true }
        Start-Sleep -Seconds 1
        if ($i -eq 10) { Invoke-PnpUtil @('/scan-devices') | Out-Null }
    }
    Write-CameraLog 'Device did not come back within 20s. Reboot so Windows re-enumerates it.' 'ERROR'
    $false
}

# ---------------------------------------------------------------------- start -

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

Write-CameraLog "=== Fix-AcerCameraDMFT $ScriptVersion on $env:COMPUTERNAME ===" 'STEP'
Write-CameraLog ("Mode: {0}{1}" -f $(if ($Apply) { 'APPLY' } else { 'DRY RUN (read only)' }), $(if ($Force) { ' +FORCE' } else { '' })) 'STEP'

if (-not (Test-Admin)) {
    Write-CameraLog 'This needs an elevated PowerShell. Stopping.' 'ERROR'
    exit 2
}

try {
    $cs = Get-CimInstance Win32_ComputerSystem
    $os = Get-CimInstance Win32_OperatingSystem
    Write-CameraLog ("Machine: {0} {1} | {2} build {3}" -f $cs.Manufacturer, $cs.Model, $os.Caption, $os.BuildNumber)
} catch {
    # Cosmetic banner only. If CIM is unhappy the fix still works.
    Write-CameraLog "Could not read the machine description: $($_.Exception.Message)" 'WARN'
}

# An interrupted -Force run leaves the camera switched off. Put it back before
# doing anything else, whatever mode we are in.
if (Test-Path -LiteralPath $StateFile) {
    Write-CameraLog 'A previous run left camera access blocked. Restoring it now.' 'WARN'
    Unlock-CameraAccess
}

$services = @(Get-AcerCameraService)

# ------------------------------------------------------------------- rollback -

if ($Rollback) {
    Write-CameraLog '--- ROLLBACK: putting the Acer services back ---' 'STEP'
    if (-not $services.Count) { Write-CameraLog 'No Acer camera service on this machine.' 'WARN' }
    foreach ($s in $services) {
        if ($Apply) {
            Set-Service -Name $s.Name -StartupType Automatic
            Start-Service -Name $s.Name -ErrorAction SilentlyContinue
            Write-CameraLog "$($s.Name) -> Automatic, started" 'OK'
        } else {
            Write-CameraLog "[dry run] $($s.Name) -> Automatic + start"
        }
    }
    Write-CameraLog 'Reboot: DetectCameraDMFT will write the registration back at the next boot.' 'INFO'
    exit 0
}

# ---------------------------------------------------------------- 1 inventory -

Write-CameraLog '--- 1. Inventory ---' 'STEP'

$pkg = @()
foreach ($glob in $PackageGlobs) {
    $pkg += Get-ChildItem -Path $DriverStore -Directory -Filter $glob -ErrorAction SilentlyContinue
}
$pkg = @($pkg | Sort-Object LastWriteTime -Descending)

if ($pkg.Count) {
    foreach ($p in $pkg) {
        $dll = Join-Path $p.FullName 'AcerMediaService.dll'
        $ver = if (Test-Path -LiteralPath $dll) { (Get-Item -LiteralPath $dll).VersionInfo.FileVersion } else { 'n/a' }
        Write-CameraLog ("Package: {0}  (AcerMediaService.dll {1})" -f $p.Name, $ver)
    }
} else {
    Write-CameraLog 'No Acer camera component package in the driver store.' 'WARN'
}

if ($services.Count) {
    foreach ($s in $services) { Write-CameraLog ("Service {0,-28} {1,-9} StartMode={2}" -f $s.Name, $s.State, $s.StartMode) }
} else {
    Write-CameraLog 'No Acer camera service present.'
}

$holders = @(Get-CameraHolder)
if ($holders.Count) {
    foreach ($h in $holders) {
        $pids = if ($h.Processes.Count) { ($h.Processes | ForEach-Object { "$($_.Name)/$($_.ProcessId)" }) -join ', ' } else { 'no live process' }
        Write-CameraLog ("CAMERA IN USE by {0}  [{1}]" -f $h.Display, $pids) 'WARN'
    }
    if (-not $Force) { Write-CameraLog 'Without -Force the device restart will most likely fail. See README.' 'WARN' }
} else {
    Write-CameraLog 'Nothing is streaming from the camera right now.' 'OK'
}

$before = @(Get-DmftRegistration)
if ($before.Count) {
    foreach ($r in $before) {
        Write-CameraLog ("REGISTRATION  [{0}]  {1} = {2}" -f $r.Category, $r.Name, $r.Data) 'WARN'
        Write-CameraLog ("              {0}" -f $r.Key)
    }
} else {
    Write-CameraLog 'No third party DMFT registration found: this machine is already clean.' 'OK'
    if (-not $Apply) { Write-CameraLog 'Nothing to do.' 'OK'; exit 0 }
}

if (-not $Apply) {
    Write-CameraLog ''
    Write-CameraLog 'Dry run finished. Re-run with -Apply to change anything.' 'STEP'
    Write-CameraLog "Log: $LogFile"
    exit 0
}

# ----------------------------------------------------------------------- work -

$cameraLocked = $false
$resetOk      = $true

try {

    # ------------------------------------------------- 2 stop the writer ------
    Write-CameraLog '--- 2. Stopping whatever writes the registration ---' 'STEP'

    $targets = if ($DisableAllServices) { @($services.Name) } else { @($WriterService) }
    foreach ($name in $targets) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if (-not $svc) { Write-CameraLog "$name is not installed, skipping" 'WARN'; continue }
        try {
            Stop-Service -Name $name -Force -ErrorAction Stop
            Set-Service  -Name $name -StartupType Disabled
            Write-CameraLog "$name stopped and disabled" 'OK'
        } catch {
            Write-CameraLog "$name : $($_.Exception.Message)" 'ERROR'
        }
    }
    Get-Process -Name 'DetectCameraDMFT' -ErrorAction SilentlyContinue |
        ForEach-Object { Stop-Process -Id $_.Id -Force; Write-CameraLog "Killed DetectCameraDMFT PID $($_.Id)" 'OK' }

    # ---------------------------------------------- 3 drop the registration ---
    Write-CameraLog '--- 3. Removing the DMFT registration ---' 'STEP'
    Backup-Registration | Out-Null

    $usedVendorTool = $false
    if (-not $Manual -and $pkg.Count) {
        $uninst = $null
        foreach ($p in $pkg) {
            $cand = Join-Path $p.FullName 'UninstallAcerCameraDMFT.exe'
            if (Test-Path -LiteralPath $cand) { $uninst = $cand; break }
        }
        if ($uninst) {
            Write-CameraLog "Running the vendor uninstaller: $uninst"
            try {
                $proc = Start-Process -FilePath $uninst -Wait -PassThru -WindowStyle Hidden
                Write-CameraLog ("UninstallAcerCameraDMFT.exe exit code {0}" -f $proc.ExitCode) $(if ($proc.ExitCode -eq 0) {'OK'} else {'WARN'})
                $usedVendorTool = $true
            } catch {
                Write-CameraLog "Could not run it: $($_.Exception.Message)" 'ERROR'
            }
            if (Test-Path $AcerLogKey) {
                (Get-ItemProperty $AcerLogKey).PSObject.Properties |
                    Where-Object { $_.Name -notmatch '^PS' } |
                    ForEach-Object { Write-CameraLog ("  vendor log: {0} = {1}" -f $_.Name, $_.Value) }
            }
        } else {
            Write-CameraLog 'UninstallAcerCameraDMFT.exe not found, deleting the values directly.' 'WARN'
        }
    }

    $leftover = @(Get-DmftRegistration)
    if ($leftover.Count) {
        if ($usedVendorTool) { Write-CameraLog 'The vendor uninstaller left something behind, cleaning up by hand.' 'WARN' }
        foreach ($r in $leftover) {
            & reg delete "$($r.Key)" /v $r.Name /f 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { Write-CameraLog ("Deleted {0} from [{1}]" -f $r.Name, $r.Category) 'OK' }
            else                     { Write-CameraLog ("Could not delete {0} in {1}" -f $r.Name, $r.Key) 'ERROR' }
        }
    }

    # ----------------------------------------------------------- 4 verify -----
    Write-CameraLog '--- 4. Verify ---' 'STEP'
    $after = @(Get-DmftRegistration)
    if ($after.Count) {
        foreach ($r in $after) { Write-CameraLog ("LEFTOVER [{0}] {1} -> {2}" -f $r.Category, $r.Name, $r.Key) 'ERROR' }
    } else {
        Write-CameraLog 'No DMFT registration left in any of the three categories.' 'OK'
    }

    # -------------------------------------------- 5 free and restart device ---
    Write-CameraLog '--- 5. Restarting the camera device ---' 'STEP'

    if ($Force) {
        Write-CameraLog 'Taking the camera by force.' 'STEP'
        $cameraLocked = Lock-CameraAccess
        Start-Sleep -Seconds 2
        Stop-CameraHolder
        Stop-FrameServerStack
    } else {
        $holders = @(Get-CameraHolder)
        if ($holders.Count) { Write-CameraLog 'The camera is in use, the restart may fail. -Force takes it anyway.' 'WARN' }
        & sc.exe stop FrameServer 2>&1 | Out-Null
    }

    $ids = @()
    $ids += @($before | Where-Object { $_.InstanceId } | Select-Object -ExpandProperty InstanceId)
    $ids += @(Get-PnpDevice -Class Camera -ErrorAction SilentlyContinue |
              Where-Object { $_.InstanceId -like 'USB\*' } | Select-Object -ExpandProperty InstanceId)
    $ids = @($ids | Sort-Object -Unique)

    if (-not $ids.Count) {
        Write-CameraLog 'No camera device to restart. Reboot to rebuild the pipeline.' 'WARN'
        $resetOk = $false
    }
    foreach ($id in $ids) {
        if (-not (Reset-CameraDevice -InstanceId $id -Force:$Force)) { $resetOk = $false }
    }

} finally {
    if ($cameraLocked) {
        Write-CameraLog 'Restoring camera access.' 'STEP'
        Unlock-CameraAccess
    }
}

# ------------------------------------------------------------------- summary --

$after = @(Get-DmftRegistration)

Write-CameraLog ''
Write-CameraLog '=== SUMMARY ===' 'STEP'
Write-CameraLog ("Registrations before : {0}" -f $before.Count)
Write-CameraLog ("Registrations after  : {0}" -f $after.Count)
Write-CameraLog ("Camera device restart: {0}" -f $(if ($resetOk) { 'ok' } else { 'incomplete, reboot' }))
Write-CameraLog ("Log                  : {0}" -f $LogFile)
Write-CameraLog ''
Write-CameraLog 'Try the camera now. Then reboot and run this script again without -Apply:' 'STEP'
Write-CameraLog 'if the registrations are still gone after the reboot, the fix is holding.' 'INFO'
Write-CameraLog 'If they came back, run it again with -Apply -DisableAllServices.' 'INFO'

if ($after.Count) { exit 1 }
if (-not $resetOk) { exit 3 }
exit 0
