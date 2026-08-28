# Acer webcam black screen — root cause and fix

Your Acer laptop shows a **black picture in every application** — Camera app,
Google Meet, Teams, Zoom, the browser — while Device Manager insists the webcam
is *working properly*, with no yellow triangle and no error code. Reinstalling
the driver does nothing. Resetting the Camera app helps until the next reboot.

This repository explains why, and fixes it.

Short version: Acer ships a **Device MFT** — a plug-in that sits inside the
Windows camera pipeline and gets to touch every frame before your application
sees it. A background service re-registers that plug-in at every boot. When the
plug-in stops handing frames over, everything downstream goes black while the
driver and the device stay perfectly healthy, because nothing has actually
failed as far as Windows is concerned.

On the fleet where I found it, the plug-in went quiet after the Windows
cumulative updates of August 2026. It had been installed since 14 July 2026 and
the cameras kept working for six weeks, so the update is what made it
incompatible, not the component on its own.

The reason the registry tweaks you find in forum threads "work until you reboot"
is that `DetectCameraDMFT.exe` writes the registration back at every startup. You
have to stop the writer, not just delete what it wrote.

---

## Is this actually your problem?

Do not run the fix blind. Run it in its default read-only mode first:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\Fix-AcerCameraDMFT.ps1
```

Look for lines like this:

```
14:02:11 [WARN ] REGISTRATION  [KSCATEGORY_VIDEO_CAMERA]  CameraDeviceMftClsidChain = {2EB17717-49CE-4B6C-85E7-58EE3AF41669}
14:02:11 [WARN ] REGISTRATION  [KSCATEGORY_CAPTURE]       CameraDeviceMftClsidChain = {2EB17717-49CE-4B6C-85E7-58EE3AF41669}
14:02:11 [WARN ] REGISTRATION  [KSCATEGORY_VIDEO]         CameraDeviceMftClsidChain = {2EB17717-49CE-4B6C-85E7-58EE3AF41669}
```

**No `REGISTRATION` line, no match.** Your black screen has some other cause and
this repo will not help you — stop here rather than start deleting things. The
symptom is extremely common and most of the threads about it turn out to be dead
webcam modules, a privacy toggle, a physical shutter, or a laptop from 2016.

The script changes nothing at all unless you pass `-Apply`.

### Symptoms that match

| What you see | What is actually happening |
|---|---|
| Black image, no error, in every app | The DMFT is loaded and returns no frames |
| Device Manager says the camera is fine | It is fine. The break is above the driver |
| The Camera app briefly shows an error code, then black | The pipeline builds, then starves |
| Resetting the Camera app fixes it until reboot | The registration is rewritten at boot |
| Updating or rolling back the camera driver does nothing | Wrong layer |
| Camera works in the BIOS / on a Linux live USB | Confirms the hardware is fine |

Error codes people report alongside this: `0xA00F429F`, `0xA00F4241`,
`0xA00F4292`, `0xA00F4271`, `0x80004003`, plus `WindowShowFailed` and
`CameraSwitchFailed` in the Camera app diagnostics.

---

## Fixing it

Elevated PowerShell, on the affected machine:

```powershell
.\Fix-AcerCameraDMFT.ps1 -Apply
```

That will, in order:

1. stop and disable `AcerARTAIMMXDriverService`, the service that relaunches the
   detector;
2. export the affected registry subtrees to `%ProgramData%\CameraFix`;
3. run Acer's own `UninstallAcerCameraDMFT.exe` out of the driver store, which
   clears all three interface categories (use `-Manual` to delete the values
   directly instead, for machines where the binary is missing);
4. read the registry back to check;
5. restart the camera device so Media Foundation rebuilds the pipeline.

It worked immediately, without a reboot, on every machine I ran it on, and it
survived reboots afterwards. Disabling the one service was enough —
`-DisableAllServices` exists for the case where the registration comes back, and
I never needed it.

The webcam ends up on the plain Microsoft stack: `usbvideo.inf` plus the
platform DMFT. You lose whatever Acer's effects layer was doing (background
blur, auto framing, "Acer PurifiedView" style features). Given the alternative
is no picture at all, that has not bothered anyone here.

### When the camera is busy

The one machine where the first version of this script failed had a Meet call
running. `Disable-PnpDevice` will not touch a device that is in use, so the
device restart step failed and the operator had to go back to the desk.

`-Force` deals with that:

```powershell
.\Fix-AcerCameraDMFT.ps1 -Apply -Force
```

It escalates, stopping as soon as the camera comes free:

1. **Blocks camera access system wide** — the same switch as *Settings → Privacy
   & security → Camera → Camera access*, written to the machine hive and to
   every loaded user hive. Streams that are running get dropped, and nothing new
   can grab the device while the fix is in flight.
2. **Kills the capture helper process.** Chromium browsers keep the camera in a
   dedicated utility process, so Chrome, Edge and Electron apps lose the camera
   while your tabs stay open.
3. **Closes whatever is still streaming**, read from the consent store rather
   than guessed from a list of app names. There is a hard exclusion list so it
   will not go after `svchost`, `explorer` and friends.
4. **Stops the frame server.** `FrameServer` and `FrameServerMonitor` are
   trigger-start, so Windows brings them back on demand. If a service refuses to
   stop, the host process is killed — but only after checking that it hosts
   nothing except those two.
5. **Restarts the device**, trying `pnputil /restart-device` first, then
   disable/enable, and finally, only on USB devices, removing the device node
   and rescanning.

Camera access is restored in a `finally` block, and the previous value of every
key is written to `%ProgramData%\CameraFix\camera-access-state.json` *before*
anything is changed. If the run is interrupted anyway — power loss, closed
window — the next run notices the file and puts the setting back before doing
anything else. You can also force that with `-Rollback`.

Two things `-Force` deliberately does not do. It will not remove and rescan a
non-USB device: an internal MIPI camera hanging off the SoC may not come back
without a reboot, and a machine with no camera at all is worse than a fix that
waits until the next restart. And it does not kill processes that the consent
store does not name, so an exotic application talking to the device directly may
still hold it — in which case the script says so and a reboot finishes the job.

Anyone in a call when you run this gets dropped. That is the point of the flag.

### Rolling back

```powershell
.\Fix-AcerCameraDMFT.ps1 -Rollback -Apply
```

Services go back to Automatic and start; the detector writes the registration
back at the next boot and you are exactly where you started. Nothing is
uninstalled and no driver package is deleted, so there is nothing to reinstall.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Clean — no third-party DMFT registration left |
| 1 | Registration still there, look at the log |
| 2 | Not running elevated |
| 3 | Registration removed, device restart incomplete — reboot |

Useful if you are pushing this through an RMM. Logs, registry backups and the
access state file all live in `%ProgramData%\CameraFix`.

### Deploying to more than one machine

Nothing in the script is machine specific: it finds the driver store package by
its original INF name and the device by walking the registrations it found, so
the `oemNN.inf` numbers (which differ on every machine) never come into it.

```powershell
# Intune / PDQ / RMM, running as SYSTEM
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Fix-AcerCameraDMFT.ps1 -Apply -Force
```

Running as SYSTEM is handled: the consent store is per user, so the script walks
`HKEY_USERS` instead of trusting `HKCU`, which under SYSTEM would be empty.

---

## Diagnosing something else

`Camera-Diag.ps1` is read-only and dumps the whole camera pipeline to a text
file: devices and their driver packages, frame server state, everything
registered on the three KS interface categories, Media Foundation platform keys,
permissions, who is holding the camera right now, recent driver installs from
`setupapi.dev.log`, update history, PnP events.

```powershell
.\Camera-Diag.ps1
```

Run it on a broken machine and on a working one of the same model and diff the
two files. That comparison is what found this bug in the first place, and the
DMFT section is worth a look on any laptop with a vendor camera effects stack —
Dell, HP, Lenovo and Intel all ship one.

---

## What the fix is actually removing

```
usbvideo.inf (Microsoft)
    └── DevProxy
        └── Platform DMFT           (EnablePlatformDmft = 1, Microsoft)
            └── Acer DMFT           ← this one. Loads, then delivers nothing.
                └── your application → black frames
