<#
    Camera-Diag.ps1

    Read-only survey of the Windows camera pipeline. Writes everything to a text
    file and touches nothing.

    How it is meant to be used: run it on a broken machine and on a healthy one
    of the same model, then diff the two reports. The difference is the cause.
    It is not Acer specific - the DMFT section is worth a look on any laptop with
    a vendor "camera effects" stack (Dell, HP, Lenovo and Intel all ship one).

    Run from an elevated PowerShell, at the root of the repository:
        Set-ExecutionPolicy -Scope Process Bypass -Force
        .\tools\Camera-Diag.ps1

    If you are reporting a model you can attach the whole report to an issue -
    read it first, it contains your machine name and the list of applications
    that have used the camera.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Two lines telling the operator where the report was written.')]
[CmdletBinding()]
param(
    [string]$OutFile = "$env:USERPROFILE\Desktop\camera-diag-$env:COMPUTERNAME-$(Get-Date -Format yyyyMMdd-HHmmss).txt"
)

$ScriptVersion = '1.0.0'

# All three interface categories a Device MFT can be registered on. Looking at
# only the first one hides half the problem: DirectShow uses the other two.
$Categories = [ordered]@{
    '{e5323777-f976-4f5b-9b55-b94699c46e44}' = 'KSCATEGORY_VIDEO_CAMERA'
    '{65E8773D-8F56-11D0-A3B9-00A0C9223196}' = 'KSCATEGORY_CAPTURE'
    '{6994AD05-93EF-11D0-A3CC-00A0C9223196}' = 'KSCATEGORY_VIDEO'
}
$CLASS_CAMERA = '{ca3e7ab9-b4c3-4ae6-8251-579ef933890f}'
$ConsentBase  = 'SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam'

$out = New-Object System.Collections.Generic.List[string]
function W([string]$s = '') { $out.Add($s) }
function Section([string]$t) { W ''; W ('=' * 78); W "  $t"; W ('=' * 78) }

Section "1. SYSTEM"
W "Camera-Diag   : $ScriptVersion"
try {
    $cs = Get-CimInstance Win32_ComputerSystem
    $bi = Get-CimInstance Win32_BIOS
    $os = Get-CimInstance Win32_OperatingSystem
    W "Model         : $($cs.Manufacturer) $($cs.Model)"
    W "BIOS          : $($bi.SMBIOSBIOSVersion)  dated $($bi.ReleaseDate)"
    W "OS            : $($os.Caption) $($os.Version) build $($os.BuildNumber)"
    W "UBR           : $((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').UBR)"
    W "DisplayVersion: $((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').DisplayVersion)"
} catch { W "ERROR: $_" }

Section "2. FRAME SERVER SERVICES"
# FrameServer is trigger-start. Finding it Stopped while nothing is capturing is
# normal and is not the fault - that one cost me an afternoon.
foreach ($svc in 'FrameServer', 'FrameServerMonitor', 'DeviceInstall', 'DsmSvc') {
    try {
        $s = Get-Service -Name $svc -ErrorAction Stop
        $cfg = Get-CimInstance Win32_Service -Filter "Name='$svc'"
        W ("{0,-20} {1,-10} StartMode={2}" -f $svc, $s.Status, $cfg.StartMode)
    } catch { W ("{0,-20} NOT PRESENT" -f $svc) }
}

Section "3. CAMERA DEVICES"
try {
    $devs = Get-PnpDevice -Class Camera, Image, Media -ErrorAction SilentlyContinue |
            Where-Object { $_.InstanceId -match 'USB|ACPI|SWD' }
    foreach ($d in $devs) {
        W "FriendlyName : $($d.FriendlyName)"
        W "Class/Status : $($d.Class) / $($d.Status)"
        W "InstanceId   : $($d.InstanceId)"
        foreach ($k in 'DEVPKEY_Device_ProblemCode', 'DEVPKEY_Device_DriverInfPath',
                       'DEVPKEY_Device_DriverVersion', 'DEVPKEY_Device_DriverProvider',
                       'DEVPKEY_Device_HardwareIds') {
            try {
                $p = Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName $k -ErrorAction Stop
                W ("  {0,-30} {1}" -f ($k -replace 'DEVPKEY_Device_', ''), ($p.Data -join ' | '))
            } catch {
                # Not every device carries every property. Nothing to report.
                Write-Verbose "$k not present on $($d.InstanceId)"
            }
        }
        W ''
    }
} catch { W "ERROR: $_" }

