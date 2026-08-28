<#
    Run-Tests.ps1

    Covers the two parts of Fix-AcerCameraDMFT.ps1 that break in silence.

    1. Reading reg.exe output. This decides whether the fix sees the problem at
       all, and when a regex stops matching nothing goes wrong loudly: the
       script just reports "this machine is already clean" and everyone goes
       home with a black webcam.

    2. Blocking and restoring camera access. This is the code that can leave a
       machine with no camera at all, so the round trip is tested against an
       in-memory registry, including the case where the run dies half way.

    No Windows and no dependencies needed - the function definitions are lifted
    out of the script with the parser, and reg.exe and the registry provider are
    replaced with stubs.

        pwsh -File tests/Run-Tests.ps1
        powershell -File tests\Run-Tests.ps1
#>

# A test harness breaks the rules on purpose: it shadows reg.exe and the registry
# cmdlets with stubs, and the stubs declare parameters they never read, because
# they only exist to swallow what the code under test passes them.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '',
    Justification = 'Shadowing the registry cmdlets is how the code under test is isolated.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'Stubs accept the real signature and ignore most of it.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'Stubs and test helpers, nothing here touches a real machine.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Fixture values are read inside functions, which the analyser does not follow.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Test output is meant for a human watching the console.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPositionalParameters', '',
    Justification = 'Assert-Equal reads better positionally.')]
param()

$ErrorActionPreference = 'Stop'
$script:Pass = 0
$script:Fail = 0

function Assert-Equal {
    param($Expected, $Actual, [string]$What)
    if ($Expected -eq $Actual) {
        $script:Pass++
        Write-Host ("  pass  {0}" -f $What) -ForegroundColor Green
    } else {
        $script:Fail++
        Write-Host ("  FAIL  {0}`n        expected <{1}>`n        actual   <{2}>" -f $What, $Expected, $Actual) -ForegroundColor Red
    }
}

# --- load the functions under test, without running the script ----------------

$target = Join-Path (Split-Path $PSScriptRoot -Parent) 'Fix-AcerCameraDMFT.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($target, [ref]$null, [ref]$null)
$defined = $ast.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)

foreach ($name in 'Get-DeviceInstanceIdFromKey', 'Get-DmftRegistration',
                  'Lock-CameraAccess', 'Unlock-CameraAccess') {
    $fn = $defined | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if (-not $fn) { throw "function $name not found in $target" }
    . ([scriptblock]::Create($fn.Extent.Text))
}

# The script-scope constants those functions read.
$Categories = [ordered]@{
    '{e5323777-f976-4f5b-9b55-b94699c46e44}' = 'KSCATEGORY_VIDEO_CAMERA'
    '{65E8773D-8F56-11D0-A3B9-00A0C9223196}' = 'KSCATEGORY_CAPTURE'
    '{6994AD05-93EF-11D0-A3CC-00A0C9223196}' = 'KSCATEGORY_VIDEO'
}
$ValueNames = @('CameraDeviceMftClsidChain', 'CameraDeviceMftClsid')

# --- fixtures -----------------------------------------------------------------

$CLSID = '{2EB17717-49CE-4B6C-85E7-58EE3AF41669}'
$IFACE = '##?#USB#VID_0408&PID_4033&MI_00#7&e6c6236&0&0000#{0}'

function New-RegOutput {
    param([string]$Guid, [string]$ValueName, [switch]$Clean)
    $base = "HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\DeviceClasses\$Guid"
    $iface = "$base\$($IFACE -f $Guid)"
    $lines = @(
        ''
        $base
        '    (Default)    REG_SZ    Video Capture Devices'
        ''
        $iface
        '    DeviceInstance    REG_SZ    USB\VID_0408&PID_4033&MI_00\7&e6c6236&0&0000'
        ''
        "$iface\#GLOBAL\Device Parameters"
        '    EnablePlatformDmft    REG_DWORD    0x1'
    )
    if (-not $Clean) { $lines += "    $ValueName    REG_MULTI_SZ    $CLSID" }
    $lines += ''
    $lines
}

# Stub for reg.exe. A function beats a native command in PowerShell's name
# resolution, so Get-DmftRegistration calls this instead of the real thing.
$script:RegMode = 'dirty'
$script:RegValueName = 'CameraDeviceMftClsidChain'
function reg {
    $root = $args[1]
    $guid = ($root -split '\\')[-1]
    if ($script:RegMode -eq 'clean')   { return @() }
    if ($script:RegMode -eq 'missing') { return $null }
    New-RegOutput -Guid $guid -ValueName $script:RegValueName
}

# ------------------------------------------------------------------------------

