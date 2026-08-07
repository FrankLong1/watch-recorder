# Testing on a real Apple Watch Ultra 2

> **Most changes do not need hardware.** `./sim.sh` runs the unit bundle, taps
> through the real UI with XCUITest, and asserts on the simulator's container
> and log — see the Testing section in [README.md](README.md). Reach for a
> device when you need the physical Action button, true press-to-record latency,
> or a real WatchConnectivity transfer to the phone; the simulator cannot
> produce any of those.

## What is already done on this Mac

| | |
|---|---|
| Xcode | 26.6 (17F113), command line tools selected, first-launch tasks complete |
| watchOS platform | **26.5 installed** (`xcodebuild -downloadPlatform watchOS`) — was missing, which is why no device or simulator destination existed |
| iOS platform | **26.5 installed** (`xcodebuild -downloadPlatform iOS`) |
| Simulators | Apple Watch Ultra 3 (49mm), Series 11, SE 3 + iPhone, all watchOS/iOS 26.5 |
| Signing identity | An `Apple Development` certificate for the team below, already in the login keychain |
| Project signing | `DEVELOPMENT_TEAM = 44X645LJ6H` set at project level, inherited by all three targets |
| Bundle IDs | `com.franklong.wristmemo{,.watchkitapp,.watchkitapp.controls}` |
| App Groups | Not used — the launch hand-off is in-process, so nothing needs a paid-only capability |

## Account tier, and why it decides everything

Signing works on a **free** personal team — that is not the constraint. What the
tier decides is *device registration*, which is what actually gates installs.

| | Free personal team | Paid program |
|---|---|---|
| Profile lifetime | **7 days**, then the app stops launching | 1 year |
| Registering a device | Xcode only, automatically, and **only when it can talk to the device** | paste the UDID into the portal by hand |
| App Groups | cannot provision | available |

Verify the tier in one command — the expiry date is the tell:

```bash
cd ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/
for p in *.mobileprovision; do
  security cms -D -i "$p" > /tmp/p.plist 2>/dev/null
  /usr/libexec/PlistBuddy -c "Print :ExpirationDate" -c "Print :Name" /tmp/p.plist
done
```

7 days out means free; a year means paid. Xcode → Settings → Apple Accounts
agrees: *Personal Team* vs *Individual*. To force a fresh answer from Apple,
move the `.mobileprovision` files aside and rebuild with
`-allowProvisioningUpdates` — that re-queries the portal live. Xcode 26 has no
refresh button in the accounts pane; signing out and back in is the only manual
equivalent, and it is rarely what you need.

**Status 2026-08-06:** paid membership is **active**. Team 44X645LJ6H is now
enrolled as *Individual*, agreements accepted, renewing 2027-08-06.

Activation landed at ~11:34, but the profiles on this Mac were minted at 11:16 —
*before* it — so they are still free-tier and still expire 2026-08-13. They do
not upgrade themselves. Move them aside and rebuild with
`-allowProvisioningUpdates` to re-mint at one year:

```bash
mkdir -p ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles.free-backup
mv ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.mobileprovision \
   ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles.free-backup/
```

Re-run the expiry check afterwards; a date a year out is the confirmation.

## What you have to do

Only the steps that need physical hardware or your Apple ID password.

### 1. Connect the iPhone first

Plug the iPhone into the Mac with USB and tap **Trust**.

Do this **before** looking for Developer Mode. The toggle does not exist in
Settings until the device has been seen by Xcode — going hunting for it first
just wastes time.

### 2. Developer Mode on both devices

- **iPhone** → Settings › Privacy & Security › Developer Mode → **On** → restart
  → unlock → confirm **Turn On**
- **Apple Watch** → Settings › Privacy & Security › Developer Mode → **On** → restart

Both are required; the watch will not accept an install without it.

Confirm from the Mac rather than trusting the UI:

```bash
xcrun devicectl list devices
xcrun devicectl device info details --device <identifier> | grep -i developerMode
```

### 3. Get the watch actually connected — the hard part

**An Apple Watch has no data port.** The magnetic charger is power-only, so
every byte between Xcode and the watch travels over Wi-Fi. There is no cable
fallback, which makes this the most fragile step by a wide margin.

The watch must be **unlocked, on its charger, and on the same Wi-Fi network as
the Mac**. Then check that Xcode ever actually prepared it:

```bash
ls ~/Library/Developer/Xcode/watchOS\ DeviceSupport/
```

An entry there is proof of a successful connection. **No such directory means
the watch has never connected**, no matter what Xcode's setup dialog claims —
its green "This device is set up" ticks reflect pairing, not preparation.

The failure looks like this:

