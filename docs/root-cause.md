# Root cause write-up

Notes from the investigation, kept because the causal chain is nowhere on the
public internet and the symptom is everywhere. Dated 28 August 2026.

## The chain

```
[1] acerartaimmxdriverextension.inf   (Extension, 2.0.0.3024, 17/03/2025)
    binds to ACPI\VEN_1025&DEV_165F&SUBSYS_*1025
    → creates the child device  SWC\SWComp_AcerARTAIMMX
             |
[2] acerartaimmxdrivercomponent.inf   (SoftwareComponent, 2.0.3038.0, 14/07/2026)
    → copies AcerMediaService.dll into System32
    → registers COM CLSID {2EB17717-49CE-4B6C-85E7-58EE3AF41669} = "Acer Media Service"
    → installs three services, all Automatic:
        AcerARTAIMMXDriverService   (AAADSvc.exe)
        AcerARTAIMMXService         (ARTAimmxService.exe)
        AcerPixyService             (AcerPixyService.exe)
             |
[3] AAADSvc.exe → Create Process: DetectCameraDMFT.exe
    which writes, at runtime, on every boot:
        CameraDeviceMftClsidChain = {2EB17717-...}
    onto three device interface keys
             |
[4] Media Foundation builds the pipeline:
        DevProxy → Platform DMFT (EnablePlatformDmft=1) → Acer DMFT
             |
[5] After the August 2026 cumulative, the Acer DMFT stops delivering frames.
    No error, no event log entry: just zero frames.
    → black screen in every app, device state OK
             |
[6] Step [3] repeats at every boot → the fix undoes itself.
    Anything that only edits the registry gets overwritten at the next restart.
```

Step [6] is the part that explains the forums. Every registry-only remedy people
post does work — right up until the reboot. It was never a fix coming loose, it
was a service actively putting things back.

### Which side broke

`AcerMediaService.dll` 2.0.3038.0 is dated 14 July 2026, and the cameras kept
working until 27 August 2026. So the Acer component alone is not sufficient to
break anything: **the August Windows update is what made that DMFT
incompatible.** That distinction matters for a bug report and not at all for the
remediation, which is the same either way.

## The three keys

The detector writes to three interface categories, not one. Taken from the
Unicode strings inside `UninstallAcerCameraDMFT.exe`:

| GUID | Category |
|---|---|
| `{e5323777-f976-4f5b-9b55-b94699c46e44}` | KSCATEGORY_VIDEO_CAMERA |
| `{65E8773D-8F56-11D0-A3B9-00A0C9223196}` | KSCATEGORY_CAPTURE |
| `{6994AD05-93EF-11D0-A3CC-00A0C9223196}` | KSCATEGORY_VIDEO |

A full path, as it appears on a real machine:

```
HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\DeviceClasses\
  {e5323777-f976-4f5b-9b55-b94699c46e44}\
  ##?#USB#VID_0408&PID_4033&MI_00#7&e6c6236&0&0000#{e5323777-f976-4f5b-9b55-b94699c46e44}\
  #GLOBAL\Device Parameters

  EnablePlatformDmft         REG_DWORD      0x1
  CameraDeviceMftClsidChain  REG_MULTI_SZ   {2EB17717-49CE-4B6C-85E7-58EE3AF41669}
```

Two value names to look for: `CameraDeviceMftClsidChain` (the one in use here)
and `CameraDeviceMftClsid`, the older single-CLSID form. The Acer binary handles
both, so other builds may well use the second.

> If you write your own script: those paths contain `?` and `#`, which the
> PowerShell registry provider treats as wildcards. `Get-ChildItem` and
> `Get-ItemProperty` on a non-literal path come back empty **with no error**.
> Use `reg.exe`, or `-LiteralPath`. I lost an hour to this.

## Evidence

### COM registration

```
HKLM\SOFTWARE\Classes\CLSID\{2EB17717-49CE-4B6C-85E7-58EE3AF41669}
    (Default)        REG_SZ         Acer Media Service
  \InprocServer32
    (Default)        REG_EXPAND_SZ  %SystemRoot%\system32\AcerMediaService.dll
    ThreadingModel   REG_SZ         Both

HKLM\SOFTWARE\Classes\WOW6432Node\CLSID\{2EB17717-...}   → does not exist
```

No 32-bit registration. That matters: see "what does not work" below.

### The DLL

```
C:\Windows\System32\AcerMediaService.dll
  Size          1,405,520
  Written       14/07/2026 22:57
  CompanyName   Acer Inc.
  ProductName   ART-AIMMX
  FileVersion   2.0.3038.0
  Signature     valid, CN=Microsoft Windows Hardware Compatibility Publisher
```

`CoCreateInstance` on the CLSID **succeeds**. It is not a dangling reference and
nothing is missing: the DMFT loads fine and then fails inside the pipeline.

### Driver store

```
acerartaimmxdrivercomponent.inf_amd64_1edab11d1f18bae6   AcerMediaService.dll 2.0.3038.0  14/07/2026   ← active
acerartaimmxdrivercomponent.inf_amd64_263409b7d8b5c3fa   AcerMediaService.dll 2.0.0.3034  27/01/2026
```