Write-Host "`nGet-DeviceInstanceIdFromKey" -ForegroundColor Cyan

$key = "HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\DeviceClasses\{e5323777-f976-4f5b-9b55-b94699c46e44}\##?#USB#VID_0408&PID_4033&MI_00#7&e6c6236&0&0000#{e5323777-f976-4f5b-9b55-b94699c46e44}\#GLOBAL\Device Parameters"
Assert-Equal 'USB\VID_0408&PID_4033&MI_00\7&e6c6236&0&0000' (Get-DeviceInstanceIdFromKey $key) `
    'decodes the interface path into a device instance id'

Assert-Equal $null (Get-DeviceInstanceIdFromKey 'HKEY_LOCAL_MACHINE\SYSTEM\Something\Else') `
    'returns nothing when the key holds no interface path'

Assert-Equal 'USB\VID_0408&PID_4033&MI_00\7&e6c6236&0&0000' `
    (Get-DeviceInstanceIdFromKey ($key -replace '\\#GLOBAL.*$', '')) `
    'works on the interface key itself, without the #GLOBAL suffix'

Write-Host "`nGet-DmftRegistration" -ForegroundColor Cyan

$script:RegMode = 'dirty'
$script:RegValueName = 'CameraDeviceMftClsidChain'
$found = @(Get-DmftRegistration)

Assert-Equal 3 $found.Count 'finds the registration in all three KS categories'
Assert-Equal 'KSCATEGORY_VIDEO_CAMERA' $found[0].Category 'labels the first category'
Assert-Equal 'KSCATEGORY_CAPTURE'      $found[1].Category 'labels the second category'
Assert-Equal 'KSCATEGORY_VIDEO'        $found[2].Category 'labels the third category'
Assert-Equal 'CameraDeviceMftClsidChain' $found[0].Name 'reads the value name'
Assert-Equal 'REG_MULTI_SZ'              $found[0].Type 'reads the value type'
Assert-Equal $CLSID                      $found[0].Data 'reads the CLSID out of the data column'
Assert-Equal 'USB\VID_0408&PID_4033&MI_00\7&e6c6236&0&0000' $found[0].InstanceId `
    'carries the device instance id, so the right device gets restarted'
Assert-Equal 1 (@($found | Select-Object -ExpandProperty InstanceId -Unique).Count) `
    'all three point at the same device'

# The legacy single-CLSID value name has to be picked up too: the vendor binary
# handles both, so some builds may write the older one.
$script:RegValueName = 'CameraDeviceMftClsid'
$legacy = @(Get-DmftRegistration)
Assert-Equal 3 $legacy.Count 'finds the legacy CameraDeviceMftClsid name as well'
Assert-Equal 'CameraDeviceMftClsid' $legacy[0].Name 'reports the legacy name unchanged'

# ...and the long name must not be counted twice, once for each pattern.
$script:RegValueName = 'CameraDeviceMftClsidChain'
$dupes = @(Get-DmftRegistration | Where-Object { $_.Category -eq 'KSCATEGORY_VIDEO_CAMERA' })
Assert-Equal 1 $dupes.Count 'does not match CameraDeviceMftClsidChain twice'

Write-Host "`nA clean machine" -ForegroundColor Cyan

$script:RegMode = 'clean'
Assert-Equal 0 @(Get-DmftRegistration).Count 'reports nothing when the values are gone'

$script:RegMode = 'missing'
Assert-Equal 0 @(Get-DmftRegistration).Count 'survives a category key that does not exist'

# ------------------------------------------------------------------------------

# --- camera access: block it, and always give it back -------------------------
#
# An in-memory stand-in for the two consent store keys. Everything the two
# functions touch on the registry goes through these four stubs; the state file
# is a real file, because the JSON round trip is part of what is being tested.

# The paths carry no drive qualifier on purpose: the functions build the
# NonPackaged path with Join-Path, and Join-Path refuses a drive that the
# session does not have - which "HKLM:" is not, off Windows.
$script:FakeReg = @{}
$WebcamKey     = Join-Path ([IO.Path]::GetTempPath()) 'FAKEREG-webcam'
$NonPackaged   = Join-Path $WebcamKey 'NonPackaged'