```
Timed out while attempting to establish tunnel using negotiated network parameters.
        (com.apple.dt.RemotePairingError error 1001)
```

and it cascades into misleading downstream errors. Most confusing is this one,
where the watchOS version is **blank** because Xcode never read it:

```
error: Frank's Apple Watch's watchOS  doesn't match WristMemo Watch App.app's
       watchOS 26.0 deployment target.
```

That is not a deployment-target problem. Do not lower `WATCHOS_DEPLOYMENT_TARGET`
in response — Controls only exist on watchOS 26, so lowering it deletes the
feature. It means the tunnel is down.

Causes seen on this Mac, in order of likelihood:

- **A multi-homed Mac.** `route -n get default` must resolve to the Wi-Fi
  interface the watch is on. A USB Ethernet dongle on a different subnet
  (here `en8` → `10.0.46.1`, while Wi-Fi `en0` was on `192.168.76.x`) captures
  the default route and the tunnel negotiates against the wrong network.
  Unplug it.
- **AP client isolation.** Common on guest, office, and apartment networks — a
  `/23` or larger subnet is a hint you are on managed infrastructure. It blocks
  device-to-device traffic outright and cannot be worked around from the Mac.
- **A VPN acting as an exit node**, which also captures the default route.
  Plain Tailscale routing only `100.64.0.0/10` is harmless; check
  `tailscale status --json` for `BackendState` before blaming it. Stale `utun`
  routes from a stopped VPN are cosmetic.

### 4. Check the watch is on watchOS 26.x

Watch → Settings › General › About › Version. The project targets watchOS 26.0,
so anything 26.x works. On 11.x or earlier it will not install.

Note that Xcode cannot tell you this until step 3 succeeds — the blank version
in the error above is exactly that gap.

### 5. Confirm both devices are in the profiles

This is the step whose absence is hardest to diagnose, because the error surfaces
on the *iPhone* as a vague **"the app could not be installed at this time."**

That message does not mean the transfer failed. Delivery is device-to-device and
works fine — the watch app ships inside the iPhone app at
`WristMemo.app/Watch/WristMemo Watch App.app`, and the phone hands it over. What
fails is the **signature check**: the embedded profile lists which devices may
run the app, and if the watch's UDID is missing, the watch refuses it.

```bash
cd ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/
for p in *.mobileprovision; do
  security cms -D -i "$p" > /tmp/p.plist 2>/dev/null
  /usr/libexec/PlistBuddy -c "Print :Name" -c "Print :ProvisionedDevices" /tmp/p.plist
done
```

The iOS host profile must include the iPhone, while the watch app and controls
profiles must include the paired watch. Keep those identifiers out of the
repository; obtain them locally from `xcrun devicectl list devices`.

| Device | UDID |
|---|---|
| iPhone | `<iPhone hardware UDID>` |
| Apple Watch | `<Watch hardware UDID>` |

