# WristMemo

Press the Apple Watch Ultra Action button, start talking. No taps.

A native watchOS 26 voice memo app built around a WidgetKit **Control**, which is
the only supported way for third-party code to own the Action button.

## Status

Draft, and **running**. Verified on the Apple Watch Ultra 3 simulator
(watchOS 26.5): launches straight into recording, and crash recovery
reconstructs a valid AAC memo from a hard-killed session.

Not yet on real hardware — the Action button itself has no simulator
equivalent, so press-to-record latency and control assignment still need an
Ultra. Setup and the remaining checklist: [DEVICE_TESTING.md](docs/operations/DEVICE_TESTING.md).

## The interface

One button, the size of the screen. **Grey READY starts; red RECORDING stops.**
The Action Button is launch-or-start: it starts from idle and does nothing while
a memo is starting, recording, or paused. While recording, a screen tap, Double
Tap, lowering the wrist for 8 seconds, or exiting WristMemo stops and saves.
There is no timer, meter, cancel, confirmation, list or settings screen. Red
means audio is genuinely reaching the disk, never merely that a press was
received.

## What happens on a press

1. Action button → the assigned control fires `StartRecordingIntent`.
2. The intent's `supportedModes = .foreground(.immediate)` brings the watch app
   forward at once.
3. The screen stays grey until the recorder is actually writing; then it turns
   red and emits the one **START** haptic. That means “speak now.”
4. Double Tap, a screen tap, an 8-second wrist-down timeout, or exiting the app
   stops it. At that same STOP haptic, the screen briefly turns green with
   **MESSAGE RECEIVED / Launching background agent…**; it is a local-capture
   receipt, not a claim that a network hop has completed. The recorder is
   already idle beneath it, so a new press starts immediately. Compression,
   phone transfer, transcription and downstream work all remain behind it.
5. Each device deletes its copy of the audio 24 h after the next hop has taken
   it, and never before. See [Design](docs/product/DESIGN.md#Memos-delete-themselves).

Product boundary: [Capture appliance](docs/product/CAPTURE_APPLIANCE.md). Design
rationale: [Design](docs/product/DESIGN.md). The full friction budget — from
press-to-recording through later review — is [Latency](docs/operations/LATENCY.md).
What Apple does not allow: [Limitations](docs/operations/LIMITATIONS.md). Source
and camera context brainstorming: [Source context](docs/product/SOURCE_CONTEXT.md).
For company-issued Watch/iPhone deployments, the proposed zero-trust device,
MDM, and service model is [Secure enterprise deployment](docs/operations/SECURE_ENTERPRISE_DEPLOYMENT.md). The IT-facing
[Jamf Pro implementation brief](docs/operations/JAMF_PRO_IMPLEMENTATION_BRIEF.md) provides the
concrete deployment scope, runbook, and acceptance tests.

## Assigning it to the Action button

On the watch, after installing the app once:

1. **Settings › Action Button**
2. Tap **Action**, choose **Control**
3. Tap the control preview, then pick **WristMemo → Your Agents**
4. Optionally set **Press Duration** to *Short Press*

Or from the iPhone: **Watch app › Action Button**, same choices.

The app must have been launched at least once so the control is registered, and
the microphone permission prompt has to be answered once before a press can
record without interaction.

It also appears in **Control Center** (side button) and can be added to the
**Smart Stack**. On non-Ultra watches, use the Siri phrase "Control your agents
in WristMemo" or add the Shortcuts action.

## Building

```bash
open src/swift_app/WristMemo.xcodeproj
```

Unsigned simulator builds work with the public defaults. For a signed device
build, copy `src/swift_app/Config/Signing.local.xcconfig.example` to
`Signing.local.xcconfig` and set your Apple team and bundle prefix there. The
local file is gitignored.

Command line, without signing:

```bash
xcodebuild -project src/swift_app/WristMemo.xcodeproj -target "WristMemo Watch App" \
  -sdk watchsimulator26.5 -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

### Targets

| Target | Platform | Role |
|---|---|---|
| `WristMemo` | iOS 26 | Companion — receives memos, shows searchable transcript history, and plays recent source audio |
| `WristMemo Watch App` | watchOS 26 | Recording app |
| `WristMemoControls` | watchOS 26 | Control extension (the Action button entry point) |
| `WristMemoTests` | watchOS 26 | Swift Testing — storage, retention, formatting, launch latch |
| `WristMemoUITests` | watchOS 26 | XCUITest — taps the real watch UI |

### Signing

The tracked project uses the neutral `com.example.wristmemo` prefix and no
development team. `Config/Signing.local.xcconfig` supplies machine-specific
values without changing the public project file.

## Testing

`./scripts/sim.sh` is the repeatable path: it boots a watch simulator, builds, runs both
test bundles, then drives the app and asserts on the real container and log.

```bash
./scripts/sim.sh                 # unit tests, UI taps, and every harness scenario
./scripts/sim.sh --unit          # logic bundle only (~2s inner loop)
./scripts/sim.sh --ui            # XCUITest taps only
./scripts/sim.sh --watch         # re-run on save
./scripts/sim.sh --repeat 20     # run N times; surfaces launch-path races
./scripts/sim.sh --help          # every flag
./scripts/check-public.sh        # reject secrets and machine-specific values
```

Scenarios cover a record→save round trip, the pre-armed capture, crash recovery
with its index ordering, and the first-sample latency marker. Simulator latency
is not device latency — see [the friction budget](docs/operations/LATENCY.md).

## Verifying on hardware

The normal path is deliberately just two commands:

```bash
./scripts/run.sh --doctor
./scripts/run.sh
```

The first reports the real device state; the second builds and installs through
the one connected iPhone. See [DEVICE_TESTING.md](docs/operations/DEVICE_TESTING.md)
for the one-time Watch steps and hardware checklist. `scripts/run.sh --watch`
is only the optional faster path when the direct Watch tunnel is healthy.
`scripts/sim.sh` is the simulator counterpart.

## Layout

```
src/swift_app/   the Xcode project and all Apple-target source
src/server/      Cloud Run ingest service, migrations, and Terraform
scripts/         simulator, device, deployment, and icon tooling
docs/            product, architecture, operations, research, and reviews
```
