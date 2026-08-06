# Simulator and test automation plan

## Goal

Add repeatable watchOS simulator coverage without putting new work on the
Action-button launch path. The result has three complementary layers:

1. `sim.sh`: a shell smoke harness that builds, installs, drives the existing
   DEBUG launch switches, and inspects the real simulator container and logs.
2. `WristMemoTests`: a watchOS Swift Testing bundle for deterministic logic.
3. `WristMemoUITests`: an XCTest UI bundle that taps the actual watch UI. This
   is deliberately separate from the launch-flag harness: it proves that the
   visible controls work, rather than merely proving that a process can be
   launched with arguments.

The simulator cannot test the physical Action button or its real
press-to-record latency. `-WristMemoAutoRecord YES` is the supported simulator
substitute for the same in-process request path.

## What is already in place

- `Shared/RecordingLaunchRequest.swift` consumes `WristMemoAutoRecord` in
  DEBUG builds.
- `WatchApp/RecorderModel.swift` consumes `WristMemoAutoStopAfter` and already
  saves after that duration.
- `WatchApp/MemoStore.swift` uses a stable data layout under the application
  data container: `Library/Application Support/WristMemo/{Captures,Memos}` and
  `memos.json`.
- `WatchApp/Latency.swift` writes an OS-log notice in the stable
  `com.franklong.wristmemo` subsystem; the important marker is
  `[latency] first sample at <N>ms`.
- The existing `DEVICE_TESTING.md` has manually verified the exact simulator
  install, microphone permission, launch, and log commands that the harness
  should formalize.
- The project currently has no test targets and the watch scheme has an empty
  `<Testables>` list.
- Xcode 26.6 is installed with WatchSimulator 26.5. Its WatchSimulator platform
  contains `Testing.framework`, `XCTest.framework`, and
  `XCUIAutomation.framework`.
- The installed `XCUIApplication.h` exposes `launch`, `terminate`,
  `waitForState`, and `tap` for watchOS (`tap` is unavailable only on tvOS).
  The existing UI also exposes useful labels such as `Record`,
  `Stop and save recording`, `Discard recording`, `Saved`, and `Done`.

One local limitation is not a project issue: CoreSimulatorService is unavailable
in this execution environment, so live simulator commands could not run here.
The implementation must validate them on a Mac session where Simulator has
started and macOS has granted Simulator microphone access.

## 1. `sim.sh`: end-to-end simulator smoke harness

### Command contract

Mirror `run.sh`'s Bash style:

- `#!/bin/bash`, `set -euo pipefail`, `cd "$(dirname "$0")"`, and the existing
  `bold`, `warn`, and `die` helpers.
- Defaults: the first available booted watch simulator, 5-second recording,
  30-second state timeout, and a configurable (intentionally simulator-relaxed)
  first-sample budget, initially 20,000 ms.
- Flags: `--simulator <UDID-or-name>`, `--record-seconds <seconds>`,
  `--timeout <seconds>`, `--max-first-sample-ms <ms>`, `--scenario <name>`,
  `--no-build`, `--keep`, `--devices`, and `--help`. `--scenario all` is the
  default; accepted individual values are `record-save`, `prearm`, `recovery`,
  and `latency`.
- Give clear failures before doing work: no installed Xcode/watchOS runtime, no
  usable watch simulator, ambiguous simulator name, boot failure, missing built
  `.app`, failed microphone grant, or a Simulator process blocked on the macOS
  microphone privacy prompt.

The first implementation should select a booted Apple Watch when possible;
otherwise select the first available watchOS device, boot it, and wait with
`xcrun simctl bootstatus "$SIM" -b`. Do not assume the stale UDID in
`DEVICE_TESTING.md` still exists. Parse `simctl list devices --json` with the
same small Python approach used by `run.sh`, rather than brittle table parsing.

### Lifecycle and evidence collection

1. Build once using the existing watch scheme and
   `-destination "platform=watchOS Simulator,id=$SIM"`, keeping derived data
   under ignored `build/simdd`.
2. Resolve `WristMemo Watch App.app`, install it with `simctl install`, and run
   `simctl privacy "$SIM" grant microphone com.franklong.wristmemo.watchkitapp`.
   Make microphone permission a documented prerequisite because the watch
   simulator records through the Mac microphone.
3. Resolve the data container after install with
   `xcrun simctl get_app_container "$SIM" "$BUNDLE_ID" data`; from it derive
   `Library/Application Support/WristMemo`. Never hard-code a CoreSimulator
   device-data path.
