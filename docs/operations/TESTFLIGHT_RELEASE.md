# TestFlight release runbook

This is the repeatable release path for WristMemo. The goal is one command for
the routine work, with App Store Connect or Xcode clicks reserved for account
repair, new agreements, or other Apple-required interaction.

## Why release 1.5 took longer

The build itself was not the slow part. Most of the delay came from recovering
an incomplete release path:

- The repository did not have one release command covering versioning, tests,
  archive, upload, TestFlight configuration, and verification.
- Xcode's command-line App Store Connect credential was broken (`missing
  Xcode-Username`), even though uploading through Xcode Organizer still worked.
- The upload then had to pass through Apple's processing queue. This part is
  external and cannot be made instantaneous.
- A processed upload is not automatically available to testers. The build must
  also be added to the **Internal** TestFlight group. Builds 1.3 and 1.4 had
  uploaded successfully but were not assigned to that group, which is why the
  TestFlight app still showed 1.2.
- Release notes, group assignment, and the final `Testing` status were verified
  manually in App Store Connect.

The important lesson is: **uploaded is not released**. A release is complete
only when the intended beta group shows the exact version and build as
`Testing`.

## What can be automated

| Release operation | Automatable? | Notes |
| --- | --- | --- |
| Check the Git worktree | Yes | Stop rather than shipping unreviewed changes. |
| Bump marketing version and build | Yes | The values still need to be chosen intentionally and must never be reused. |
| Create the release-notes file | Mostly | A script can create and validate it; a human should approve the wording. |
| Run tests | Yes | Fail the release immediately if a required test fails. |
| Create the signed archive | Yes | Use `xcodebuild archive`. |
| Upload the archive | Yes | Use an App Store Connect API key with `xcodebuild -exportArchive`. |
| Wait for Apple processing | Yes | Poll App Store Connect until the build is complete or failed. The wait itself remains unavoidable. |
| Set **What to Test** | Yes | App Store Connect's API exposes beta build localizations. |
| Add the build to **Internal** | Yes | App Store Connect's API exposes beta-group build relationships. |
| Verify `Testing` status | Yes | This must be a release gate, not an informal visual check. |
| Commit, tag, and push | Yes | Do this only after the uploaded build is verified. |
| Repair an expired login, accept an agreement, or complete an Apple challenge | No | These remain occasional interactive account operations. |

## One-time setup for full automation

The remaining release clicks can be removed by configuring an App Store Connect
API key once:

1. Have the Account Holder or an Admin create an App Store Connect API key with
   only the access needed to upload and manage TestFlight builds.
2. Download its `AuthKey_<key-id>.p8` file once and store it outside this
   repository in a private local location.
3. Copy `src/swift_app/Config/TestFlight.local.env.example` to
   `src/swift_app/Config/TestFlight.local.env`. Fill in the key ID, issuer ID,
   and absolute private-key path. The local file is ignored by Git.
4. Never put the `.p8` file inside this repository and never print the private
   key in logs.
5. Confirm that automatic signing works for every shipping target.
6. Confirm that the App Store Connect beta group named **Internal** exists.

Installed Xcode supports App Store Connect key authentication through
`-authenticationKeyPath`, `-authenticationKeyID`, and
`-authenticationKeyIssuerID`. The App Store Connect API can then handle build
status, **What to Test**, group assignment, and final verification.

## Release discipline

Every TestFlight upload is a release. For each upload:

1. Advance `MARKETING_VERSION` by one minor version (`1.5` to `1.6`) and
   increment `CURRENT_PROJECT_VERSION` at the same time.
2. Add `docs/releases/<marketing-version>.md` with concise release notes and a
   focused **What to test** section.
3. Keep every shipping target on the same version and build number.
4. Run the narrowest relevant tests, then the full capture/sync/UI harness when
   those areas changed.
5. Archive and upload the exact tested source.
6. Wait for the exact build to finish processing.
7. Save **What to Test** and add the build to **Internal**.
8. Verify that **Internal → Builds** shows the exact version/build as
   `Testing`.
9. Commit as `release: v<marketing-version>`, create the matching tag, and push
   the commit and tag to `origin`.

Never reuse a marketing version or build number.

## Automated command-line path

Prepare the next release-note file:

```sh
./scripts/release-testflight.sh --prepare 1.6 13
```

Edit every placeholder in `docs/releases/1.6.md`. Check the complete plan
without changing files, Git, the network, or Apple:

```sh
./scripts/release-testflight.sh --dry-run 1.6 13
```

Run the release:

```sh
./scripts/release-testflight.sh 1.6 13
```

The command enforces the version and build increments, requires approved
release notes, rejects unrelated worktree changes, runs the public-tree check
and both test passes, archives, validates embedded versions, uploads, polls
Apple, saves **What to Test**, adds **Internal**, waits for
`IN_BETA_TESTING`, fingerprints the uploaded source, commits, tags, pushes,
and verifies both remote Git refs.

Its durable state is stored under `build/releases/`. If Apple processing or a
later step is interrupted, use:

```sh
./scripts/release-testflight.sh --resume 1.6 13
```

The script marks the upload as in progress before invoking Xcode. If the
process dies at that exact boundary, `--resume` waits for Apple instead of
risking a duplicate upload. Only after confirming that Apple never received
the build should the upload be retried explicitly:

```sh
./scripts/release-testflight.sh --retry-upload 1.6 13
```

There are intentionally no skip-test, skip-upload, or skip-push flags.

## Xcode and App Store Connect fallback

Use this path until API-key automation is configured, or when an account issue
breaks the command-line upload.

1. Open Xcode and choose **Product → Archive**. Archiving from Xcode is the
   simplest way to ensure the archive appears in Organizer.
2. In **Window → Organizer → Archives**, select the exact WristMemo archive.
3. Click **Distribute App**.
4. Choose **App Store Connect**, then the upload/distribute option.
5. Review signing and version information carefully, then click **Distribute**.
6. Wait for Xcode to report that the upload succeeded.
7. Open App Store Connect and select the app record currently named
   **Agent Wrist Capture**.
8. Open **TestFlight → iOS** and wait for the exact build's upload status to
   become complete. A `Processing` build is not ready yet.
9. Open the build, paste the concise **What to test** text from
   `docs/releases/<version>.md`, and save it.
10. Click **Add Group**, select **Internal**, and confirm **Add**.
11. Open **Internal → Builds** and verify that the exact version and build show
    `Testing`.
12. Refresh the TestFlight app on the device and confirm that the same build is
    installable.
13. Commit the exact shipped source, tag it, and push the branch and tag.

## Failure diagnosis

### `missing Xcode-Username`

The Xcode command-line account credential is incomplete or stale. Either:

- open **Xcode → Settings → Accounts**, remove and re-add the Apple account,
  then retry; or
- use the App Store Connect API-key path, which avoids depending on Xcode's
  interactive account credential.

Organizer working does not prove that the command-line credential is healthy.

### Upload is complete but the build is missing from TestFlight

Check **TestFlight → Internal → Builds**. The build was probably uploaded but
not assigned to the Internal group. Add it explicitly and verify `Testing`.

### The build is still processing

Wait and poll the build status. Apple's processing cannot be bypassed. If it
fails, inspect the build status and Apple's email rather than repeating the
same version/build upload. Apple advises contacting support if processing has
not completed after 24 hours.

### The version or build already exists

Stop. Advance both values according to the repository release discipline,
rebuild, and upload a new archive. Never reuse a TestFlight version or build
number.

### The archive uses development signing

The export step is expected to sign the distributed app for App Store Connect.
If export cannot do so, repair the distribution credentials or configure the
API key; do not treat the development-signed archive itself as uploaded.

## Definition of done

A TestFlight release is complete only when all of these are true:

- The intended tests passed against the exact shipped source.
- Every shipping target contains the intended marketing version and build.
- The release-notes file exists and matches **What to Test**.
- App Store Connect shows the exact upload as processed successfully.
- The **Internal** group's Builds page shows the exact build as `Testing`.
- The build is visible to the intended tester in the TestFlight app.
- The exact source is committed as `release: v<version>`.
- Tag `v<version>`, the release commit, and the release branch are pushed to
  `origin`.
- The working tree is clean.

## Release script

The release command is:

```sh
./scripts/release-testflight.sh 1.6 13
```

It validates rather than silently guessing. Any mismatch or failed Apple
response stops with a specific recovery instruction, and the resumable state
prevents a failure after upload from turning into an accidental duplicate.

## Apple references

- [Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)
- [View builds and metadata](https://developer.apple.com/help/app-store-connect/manage-builds/view-builds-and-metadata/)
- [App Store Connect API](https://developer.apple.com/documentation/appstoreconnectapi/)
- [Beta build localizations](https://developer.apple.com/documentation/appstoreconnectapi/beta-build-localizations)
- [Beta groups](https://developer.apple.com/documentation/appstoreconnectapi/beta-groups)
- [List builds for a beta group](https://developer.apple.com/documentation/appstoreconnectapi/get-v1-betagroups-_id_-builds)
