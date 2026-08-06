# Testing on a real Apple Watch Ultra 2

## What is already done on this Mac

| | |
|---|---|
| Xcode | 26.6 (17F113), command line tools selected, first-launch tasks complete |
| watchOS platform | **26.5 installed** (`xcodebuild -downloadPlatform watchOS`) — was missing, which is why no device or simulator destination existed |
| iOS platform | **26.5 installed** (`xcodebuild -downloadPlatform iOS`) |
| Simulators | Apple Watch Ultra 3 (49mm), Series 11, SE 3 + iPhone, all watchOS/iOS 26.5 |
| Signing identity | `Apple Development: fylong00@gmail.com`, **Team 44X645LJ6H**, already in the login keychain |
| Project signing | `DEVELOPMENT_TEAM = 44X645LJ6H` set at project level, inherited by all three targets |
| Bundle IDs | `com.franklong.wristmemo{,.watchkitapp,.watchkitapp.controls}` |
| App Groups | **Disabled by default** — a free/personal team cannot provision them, and the app only uses the group as a fallback |

Apple-account connectivity is confirmed working: a signed device build reached
Apple's portal and returned *"Your team has no devices from which to generate a
provisioning profile."* That is the expected answer when no hardware has been
registered yet, and it resolves itself the first time you plug the phone in.

## What you have to do

Only the steps that need physical hardware or your Apple ID password.

### 1. Developer Mode on both devices

- **iPhone** → Settings › Privacy & Security › Developer Mode → **On** → restart
- **Apple Watch** → Settings › Privacy & Security › Developer Mode → **On** → restart

Both are required; the watch will not accept an install without it.

### 2. Connect

Plug the iPhone into the Mac with USB and tap **Trust**. The watch is reached
*through* the phone the first time — you do not connect it directly.

In Xcode: **Window › Devices and Simulators**. The iPhone appears, and the
paired watch appears nested underneath it. Wait until it stops saying
"Preparing debugger support" — first time this takes a few minutes.

### 3. Check the watch is on watchOS 26.x

Watch app on iPhone → General › About. The project targets watchOS 26.0, so
anything 26.x works. On 11.x or earlier it will not install.

### 4. Run it

```
open /Users/frank/Projects/watch-recorder/WristMemo.xcodeproj
```

1. Scheme **WristMemo** → destination *your iPhone* → **Run**.
   This installs the companion and pushes the watch app across.
   Xcode will register both devices and generate provisioning profiles — you may
   be asked for your Apple ID password once.
2. Scheme **WristMemo Watch App** → destination *your Apple Watch* → **Run**
   for subsequent watch-only iterations (much faster).

On the watch, the first launch shows the microphone prompt. Allow it.

### 5. Assign the Action button

Watch → **Settings › Action Button** → **Action** → **Control** → tap the
preview → **WristMemo › Record Voice Memo**.

Then press it.

## What is already verified, and what is not

Verified by actually running on the Apple Watch Ultra 3 simulator:

- **Full cycle end to end**: launch → auto-record → stop → compress → save,
  producing a 5.27 s AAC memo, index written, capture directory cleaned

- App launches and renders on a 49mm Ultra screen
- First-run microphone permission screen
- **Launch-straight-into-recording** — the same `startRequested` path the Action
  button drives, triggered by a DEBUG launch flag (below)
- Live timer, level meter, and the Cancel / Pause / Stop controls
- **Crash recovery**: hard-killed mid-recording, the 2 MB PCM capture survived,
  and the next launch turned it into a valid 216 KB AAC file — `afinfo` reports
  1 ch, 22050 Hz, 45.5 s, 32 kbit/s. Compression ratio 9.3×.
- Index persistence and the "1 recovered memo" list state

Still needs the real Ultra 2, because a simulator cannot answer these:

- [ ] The control actually appears in Settings › Action Button
- [ ] A press foregrounds the app — **the one assumption the design rests on**
- [ ] How instant the press-to-first-sample delay feels
- [ ] Recording continues on wrist-down (`WKBackgroundModes: audio`)
- [ ] A phone call pauses and resumes cleanly
- [ ] Haptics feel right at start/stop
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

- **7-day expiry.** If Team 44X645LJ6H is a free personal team, the app stops
  launching after 7 days and needs a re-run from Xcode. A paid membership
  raises this to a year.
- **App Groups need a paid account.** They are off by default. With a paid
  membership, re-add `CODE_SIGN_ENTITLEMENTS = Config/Watch{App,Controls}.entitlements`
  to the two watch targets to enable the cross-process hand-off fallback.
- **Launch the app once** before the control shows up in the Action button list.
- **Sync needs the companion installed** on the iPhone; `transferFile` has
  nowhere to deliver otherwise.