```
oem17.inf  acerartaimmxdriverextension.inf   Extension          2.0.0.3024   17/03/2025
oem4.inf   acerartaimmxdrivercomponent.inf   SoftwareComponent  2.0.3038.0   14/07/2026
oem96.inf  acerartaimmxdrivercomponent.inf   SoftwareComponent  2.0.0.3034   27/01/2026
```

The `oemNN.inf` numbers are assigned per machine. Never key a script off them.

Package contents, for reference: `AAADSvc.exe`, `ARTAimmxService.exe`,
`AcerPixyService.exe`, `AcerMediaService.dll`, `AimmxClientAPI.dll`,
`DetectCameraDMFT.exe`, `UninstallAcerCameraDMFT.exe`, `opencv_world455.dll`
(59 MB), plus the usual VC++ runtime DLLs.

### Which service is the writer

Searching the three service binaries for `DetectCameraDMFT|CameraDeviceMft`:

```
AAADSvc.exe            "Create Process: DetectCameraDMFT.exe", "DetectCameraDMFT.exe"
ARTAimmxService.exe    (nothing)
AcerPixyService.exe    (nothing)
```

Only `AcerARTAIMMXDriverService` relaunches the detector, which is why the fix
disables that one and leaves the other two running.

### The vendor uninstaller

Strings in `UninstallAcerCameraDMFT.exe`:

```
RemoveDMFTChain Enter / RemoveDMFTChain End
RegDeleteValueW
CameraDeviceMftClsid / CameraDeviceMftClsidChain
SYSTEM\CurrentControlSet\Control\DeviceClasses\{e5323777-...}\
SYSTEM\CurrentControlSet\Control\DeviceClasses\{65E8773D-...}\
SYSTEM\CurrentControlSet\Control\DeviceClasses\{6994AD05-...}\
SOFTWARE\OEM\Acer ART-AIMMX Driver\Log
```

No usage strings and no command line switches, so it runs bare. It exits 0 in
about a second and clears all three categories. The log key it mentions did not
exist on the machine I tested, so there is no independent confirmation from the
tool itself — read the registry back instead, which is what the script does.

## What does not work, and why

Each of these was tried. None of them are worth repeating.

| Attempt | Why it fails |
|---|---|
| Reinstalling or rolling back the camera driver | Device status OK, problem code 0, Microsoft inbox `usbvideo.inf`. The break is above the driver |
| Privacy settings | Consent store says `Allow` in both HKLM and HKCU, no `AppPrivacy` policy |
| Resetting the Camera app | Black in Meet and everywhere else too. The reset does help — until the next boot |
| Starting the FrameServer service | It is trigger-start. Finding it stopped is normal. This is the single most misleading clue in the whole business |
| Uninstalling the KB with `wusa` | `wusa` does not remove drivers, and the registration is written at runtime by a service. The update was the trigger, not the thing to remove |
| `DISM /RestoreHealth`, `sfc /scannow` | The system files were fine |
| `EnableFrameServerMode = 0` | Cannot work. The registration is on KSCATEGORY_CAPTURE and KSCATEGORY_VIDEO as well, which is what DirectShow reads, and there is no 32-bit COM registration to fall back on |
| `pnputil /delete-driver` on the Acer packages | Removes the package from the store, not the registration already written on the device key — which comes back at the next boot anyway |
| Matching the extension and component versions | Wrong idea. Reading the INFs: the extension binds to an ACPI device and exists only to create the child software component. They are not supposed to be at the same version, and the 3024 / 3038 gap is normal |
| BIOS, physical shutter, Fn key | The software fix restores the picture, so the hardware was never the problem |

## Prevention

The component can come back through Windows Update or Acer Care Center. Options,
none of which I have settled on:

- `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate` →
  `ExcludeWUDriversInQualityUpdate = 1` (group policy: *Do not include drivers
  with Windows Updates*). Set and forget, but it blocks every driver from WU,
  not just this one.
- Device installation restrictions on the hardware ID
  `SWC\SWComp_AcerARTAIMMX`. **Do not block the camera's own hardware ID**
  (`USB\VID_0408&PID_4033`): the extension INF matches the same ID as the base
  driver, and you would take out the webcam.
- Or leave the service disabled and re-run the script from a scheduled task as a
  periodic check. That is what I do.

## Loose ends

- The sibling package family `acergaicameracomponent.inf` /
  `acergaicameraextensionnonnextgen.inf`, with services named "Acer GAI Camera
  Service" and "Acer GAI Camera Windows", appears to be the same mechanism under
  another name. Not confirmed, and the fix has never been run against it.
- `ffmpeg -f dshow -i video="<camera name>"` is the right discriminator if a
  future case does not match this pattern: it goes through DirectShow and tells
  you whether frames exist at all. Prepared, never needed.
- Running `Camera-Diag.ps1` on other Acer models — including working ones —
  would say whether the CLSID is the same everywhere. The script reads it rather
  than assuming it, but the data point would be worth having.
