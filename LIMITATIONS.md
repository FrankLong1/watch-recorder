# Apple-imposed limitations

Things that cannot be worked around, and what this app does about them.

## 1. The user must assign the control themselves

No API can claim the Action button. The app can only publish a control; the
assignment is a manual step in Settings › Action Button. Apple deliberately
keeps that choice with the user.

**Consequence:** first-run instructions matter. See README.

## 2. Recording cannot start from the background

The microphone only opens for a foreground app. `WKBackgroundModes: audio` lets
a recording that *started* in the foreground continue when the wrist drops, but
it cannot be used to begin one. Apple's background sessions documentation:

> Your app must start the session in the foreground, but the session continues
> to run when your app transitions to the background.

**Consequence:** the whole architecture. The intent foregrounds the app rather
than recording headlessly. There is no way to record with the screen off from a
cold start.

## 3. `AudioRecordingIntent` requires a Live Activity

Adopting it obliges you to start a Live Activity and keep it alive:

> If you don't start a Live Activity, the audio recording stops.

A watchOS app cannot originate a Live Activity — on watchOS they mirror from
iPhone. Adopting the protocol on watch would guarantee the recording stops.

**Consequence:** this app uses a plain `AppIntent`, so it does not get the
system's audio-recording indicator treatment that the protocol provides.

## 4. Background recording is CPU-limited and revocable

Once backgrounded, the app runs under tighter CPU limits and the system may
suspend it under memory or thermal pressure. Extended runtime sessions do not
help: `WKExtendedRuntimeSession` has no audio-recording session type, and the
types that exist are invalidated when the app leaves the foreground.

**Consequence:** capture is PCM-in-CAF so a suspended-then-killed app leaves a
decodable file, and orphaned captures are recovered on the next launch. Long
unattended recordings are still not something watchOS guarantees.

## 5. Controls mirrored from iPhone cannot foreground the iPhone app

watchOS 26 surfaces iOS controls on the watch automatically, but per WWDC25:

> Since the action is performed on iPhone, controls whose actions foreground the
> iPhone app will not appear on Apple Watch.

**Consequence:** a watch-native control extension is required — an iOS-only
control could never launch anything for this use case. That is why
`WatchControls` is a watchOS target.

## 6. The Action button is Ultra-only

Series and SE models have no Action button.

**Consequence:** `StartRecordingIntent` is also exposed through
`AppShortcutsProvider`, so non-Ultra users get a Siri phrase and a Shortcuts
action. It is one hop slower, and that hop cannot be removed.

## 7. Control state is not live

A control's rendering is provided by the extension, which cannot observe the
app's audio session. There is no supported way to show "recording in progress"
on the Action button or in Control Center from a watch app.

**Consequence:** a button ("start a memo"), not a toggle.

## 8. Battery shutdown gives no warning

watchOS has no "about to power off" callback.

**Consequence:** the app polls battery level every ~5 seconds while recording
and auto-saves below 5%. A sudden shutdown above that threshold still relies on
crash recovery (limitation 4).

## 9. Sync needs a companion app and is best-effort

`WCSession.transferFile` requires a counterpart iOS app and delivers on the
system's schedule — it can be minutes, or longer if the phone is away.

**Consequence:** the memo is committed to watch storage before any transfer is
attempted. Sync state is shown per memo, and pending transfers are retried when
the session activates or the phone becomes reachable.

---

## Verified against

Everything above was checked against the **watchOS 26.5 SDK** shipped with
**Xcode 26.6** (`arm64_32-apple-watchos.swiftinterface`), not from memory:

| Symbol | Availability |
|---|---|
| `ControlWidget`, `ControlWidgetButton`, `StaticControlConfiguration` | iOS 18.0, **watchOS 26.0**, macOS 26.0 |
| `IntentModes` / `AppIntent.supportedModes` | **watchOS 26.0** |
| `AppIntent.openAppWhenRun` | deprecated in watchOS 26.0 — "Please provide `supportedModes` instead" |
| `AudioRecordingIntent` | watchOS 11.0 (rejected, see 3) |
| `AVAudioApplication.requestRecordPermission` | watchOS 10.0 |
| `AVAudioSession.requestRecordPermission` | deprecated watchOS 10.0 |
| `AVAudioSession.activate(options:completionHandler:)` | watchOS 5.0, watch-only |

Sources: [What's new in watchOS 26 (WWDC25)](https://developer.apple.com/videos/play/wwdc2025/334/),
[What's new in widgets (WWDC25)](https://developer.apple.com/videos/play/wwdc2025/278/),
[AudioRecordingIntent](https://developer.apple.com/documentation/AppIntents/AudioRecordingIntent),
[Enabling Background Sessions](https://developer.apple.com/documentation/watchkit/enabling-background-sessions).