Section "4. THIRD PARTY DRIVER PACKAGES (driver store)"
# The oemNN.inf numbers are assigned per machine - never key a script off them,
# match on the original inf name instead.
try {
    $drv = pnputil /enum-drivers
    $block = @()
    foreach ($l in $drv) {
        if ($l.Trim() -eq '' -and $block.Count) {
            $text = $block -join "`n"
            if ($text -match 'Camera|camera|Image|Media|Extension|SoftwareComponent') { W $text; W '' }
            $block = @()
        } elseif ($l.Trim() -ne '') { $block += $l }
    }
} catch { W "ERROR: $_" }

Section "5. DMFT / POST PROCESSING REGISTERED ON THE DEVICE   <<< THE INTERESTING ONE"
# A Device MFT (the OEM plug-in that gets to touch every frame) is registered
# here, on the device interface key - not in the driver store. This is why
# pnputil /delete-driver does not get rid of it.
#
# These paths contain '?' and '#'. The PowerShell registry provider reads them
# as wildcards and returns nothing at all, without an error. reg.exe treats them
# as literals, so that is what is used below.
$roots = @()
foreach ($guid in $Categories.Keys) {
    $roots += [pscustomobject]@{
        Label = $Categories[$guid]
        Path  = "HKLM\SYSTEM\CurrentControlSet\Control\DeviceClasses\$guid"
    }
}
$roots += [pscustomobject]@{ Label = 'Camera setup class'; Path = "HKLM\SYSTEM\CurrentControlSet\Control\Class\$CLASS_CAMERA" }

foreach ($r in $roots) {
    W "--- $($r.Label)"
    W "    $($r.Path)"
    $raw = & reg query $r.Path /s 2>$null
    $curKey = ''
    $found = $false
    foreach ($line in $raw) {
        if ($line -match '^HKEY_') { $curKey = $line.Trim() }
        elseif ($line -match 'Mft|Clsid|CLSID|CustomCaptureSource|PostProcessing|Effect') {
            W "  $curKey"
            W "      $($line.Trim())"
            $found = $true
        }
    }
    if (-not $found) { W "  (nothing registered - this is the clean state)" }
    W ''
}

Section "6. MEDIA FOUNDATION PLATFORM"
foreach ($k in @(
    'HKLM:\SOFTWARE\Microsoft\Windows Media Foundation\Platform',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Media Foundation\Platform'
)) {
    if (Test-Path $k) {
        W "$k"
        (Get-ItemProperty $k).PSObject.Properties |
            Where-Object { $_.Name -notmatch '^PS' } |
            ForEach-Object { W ("  {0,-35} {1}" -f $_.Name, $_.Value) }
    } else { W "$k  (absent)" }
}

Section "7. CAMERA PERMISSIONS AND WHO IS STREAMING"
foreach ($k in @("HKLM:\$ConsentBase", "HKCU:\$ConsentBase",
                 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy')) {
    if (Test-Path $k) {
        W "$k"
        (Get-ItemProperty $k).PSObject.Properties |
            Where-Object { $_.Name -notmatch '^PS' } |
            ForEach-Object { W ("  {0,-35} {1}" -f $_.Name, $_.Value) }
    } else { W "$k  (absent)" }
}
W ''
# LastUsedTimeStop still at zero means the app has the camera open right now.
W "Applications currently holding the camera:"
$any = $false
if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
    New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS -Scope Script -ErrorAction SilentlyContinue | Out-Null
}
$hives = @("HKLM:\$ConsentBase")
$sids = @(Get-ChildItem 'HKU:\' -ErrorAction SilentlyContinue |
          Where-Object { $_.PSChildName -match '^S-1-5-21-[\d\-]+$' })