If the watch is missing, register it by hand at
[Devices](https://developer.apple.com/account/resources/devices/list) → **+** →
platform **watchOS** → paste the UDID from `xcrun devicectl list devices`.

**This is the escape hatch, and on a paid team it is the primary path.** Portal
registration needs no Mac-to-watch connection at all, so it sidesteps step 3 —
the tunnel, the Wi-Fi subnet, the VPN, all of it. Combined with installing via
the iPhone over USB (step 6, path 1), the whole loop runs without the Mac ever
talking to the watch directly.

Then move the profiles aside and rebuild so they regenerate with both devices.

### 6. Run it

```
open /Users/frank/Projects/watch-recorder/WristMemo.xcodeproj
```

1. Scheme **WristMemo** → destination *your iPhone* → **Run**.
   This installs the companion and pushes the watch app across.
2. Scheme **WristMemo Watch App** → destination *your Apple Watch* → **Run**
   for subsequent watch-only iterations (much faster). Needs step 3 working.

Or from the command line, which is faster to iterate and gives better errors:

```bash
xcodebuild -project WristMemo.xcodeproj -scheme "WristMemo" \
  -destination "id=<iPhone hardware UDID>" \
  -derivedDataPath /tmp/wm -allowProvisioningUpdates build

xcrun devicectl device install app --device <iPhone device identifier> \
  /tmp/wm/Build/Products/Debug-iphoneos/WristMemo.app
```

`xcrun devicectl list devices` shows both values. `xcodebuild` needs the
hardware UDID; `devicectl` needs the device identifier shown in its first
column.

If the watch app does not appear on the watch by itself, push it from the phone:
**Watch app → Available Apps → WristMemo → Install**.

On the watch, the first launch shows the microphone prompt. Allow it.

### 7. Assign the Action button

Watch → **Settings › Action Button** → **Action** → **Control** → tap the
preview → **WristMemo › Record Voice Memo**.

Then press it.

## What is already verified, and what is not

Verified by actually running on the Apple Watch Ultra 3 simulator:

- **Full cycle end to end**: launch → auto-record → stop → compress → save,
  producing a 5.27 s AAC memo, index written, capture directory cleaned

- App launches and renders on a 49mm Ultra screen
- **Launch-straight-into-recording** — the same `startRequested` path the Action
  button drives, triggered by a DEBUG launch flag (below)
- The full-screen button: grey READY → tap → red RECORDING → tap → grey again,
  with no confirmation in between, and a second recording startable at once
- **Crash recovery**: hard-killed mid-recording, the 2 MB PCM capture survived,
  and the next launch turned it into a valid 216 KB AAC file — `afinfo` reports
  1 ch, 22050 Hz, 45.5 s, 32 kbit/s. Compression ratio 9.3×.
- Index persistence across launches

Still needs the real Ultra 2, because a simulator cannot answer these:

- [ ] The control actually appears in Settings › Action Button
- [ ] A press foregrounds the app — **the one assumption the design rests on**
- [ ] **A second Action press stops the recording.** The button is now a toggle,
      which assumes the intent still fires and reaches an app that is already
      frontmost and recording. Only hardware can show that; if it turns out the
      press is swallowed, the screen tap and silence auto-stop still end it.
- [ ] How instant the press-to-first-sample delay feels
- [ ] Recording continues on wrist-down (`WKBackgroundModes: audio`)
- [ ] A phone call pauses and resumes cleanly
- [ ] **The two start haptics are distinguishable** — the light one on press and
      the "speak" one when the microphone opens. If they blur into each other on
      the wrist, the second is the one that matters.
- [ ] Red is bearable at night, and the grey reads as off rather than as an
      unlit screen, in sunlight and in always-on
- [ ] Double Tap toggles the full-screen button in both directions
- [ ] `WCSession.transferFile` delivers to the iPhone

## Simulator iteration

The simulator has no Action button, so a DEBUG-only launch flag drives the same
code path:

```bash
SIM=DA9BA2FF-A82F-4B2F-94FC-50A2D14DD1ED   # Apple Watch Ultra 3 (49mm)
xcrun simctl boot $SIM
xcodebuild -project WristMemo.xcodeproj -scheme "WristMemo Watch App" \
  -destination "platform=watchOS Simulator,id=$SIM" -derivedDataPath /tmp/wmdd build
xcrun simctl install $SIM "/tmp/wmdd/Build/Products/Debug-watchsimulator/WristMemo Watch App.app"
xcrun simctl privacy $SIM grant microphone com.franklong.wristmemo.watchkitapp

# launch straight into recording, exactly as the Action button would
xcrun simctl launch $SIM com.franklong.wristmemo.watchkitapp -WristMemoAutoRecord YES

# or the whole pipeline unattended: record, then stop and save after 5s
xcrun simctl launch $SIM com.franklong.wristmemo.watchkitapp \
  -WristMemoAutoRecord YES -WristMemoAutoStopAfter 5
xcrun simctl io $SIM screenshot /tmp/shot.png
```

Note: the watch simulator routes audio through the **Mac's** microphone, so
macOS will ask to let Simulator use it. Until that is answered the simulator
stalls on a spinner.

Logs:

```bash
xcrun simctl spawn $SIM log stream --predicate 'subsystem == "com.franklong.wristmemo"'
```

## Gotchas

- **The 7-day expiry is now fixed, but not retroactively.** Team 44X645LJ6H was
  a free personal team; profiles minted 2026-08-06 at 11:16 expire 2026-08-13.
  Paid membership activated the same morning and raises this to a year, but only
  for profiles minted *after* activation — the existing ones must be deleted and
  re-minted. See the tier table above.
- **The Action button is Ultra-only.** On a Series 9 or any non-Ultra watch,
  Settings › Action Button does not exist. This does not block testing the
  design: `StartRecordingControl`, `RecordComplication`, and `WristMemoShortcuts`
  all fire the *same* `StartRecordingIntent` with
  `supportedModes = .foreground(.immediate)`. Adding the **Record Memo**
  complication to the watch face and tapping it exercises the identical code
  path, so the one assumption the design rests on — that the intent foregrounds
  the app and starts recording — is answerable on any watchOS 26 watch. Only
  press-to-first-sample feel and the button assignment itself need an Ultra.
- **Launch the app once** before the control shows up in the Action button list.
- **Sync needs the companion installed** on the iPhone; `transferFile` has
  nowhere to deliver otherwise.