function Initialize-HkuDrive { }
function Write-CameraLog { param([string]$Message, [string]$Level = 'INFO') }
function Get-ConsentStoreRoot {
    @([pscustomobject]@{ Scope = 'Machine'; Path = $WebcamKey })
}
function Test-Path {
    param([string]$LiteralPath)
    if ($script:FakeReg.ContainsKey($LiteralPath)) { return $true }
    if ($LiteralPath -like '*FAKEREG-webcam*')     { return $false }
    Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath
}
function Get-ItemProperty {
    param([string]$LiteralPath, [string]$Name, $ErrorAction)
    $v = $script:FakeReg[$LiteralPath]
    if ($null -eq $v -or -not $v.ContainsKey($Name)) { return $null }
    [pscustomobject]@{ $Name = $v[$Name] }
}
function Set-ItemProperty {
    param([string]$LiteralPath, [string]$Name, $Value, $Type, [switch]$Force, $ErrorAction)
    $script:FakeReg[$LiteralPath][$Name] = $Value
}
function Remove-ItemProperty {
    param([string]$LiteralPath, [string]$Name, $ErrorAction)
    $script:FakeReg[$LiteralPath].Remove($Name) | Out-Null
}

$StateFile = Join-Path ([IO.Path]::GetTempPath()) ("camera-access-state-test-{0}.json" -f $PID)
function Reset-FakeReg {
    param($MachineValue, $NonPackagedValue)
    $script:FakeReg = @{
        $WebcamKey   = @{}
        $NonPackaged = @{}
    }
    if ($null -ne $MachineValue)     { $script:FakeReg[$WebcamKey]['Value'] = $MachineValue }
    if ($null -ne $NonPackagedValue) { $script:FakeReg[$NonPackaged]['Value'] = $NonPackagedValue }
    Remove-Item -LiteralPath $StateFile -Force -ErrorAction SilentlyContinue
}

Write-Host "`nLock-CameraAccess / Unlock-CameraAccess" -ForegroundColor Cyan

Reset-FakeReg -MachineValue 'Allow' -NonPackagedValue 'Allow'
$locked = Lock-CameraAccess
Assert-Equal $true  $locked 'reports that it changed something'
Assert-Equal 'Deny' $script:FakeReg[$WebcamKey]['Value']   'denies camera access machine wide'
Assert-Equal 'Deny' $script:FakeReg[$NonPackaged]['Value'] 'denies it for desktop apps too'
Assert-Equal $true  (Microsoft.PowerShell.Management\Test-Path $StateFile) `
    'writes the state file before touching anything'

Unlock-CameraAccess
Assert-Equal 'Allow' $script:FakeReg[$WebcamKey]['Value']   'gives machine wide access back'
Assert-Equal 'Allow' $script:FakeReg[$NonPackaged]['Value'] 'gives desktop app access back'
Assert-Equal $false  (Microsoft.PowerShell.Management\Test-Path $StateFile) `
    'clears the state file once everything is restored'

# A value that did not exist must not be left behind set to Deny.
Reset-FakeReg -MachineValue $null -NonPackagedValue 'Allow'
Lock-CameraAccess | Out-Null
Assert-Equal 'Deny' $script:FakeReg[$WebcamKey]['Value'] 'creates the value when the machine had none'
Unlock-CameraAccess
Assert-Equal $false ($script:FakeReg[$WebcamKey].ContainsKey('Value')) `
    'removes it again instead of leaving Deny behind'

# Someone who had already turned the camera off keeps it off afterwards.
Reset-FakeReg -MachineValue 'Deny' -NonPackagedValue 'Deny'
$locked = Lock-CameraAccess
Assert-Equal $false $locked 'does nothing when access was already denied'
Assert-Equal $false (Microsoft.PowerShell.Management\Test-Path $StateFile) `
    'writes no state file when it changed nothing'
Unlock-CameraAccess
Assert-Equal 'Deny' $script:FakeReg[$WebcamKey]['Value'] 'leaves a deliberately disabled camera disabled'

# The one that matters: the run dies after locking. The next run has to put the
# setting back from the state file alone, with nothing left in memory.
Reset-FakeReg -MachineValue 'Allow' -NonPackagedValue 'Allow'
Lock-CameraAccess | Out-Null
Assert-Equal 'Deny' $script:FakeReg[$WebcamKey]['Value'] 'camera is off mid-run'
$onDisk = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
Assert-Equal 2 @($onDisk).Count 'the state file remembers both keys'
Unlock-CameraAccess     # stands in for the next run finding the leftover file
Assert-Equal 'Allow' $script:FakeReg[$WebcamKey]['Value']   'a later run repairs the machine hive'
Assert-Equal 'Allow' $script:FakeReg[$NonPackaged]['Value'] 'and the desktop app switch'

Remove-Item -LiteralPath $StateFile -Force -ErrorAction SilentlyContinue

# ------------------------------------------------------------------------------

Write-Host ("`n{0} passed, {1} failed`n" -f $script:Pass, $script:Fail) `
    -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
exit $(if ($script:Fail) { 1 } else { 0 })