```

The chain is written to three device interface keys under
`HKLM\SYSTEM\CurrentControlSet\Control\DeviceClasses\`, one per KS category:

| GUID | Category |
|---|---|
| `{e5323777-f976-4f5b-9b55-b94699c46e44}` | KSCATEGORY_VIDEO_CAMERA |
| `{65E8773D-8F56-11D0-A3B9-00A0C9223196}` | KSCATEGORY_CAPTURE |
| `{6994AD05-93EF-11D0-A3CC-00A0C9223196}` | KSCATEGORY_VIDEO |

Cleaning only the first is a half fix: the other two are what DirectShow reads.
Turning off frame server mode does not help either — the registration is present
on the DirectShow categories too, and the COM object has no 32-bit registration,
so there is no configuration that routes around it.

The full write-up, with the evidence behind each step and a list of the things I
tried that turned out to be wrong, is in [docs/root-cause.md](docs/root-cause.md).

---

## Scope, and what I have not tested

Found and fixed on:

- **Acer Aspire A315-44P**, Ryzen 7 5700U, Windows 11 build 26200, BIOS Insyde V1.13
- Camera: ACER HD User Facing (Quanta), `USB\VID_0408&PID_4033`
- Driver: `usbvideo.inf` 10.0.26100.8972 — Microsoft inbox UVC, device state OK
- Component: `acerartaimmxdrivercomponent.inf` 2.0.3038.0, `AcerMediaService.dll` 2.0.3038.0
- CLSID: `{2EB17717-49CE-4B6C-85E7-58EE3AF41669}` — "Acer Media Service"
- Broke after `KB5121003`, `KB5123304`, `KB5120708`; a second machine broke in
  July after `KB5120102`, `KB5101650`, `KB5100998`

That is one model family on one fleet. The Acer extension INF binds to subsystem
IDs across Predator, Nitro, Aspire, Swift, TravelMate and Extensa, so the
component is installed far more widely than that — but I have only seen it fail
here, and I am not going to claim otherwise. The script reads the CLSID off your
machine rather than assuming mine, so it should behave sensibly on models where
the numbers differ.

Not tested:

- The sibling package family `acergaicameracomponent.inf` / "Acer GAI Camera
  Service", which I found on a second machine and which looks like the same
  mechanism under a different name. The script detects its services and
  packages, but I have never had to run the fix against it.
- Windows 10. The code paths are 5.1 compatible and
  `pnputil /restart-device` is skipped when it is not available, but I have not
  run it there.
- Cameras that are not USB. The forceful remove-and-rescan step refuses to touch
  them on purpose.

Reports from other models are welcome — open an issue with the read-only output
of both scripts.

---

## If you are reporting this to Acer or Microsoft

The useful facts, in the order support usually asks for them: model
`A315-44P`; component `acerartaimmxdrivercomponent.inf` version `2.0.3038.0`;
`AcerMediaService.dll` `2.0.3038.0` in `System32`, signed by the Microsoft
Windows Hardware Compatibility Publisher; CLSID
`{2EB17717-49CE-4B6C-85E7-58EE3AF41669}` registered as a DMFT on the three
interface categories by `DetectCameraDMFT.exe`, itself launched by
`AAADSvc.exe` (`AcerARTAIMMXDriverService`) at every boot; and the detail that
convinces people fastest — **Acer's own `UninstallAcerCameraDMFT.exe`, shipped
inside the same driver package, resolves it.**

---

## License

MIT. See [LICENSE](LICENSE).

Provided as is. It disables a vendor service and edits device interface keys on
a machine you presumably care about, and everything it does is reversible, but
read the script before you run it on someone else's laptop.