4. Before every scenario, reset just the app by uninstalling/reinstalling it
   (then grant microphone permission again) and start a filtered log capture:

   ```bash
   xcrun simctl spawn "$SIM" log stream --style compact \
     --predicate 'subsystem == "com.franklong.wristmemo"'
   ```

   Capture it in a scenario-specific temporary file and clean it with a trap.
   Start a second filtered error-level stream, or use structured log output if
   it proves stable on Xcode 26.6, so the clean-log assertion checks actual log
   severity rather than matching the word "error" in a user message.
5. Launch via `simctl launch` with the requested DEBUG flags. Poll the data
   container and log file until the expected state or a deadline. A short sleep
   inside a reusable polling loop is fine; fixed "sleep five seconds and hope"
   calls are not.
6. On every pass or failure, print a compact scenario summary and preserve
   evidence when `--keep` is supplied (logs, parsed index JSON, and an optional
   screenshot). Always terminate background log-stream processes in the trap.

Use small Python helpers for file/JSON assertions, as macOS does not guarantee
`jq` is installed. They should report the discovered files, IDs, dates, sizes,
and durations on failure.

### Scenario assertions

| Scenario | Drive | Poll for and assert |
|---|---|---|
| `record-save` | Launch with `-WristMemoAutoRecord YES -WristMemoAutoStopAfter <seconds>`. | Exactly one new index entry and final memo file; duration is within a documented tolerance (for example ±1.5 s, configurable if simulator load warrants it); `createdAt` values in `memos.json` descend newest-first; the recorded capture was removed. |
| `prearm` | Launch idle, with neither recording flag. | Exactly one `.caf` in `Captures`, with the expected header-only 4,096-byte size. This scenario intentionally does not call it a drained directory: that file is the next pre-armed recorder. |
| `recovery` | First save a normal current memo. Then launch an unbounded auto-record, poll until its capture has crossed a safe byte threshold, hard-terminate with `simctl terminate`, and backdate that real CAF before a subsequent idle launch. | Startup recovers the orphan to `Memos`; the old capture disappears, except for the one newly pre-armed header; the index contains the two distinct UUIDs exactly once; and the backdated recovered memo sorts after the current memo, proving recovery uses its own date instead of inserting at position zero. |
| `latency` | Launch auto-record with a long enough auto-stop to leave the recording alive while logs arrive. | Poll the log capture for the first-sample marker, parse `N`, and fail if `N > --max-first-sample-ms`. This is process-exec-to-first-sample instrumentation, not physical button latency. |
| clean log (all relevant scenarios) | Inspect each scenario's filtered severity capture after it reaches its success condition. | No `error` or `fault` entries from WristMemo. Do not reject benign text that happens to contain the word “error.” |

Crash recovery needs a *valid* CAF, not a fabricated byte file. The harness gets
one by recording first, then killing the process only after the capture grows
beyond the minimum-duration byte threshold. `MemoStore` deliberately reads the
file creation date, so backdating must change creation time, not just mtime.
Use the Xcode `SetFile -d` utility when available, then verify the resulting
birth/creation date before relaunching. If the simulator volume does not honor
creation-date mutation, fail explicitly and add a narrowly scoped DEBUG fixture
hook only after confirming that limitation; do not silently downgrade this test
to an mtime test.

### Preconditions worth testing first

Implement a tiny prototype path before writing all assertions:

1. boot a selected watch simulator and run `bootstatus -b`;
2. build/install/grant microphone permission;
3. launch `AutoRecord` plus `AutoStopAfter 1`;
4. prove `get_app_container` reaches the expected storage root;
5. prove the filtered stream includes the first-sample marker; and
6. prove a real orphan CAF's creation date can be changed and observed by
   `FileManager` on this Xcode/runtime combination.

This resolves the only platform-sensitive assumptions early. The manual
workflow in `DEVICE_TESTING.md` makes the first five expected, while item six
is the risk that determines whether the recovery-ordering test needs a small
DEBUG-only fixture seam.

## 2. `WristMemoTests`: Swift Testing for deterministic behavior

Create `WristMemoTests/` and a `WristMemoTests` watchOS unit-test bundle.
Use `import Testing`, `@Suite`, and `@Test`; do not create XCTest assertion
wrappers for these cases.

Because this project has no reusable core module, compile the relevant existing
production sources into the test bundle as well as the watch app target:

- `Shared/Formatting.swift`
- `Shared/RecordingLaunchRequest.swift`
- `Shared/SharedConfig.swift`
- `Shared/AudioDuration.swift`
- `WatchApp/Memo.swift`
- `WatchApp/MemoStore.swift`
- `WatchApp/AudioCompressor.swift`

