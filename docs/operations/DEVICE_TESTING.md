# Real-device deployment

There is one normal way to put WristMemo on the hardware:

```bash
./scripts/run.sh --doctor
./scripts/run.sh
```

The first command explains the current device state. The second builds the
iPhone app, embeds the Watch app, signs both, and installs the package on the
connected iPhone. The paired iPhone then owns the Watch hand-off.

Direct Mac → Watch installation is an optional faster development loop. It is
not required for the normal install and should not be the first thing to debug.

## Local readiness

Machine, account, device, and provisioning details are intentionally not
tracked. Keep a private snapshot in `DEVICE_TESTING.local.md`, which is
gitignored. Before a hardware run, verify:

| Item | Status |
|---|---|
| Xcode | A version supporting the deployment targets |
| iOS and watchOS platforms | Installed in Xcode |
| Apple Developer membership | Active and set in `Signing.local.xcconfig` |
| Provisioning profiles | Valid for the local bundle prefix |
| Connected phone | Trusted, unlocked, and in Developer Mode |
| Watch developer connection | Optional for the normal iPhone-first path |

The missing Watch developer connection only prevents `./scripts/run.sh --watch`.
It does not prevent the normal iPhone-first installation.

## Normal installation

1. Plug the iPhone into the Mac with USB.
2. Unlock it and tap **Trust** if asked.
3. Check the setup:

   ```bash
   ./scripts/run.sh --doctor
   ```

4. Deploy:

   ```bash
   ./scripts/run.sh
   ```

5. If WristMemo does not appear on the Watch automatically, open the iPhone
   **Watch app → Available Apps → WristMemo → Install**.
6. Launch WristMemo once on the Watch and allow microphone access.
7. On the Watch, open **Settings → Action Button → Action → Control**, tap the
   control preview, then select **WristMemo → Your Agents**.

The deploy command proves that the signed iPhone package was installed. When
the Watch is not visible to Xcode, it cannot honestly prove that iOS completed
the second hand-off. The final Watch check is therefore explicit instead of
being reported as a false success.

## What `--doctor` checks

`./scripts/run.sh --doctor` reports:

- the single connected physical iPhone;
- whether iPhone Developer Mode is enabled;
- the installed WristMemo version and build, if present;
- whether an Apple Watch is visible to Xcode; and
- whether the optional direct Watch connection is usable.

Stale paired devices are ignored for the normal path. If more than one iPhone
is genuinely connected, deployment stops instead of guessing which one to use.

## Optional direct Watch loop

Use this only after the normal installation works:

```bash
./scripts/run.sh --watch
```

To build, install, and launch directly into recording:

```bash
./scripts/run.sh --record
```

Direct installation requires all of the following:

- Watch **Settings → Privacy & Security → Developer Mode** is on;
- the Watch was restarted after enabling Developer Mode;
- the Watch is unlocked, awake, and near the iPhone and Mac;
- the Watch and Mac can reach each other over the local network; and
- the Watch appears in Xcode under **Window → Devices and Simulators**.

An Apple Watch has no wired data connection. Its magnetic charger supplies
power only, so the direct developer tunnel is inherently more fragile than the
USB iPhone path.

If Xcode reports a blank watchOS version or claims that `watchOS  doesn't match`
the 26.0 deployment target, the tunnel is down. Do not lower
`WATCHOS_DEPLOYMENT_TARGET`: WristMemo's Action Button Control requires watchOS
26.

Common direct-tunnel blockers are:

- the Watch is locked or Developer Mode has not completed its restart;
- the Mac and Watch are on different networks;
- guest or managed Wi-Fi blocks device-to-device traffic;
- Ethernet or a VPN owns the Mac's default route; or
- Xcode still contains a stale manually paired device record.

## Signing

The project uses automatic signing. These identifiers are derived from the
private `WRISTMEMO_BUNDLE_PREFIX` value:

| Target | Bundle identifier |
|---|---|
| iPhone companion | `$(WRISTMEMO_BUNDLE_PREFIX)` |
| Watch app | `$(WRISTMEMO_BUNDLE_PREFIX).watchkitapp` |
| Watch control extension | `$(WRISTMEMO_BUNDLE_PREFIX).watchkitapp.controls` |

All targets use the `DEVELOPMENT_TEAM` value from the same ignored local file.

If signing genuinely fails later, let `./scripts/run.sh` request fresh profiles
through Xcode. The full build output is retained at `build/phone-dd.log` or
`build/watch-dd.log` instead of disappearing after the command.

## Hardware acceptance checklist

The simulator already covers build, UI, recording, save, crash recovery, and
index persistence. Real hardware is still required to verify:

- [ ] The WristMemo control appears in Action Button settings.
- [ ] An Action Button press foregrounds WristMemo and starts recording.
- [ ] A second Action Button press does not stop a live recording.
- [ ] The start haptic fires only when the microphone is writing.
- [ ] Double Tap stops while recording and does nothing while ready.
- [ ] Wrist-down inactivity stops after the configured timeout.
- [ ] Exiting WristMemo stops and saves immediately.
- [ ] Recording continues correctly through wrist-down/background behavior.
- [ ] A phone call pauses and resumes cleanly.
- [ ] `WCSession.transferFile` delivers the memo to the iPhone.
- [ ] Press-to-first-sample latency feels acceptable on the Ultra.

For simulator work, use `./scripts/sim.sh`; it does not need any physical-device
pairing.