foreach ($s in $sids) {
    $p = "HKU:\$($s.PSChildName)\$ConsentBase"
    if (Test-Path -LiteralPath $p) { $hives += $p }
}
foreach ($hive in $hives) {
    foreach ($branch in @($hive, (Join-Path $hive 'NonPackaged'))) {
        if (-not (Test-Path -LiteralPath $branch)) { continue }
        foreach ($k in @(Get-ChildItem -LiteralPath $branch -ErrorAction SilentlyContinue)) {
            if ($k.PSChildName -eq 'NonPackaged') { continue }
            $v = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
            if (-not $v -or $null -eq $v.LastUsedTimeStart) { continue }
            if ($v.LastUsedTimeStart -eq 0 -or $v.LastUsedTimeStop -ne 0) { continue }
            W ("  IN USE  {0}" -f ($k.PSChildName -replace '#', '\'))
            $any = $true
        }
    }
}
if (-not $any) { W "  (none)" }

Section "8. RECENT DRIVER INSTALLS (setupapi.dev.log)"
# This is where you see whether an update brought a driver package with it.
$log = "$env:SystemRoot\INF\setupapi.dev.log"
if (Test-Path $log) {
    try {
        $hits = Select-String -Path $log -Pattern 'Section start|Driver Package|oem\d+\.inf|camera' -ErrorAction SilentlyContinue
        W "Last 60 relevant lines of $log :"
        $hits | Select-Object -Last 60 | ForEach-Object { W ("  [{0}] {1}" -f $_.LineNumber, $_.Line.Trim()) }
        W ''
        W "Lines mentioning 'gaicamera' or 'Acer':"
        $acer = Select-String -Path $log -Pattern 'gaicamera|artaimmx|Acer' -ErrorAction SilentlyContinue
        if ($acer) { $acer | Select-Object -Last 40 | ForEach-Object { W ("  [{0}] {1}" -f $_.LineNumber, $_.Line.Trim()) } }
        else { W "  (none)" }
    } catch { W "ERROR reading the log: $_" }
} else { W "$log not found" }

Section "9. RECENTLY INSTALLED UPDATES"
try {
    Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 10 |
        ForEach-Object { W ("  {0,-12} {1,-18} {2}" -f $_.HotFixID, $_.Description, $_.InstalledOn) }
} catch { W "ERROR: $_" }
W ''
try {
    # QueryHistory lives on the searcher, not on the session.
    $searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
    $count = [Math]::Min($searcher.GetTotalHistoryCount(), 50)
    W "Windows Update history (last $count entries):"
    if ($count -gt 0) {
        $searcher.QueryHistory(0, $count) |
            Sort-Object Date -Descending |
            ForEach-Object { W ("  {0}  rc={1}  {2}" -f $_.Date, $_.ResultCode, $_.Title) }
    }
} catch { W "Update history not readable: $_" }

Section "10. DEVICE SETUP AND PNP EVENTS (last 7 days)"
foreach ($ch in 'Microsoft-Windows-DeviceSetupManager/Admin',
                'Microsoft-Windows-DeviceSetupManager/Operational',
                'Microsoft-Windows-Kernel-PnP/Configuration') {
    W "--- $ch"
    try {
        Get-WinEvent -FilterHashtable @{LogName = $ch; StartTime = (Get-Date).AddDays(-7)} -MaxEvents 25 -ErrorAction Stop |
            ForEach-Object { W ("  {0}  Id={1}  {2}" -f $_.TimeCreated, $_.Id, ($_.Message -split "`n")[0]) }
    } catch { W "  (channel unavailable or empty)" }
    W ''
}

Section "END"
$out | Set-Content -Path $OutFile -Encoding UTF8
Write-Host "Report written to: $OutFile" -ForegroundColor Green
Write-Host "Run it on a working machine of the same model too, then diff the two." -ForegroundColor Yellow