Keep those source memberships explicit in `project.pbxproj`; do not fork the
files into copies under the tests directory. Decouple MemoStore's
minimum-capture-byte calculation from `RecordingEngine` into an internal
storage/capture-format constant so this pure test bundle does not need to link
the audio-session engine or WatchKit.

Add a production-safe, internal testability seam to `MemoStore`, such as
`init(rootURL:fileManager:)`, while keeping the no-argument initializer as the
only app call site. Tests can then use a unique temporary root per test and
delete only that root in teardown. This avoids touching a real simulator app
container and makes the intended filesystem layout visible in the tests.

Coverage:

- `TimeInterval.memoClock`: minute padding and rounding boundaries.
- `TimeInterval.recordingClock`: tenths, minutes, and negative-duration clamp.
- `MemoStore.loadIfNeeded`: a pre-seeded, deliberately unsorted `memos.json`
  becomes descending `createdAt` order.
- `MemoStore.finalize`: a 4,096-byte header-only capture is rejected and
  removed before compression, demonstrating the minimum-duration guard.
- `RecordingLaunchRequest`: `post()` is consumed exactly once and then clears.
  Keep this suite serialized and clear the DEBUG UserDefaults key before and
  after it because the latch is process-global.

The tests should test sort order by seeding encoded `Memo` values, not by
depending on the AAC encoder. The rejection test deliberately uses a small
placeholder CAF because `finalize` rejects it before AVFoundation tries to
parse it.

## 3. Actual UI interaction: `WristMemoUITests`

Add a second watchOS UI-test bundle rather than trying to make Swift Testing
drive `XCUIApplication`. XCTest remains the straightforward owner of
`XCUIApplication`, element waits, screenshots, and failure attachments.

Configure it with the watch app as its target application, a test-host/target
dependency, `SDKROOT = watchos`, `WATCHOS_DEPLOYMENT_TARGET = 26.0`, and the
same `SWIFT_VERSION = 5.0`. Its primary test should:

1. receive microphone permission from the harness/setup environment;
2. launch the app with no recording launch flags;
3. wait for and tap the `Record` button;
4. wait for `RECORDING` and tap `Stop and save recording`;
5. wait for `Saved`, tap `Done`, and verify the memo is visible on Home.

Use `waitForExistence(timeout:)` between every transition. Avoid hand-timed
delays and avoid screen coordinates. Before adding the target, add stable
SwiftUI accessibility identifiers to the record button, recording state,
stop/discard buttons, saved state, and Done button. Labels work today, but IDs
avoid locale, typography, and SF Symbol changes breaking the UI test.

The UI test should not assert audio duration or inspect files. Those assertions
belong to `sim.sh`; keeping ownership separate makes failures diagnoseable:
the UI bundle answers “could a user tap through this?”, while the harness
answers “did recording produce the correct durable artifacts?”.

## 4. Hand-editing the project and scheme safely

The project is hand-maintained, so make project edits in small reviewable
blocks. For each test target add only the necessary PBX objects:

- file references and source build files;
- a product reference and Products-group entry;
- sources/framework phases;
- a `PBXNativeTarget` of the correct unit-test or UI-test product type;
- Debug and Release build configurations plus configuration list;
- target dependencies and container proxies for the watch app where required;
- `TargetAttributes` entries; and
- `TestableReference` entries in `WristMemo Watch App.xcscheme`.

Do not mix generator output, UUID reformatting, or unrelated target edits into
the same change. Verify after each mechanical edit with:

```bash
xcodebuild -project WristMemo.xcodeproj -list
xcodebuild -project WristMemo.xcodeproj -scheme "WristMemo Watch App" \
  -destination "platform=watchOS Simulator,id=$SIM" test
```

Also run `./sim.sh --scenario all` with a live simulator. The final CI/local
acceptance check is green unit tests, green UI taps, green harness scenarios,
and no new timing-sensitive work in `RecorderModel.init`,
`RecordingEngine.beginActivation`, or the first-sample path.

## Suggested implementation order

1. Prototype and document the six simulator preconditions above.
2. Add `sim.sh` lifecycle helpers and make `record-save` green.
3. Add `prearm`, then the validity-safe recovery/ordering scenario, then log
   severity and latency parsing.
4. Add the small MemoStore testability seam and `WristMemoTests` target.
5. Add accessibility identifiers and the `WristMemoUITests` target.
6. Wire both test bundles into the shared scheme, run the verification commands,
   and update `DEVICE_TESTING.md` to point to `sim.sh` as the repeatable path.

This order gets durable end-to-end evidence first, isolates the simulator's
filesystem/date behavior before the complex recovery assertion, and keeps
actual UI automation independent of hidden test flags.
