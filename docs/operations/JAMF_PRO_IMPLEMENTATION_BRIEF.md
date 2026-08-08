# WristMemo — Jamf Pro implementation brief

**Audience:** Enterprise IT / Jamf Pro administrator and the technical team or
implementation agent working with them.

**Purpose:** Build a secure, company-owned iPhone + Apple Watch deployment for
WristMemo. This is an execution brief, not a generic MDM overview. It is safe
to give to an implementation agent, but **never provide it with credentials,
private keys, API tokens, employee data, or production configuration exports**.

**Authoritative companion:** [Secure enterprise deployment](SECURE_ENTERPRISE_DEPLOYMENT.md)
explains the security architecture and product constraints behind this checklist.

## Human brief — read this first

**Goal:** Issue each approved employee a company-owned iPhone and Apple Watch
pair that is supervised and managed in Jamf, then use that iPhone as the secure
network gateway for WristMemo captures.

**The simple plan:**

1. IT enrolls company iPhones through Apple Business Manager + Automated Device
   Enrollment, scopes an eligible supervised-iPhone group in Jamf, and enables
   Apple Watch enrollment only for that group.
2. IT installs the WristMemo iPhone app as an ABM Custom App, sends it only
   non-secret configuration, and pairs a new/erased company Watch through the
   iPhone’s Remote Management flow.
3. Engineering makes the iPhone prove its own device/app identity and get
   short-lived, tenant-specific upload permission. The Watch never receives an
   API key or reusable upload token.
4. Start with a small named pilot. Test capture and recovery with the phone
   offline, then expand only after security and support sign-off.

**The non-negotiables:**

- This is company-owned, one worker per iPhone/Watch pair—not BYOD, shared
  Watches, or Watch-only management.
- The current single-user Google identity allowlist and OAuth App Check are a
  strong private deployment baseline, but they do not prove MDM compliance,
  tenant assignment, or per-device revocation. Add those before enterprise
  production.
- Never put API keys, client private keys, shared bearer tokens, recordings, or
  transcripts into Jamf configuration, support tickets, logs, or AI prompts.
- The Watch saves the recording first; network, transcription, and AI work
  happen afterward. Failed delivery must remain visible and repairable.
- A lost/reassigned device must lose service access immediately, even if it
  never checks in again.

**What IT needs to deliver:** ABM/ADE, Jamf scopes and security baseline,
Custom App distribution, managed non-secret configuration, Watch-pairing
procedure, inventory/reports, and lost-device/offboarding runbooks.

**What engineering needs to deliver:** per-device registration, App Attest and
device-bound authentication, short-lived authorization, tenant isolation,
server-side revocation, audio-at-rest protections, and failure/recovery tests.

**Go/no-go:** Do not launch beyond a pilot until a new managed pair can enroll,
capture with the phone unavailable, recover one copy safely, reject a revoked
or wrong-tenant upload, and show that no secret or audio reaches Jamf or server
logs.

---

## Detailed implementation context for IT and its implementation agent

The material below is intentionally thorough. It is the reference checklist
for the IT team or its AI implementation agent; the section above is the
decision summary for the human owner.

### The required outcome

Each worker receives one company-owned, supervised iPhone paired to one
company-owned Apple Watch. The iPhone is enrolled through Automated Device
Enrollment (ADE) in Apple Business Manager (ABM) and managed by Jamf Pro. The
watch is enrolled **during fresh pairing** through the supervised host iPhone.

WristMemo remains a capture appliance:

- The Watch deliberately records and durably retains audio until hand-off.
- The iPhone is the managed network and identity boundary.
- Audio is sent from the phone to the WristMemo service only after a verified,
  authenticated hand-off.
- The Watch does not hold a reusable production upload credential.
- The service accepts a request only after device-, user-, and tenant-specific
  authorization succeeds.

This is not a bring-your-own-device program, a shared-device program, or a
Watch-only deployment. Those are different security designs and are out of
scope for the first rollout.

## Do not proceed on the current private deployment alone

The current WristMemo service verifies short-lived Google ID tokens, an exact
single-user OIDC subject, and OAuth App Check/App Attest on the iOS client. That
removes the old fleet-wide shared token, but it is still **not sufficient for a
multi-user enterprise rollout**: it has no tenant assignment, managed-device
posture proof, or individual device revocation registry.

Before any production device can upload, WristMemo engineering must replace
them with the registration and authorization model in this brief:

1. An individual iPhone installation registers to its assigned tenant and
   managed user.
2. The iPhone proves a non-exportable device/app identity on each sensitive
   request (for example, client certificate plus App Attest assertion).
3. The service issues short-lived, narrowly scoped upload authorization.
4. Every memo, audit event, and retention decision is tied to the real tenant,
   person, device, and watch-generated memo UUID.

Jamf can establish device management posture; Google user identity alone cannot
turn that posture into per-device authorization. This is a joint IT and
engineering deliverable.

## Design decisions to confirm before configuration

The business owner, security lead, IT, and WristMemo engineering must sign off
on these items. Do not guess them in Jamf.

| Decision | Required production choice |
| --- | --- |
| Device ownership | Company-owned iPhone and Apple Watch, assigned one-to-one to a named worker. |
| Enrollment | iPhone uses ABM + ADE supervision; Apple Watch enrollment is enabled only for the designated iPhone group. |
| Minimum OS | iPhone/iOS 17 or later and Apple Watch/watchOS 10 or later; use a higher supported baseline if the security program requires it. |
| Account model | Managed Apple Account where required by the business; it is not an authorization substitute for WristMemo. |
| App distribution | Private Custom App in Apple Business Manager, licensed to the organization and deployed by Jamf. |
| Data classification | Audio is sensitive company data; transcripts and derived summaries inherit the organization’s applicable classification. |
| Data location | No audio at rest in Cloud Run, logs, analytics, crash reports, or temporary server files. Text storage is tenant-isolated and subject to the agreed retention schedule. |
| Identity boundary | iPhone is the network trust anchor; the Watch has no reusable API secret. |
| Recovery | Lost or failed hand-off is visible and repairable. A device replacement does not silently destroy unconfirmed audio. |
| Pilot | Use a small named cohort first; no broad deployment before the acceptance tests pass. |

## Responsibility split

| Workstream | IT / Jamf | WristMemo engineering | Security / business owner |
| --- | --- | --- | --- |
| ABM, ADE, Jamf Cloud, APNs, Apps and Books | Owns and operates | Consulted | Approves access and procurement |
| iPhone supervision, restrictions, Wi-Fi/VPN, OS-update policy | Implements and tests | Confirms capture is not impaired | Approves security baseline |
| Apple Watch enrollment group and asset lifecycle | Implements and audits | Provides app requirements | Approves issuance/offboarding policy |
| App packaging and Custom App submission | Distributes/licenses | Builds, signs, publishes updates | Approves release channel |
| Managed app-configuration schema | Creates Jamf payload from approved schema | Defines schema and validates parsing | Approves non-secret fields |
| Per-device identity, client authentication, replay defense, tenant authorization | Provides PKI/MDM inputs if used | Implements server and app protocol | Reviews threat model and evidence |
| Audio/transcript retention and deletion controls | Enforces device posture/erase | Implements service-side lifecycle | Sets retention and legal holds |
| Security evidence and incident response | Owns device inventory/actions | Supplies service audit trail | Owns approvals and incident decisions |

No team should assume another team owns a blank cell. Create a named RACI
before work begins.

## Preconditions in Apple and Jamf

Complete and evidence each prerequisite before issuing pilot devices.

### Apple Business Manager

- Organization is verified in ABM and has an approved purchaser/reseller flow
  so iPhones and Watches appear as organization-owned assets.
- Jamf Pro has an active ABM automated-enrollment connection and an active
  Apps and Books token.
- The organization has approved the **WristMemo** Custom App for private
  distribution in ABM. If the app is not yet published, give engineering the
  ABM Organization ID and any required distribution requirements; do not
  substitute a public App Store build for production without approval.
- The asset record, serial number, assigned person, iPhone serial, Watch serial,
  and issuance/return status can be reconciled with Jamf inventory.
- Activation Lock responsibilities and the permitted ABM roles are documented.

Apple can record organization-owned Watches in ABM, but a Watch is enrolled in
MDM when it is paired to an eligible supervised iPhone. Treat the iPhone–Watch
pairing as an issuance step, not a background inventory process.

### Jamf Pro administration

- Use a Jamf Pro Cloud-hosted tenant with its Cloud Services connection enabled.
- Grant the smallest practical role privileges. The role that enables Watch
  enrollment needs the relevant Apple Watch enrollment setting privilege; it
  must not become a broad Jamf administrator role by convenience.
- Protect Jamf administrator accounts with phishing-resistant MFA, named
  accounts, limited break-glass access, and audit-log review.
- Maintain a current APNs certificate with a documented renewal owner and
  calendar reminder. Test renewals before expiry.
- Verify that the Jamf version currently in use still supports the exact Apple
  Watch enrollment flow described below. UI labels change; confirm against the
  current Jamf documentation before making production changes.
- Configure ABM/ADE enrollment profiles so MDM management is non-removable for
  the target corporate-device population, consistent with local policy and
  law.

## Jamf objects to create

Use consistent names, production/test separation, and change tickets. The
following are the minimum implementation objects. Exact UI labels can differ by
Jamf release.

### 1. Scope group for eligible host iPhones

Create a Smart Device Group, for example:

`WristMemo — Eligible iPhone Hosts — Production`

Membership must require all of the following:

- corporate-owned, supervised iPhone;
- enrolled through ADE;
- iOS 17 or later (or the approved higher baseline);
- current Jamf management profile present;
- assigned to the approved pilot/production population; and
- no unresolved compliance condition that policy says blocks WristMemo.

Do not key eligibility solely on a device name, serial-number list, or the
presence of the app. Keep a separate static or identity-backed assignment group
for the people authorized to use the production service.

In Jamf Pro, enable **Apple Watch enrollment** for this group in the group’s
Automated Management area. Jamf’s documented flow applies the corresponding
Watch enrollment configuration to member iPhones; deleting the group removes
that configuration. Change-control the group accordingly.

### 2. ADE enrollment profile for WristMemo iPhones

Create or deliberately scope an ADE enrollment profile for the workforce
devices. It must establish supervision and enforce the organizational setup
experience. Configure the permitted Setup Assistant screens according to the
company’s privacy and operational policies.

Record these settings in the change ticket:

- enrollment profile name and scope;
- supervision enabled;
- MDM profile removal policy;
- authentication / account-assignment approach;
- OS update and deferral policy;
- required Wi-Fi or cellular connectivity path during enrollment; and
- support contact shown to the user.

Do not promise zero-touch Watch deployment: an eligible Watch must be new or
erased and paired during the user-facing pairing flow, where the user accepts
Remote Management.

### 3. Security-baseline configuration profiles

Scope the company’s approved iPhone security baseline to the eligible-host
group. Use separate, reviewable profiles instead of an opaque all-in-one
profile. Typical profiles cover:

- passcode, Auto-Lock, and device-lock requirements;
- OS-update cadence and minimum version;
- Wi-Fi / 802.1X and, if approved, per-app VPN;
- certificates or identity payloads issued through the organization’s PKI;
- restrictions on unauthorized app installation/removal and account changes;
- AirDrop, clipboard, iCloud, backup, and sharing policy as determined by the
  data-classification decision; and
- lost-mode and erase capability for corporate-owned devices.

Start from the organization’s approved mobile baseline; do not blindly apply
every possible restriction. In particular, validate that the final restrictions
do not block Bluetooth pairing, microphone permission, Watch companion
installation, network delivery, or required accessibility features.

An iPhone’s local memo directory may otherwise be eligible for iCloud restore.
For the highest-security deployment, engineering must use an explicit
no-backup protection strategy for unhanded-off audio, or encrypt recovery data
so a restore alone cannot recover it. This is a product/security decision—not
a Jamf checkbox.

### 4. WristMemo mobile-device application record

Create distinct app records for the test and production builds. Use the iOS
bundle that includes the Watch companion; Jamf deployment begins on the iPhone,
then the paired Watch receives the companion according to Apple’s supported
app-install flow.

For each production record:

- attach the ABM Apps and Books license assignment;
- set the correct production bundle identifier and version channel;
- make the app required for the approved iPhone scope;
- disallow user removal only if the approved baseline and labor policy permit
  it;
- define an update process, emergency rollback condition, and release owner;
- test the iPhone-first installation and Watch companion installation on a
  fresh pair; and
- retain an app-inventory report with installed version, iPhone serial, paired
  Watch serial, and assignment owner.

Apple’s management model requires a paired app to be installed on the iPhone
before installation on the Watch. Treat an absent or stale Watch companion as
a visible compliance/remediation condition, not as proof that the service is
working.

### 5. WristMemo managed app configuration

Create a Managed App Configuration payload on the **iPhone app record**. Jamf
delivers this as a property-list key/value payload to the iOS app. The Watch is
not the credential endpoint: the companion iPhone app consumes this
configuration and uses the approved phone-to-watch protocol only for
non-secret behavior or status needed on the Watch.

Use the following **non-secret** schema as a starting point. Engineering must
publish the final versioned schema and reject malformed or unknown critical
values safely.

```xml
<dict>
  <key>configuration_version</key>
  <string>1</string>
  <key>environment</key>
  <string>production</string>
  <key>tenant_id</key>
  <string>EXAMPLE-TENANT-ID</string>
  <key>service_base_url</key>
  <string>https://api.example.com</string>
  <key>device_registration_url</key>
  <string>https://api.example.com/device-registration</string>
  <key>policy_id</key>
  <string>wristmemo-prod-v1</string>
  <key>minimum_supported_app_version</key>
  <string>1.0.0</string>
  <key>support_url</key>
  <string>https://support.example.com/wristmemo</string>
</dict>
```

Allowed configuration values are public routing and policy identifiers—not
secrets. **Never place any of these in Jamf app configuration, a plist, source
code, an MDM custom field, a device name, logs, screenshots, or an AI prompt:**

- OpenAI API keys or service-provider keys;
- a shared `INGEST_BEARER_TOKEN` or static upload bearer token;
- client private keys, recovery keys, password material, or SCEP challenge
  secrets;
- employee health, voice, transcript, or investment/research content; or
- a production database connection string.

If an app uses a certificate identity, use the organization’s approved PKI
protocol and device-bound key storage. The WristMemo service must validate the
certificate chain, issuer, audience, validity, revocation state where
applicable, and mapping to the enrolled device/tenant. A certificate alone is
not enough: bind it to an authenticated app instance and short-lived request
authorization.

### 6. Inventory, reporting, and compliance groups

Create reports or smart groups for at least:

- eligible iPhone but no paired/enrolled Watch;
- paired Watch but WristMemo iPhone app absent or outdated;
- WristMemo app installed but device registration missing/failed;
- certificate or device authorization nearing expiry;
- app version below the required minimum;
- inactive / lost / retired device still authorized by the service;
- repeated hand-off failures needing support; and
- device or Watch removed from the approved assignment population.

Jamf is the authority for device posture; WristMemo is the authority for
application registration and memo-delivery status. Build a privacy-preserving
daily reconciliation using stable IDs and aggregate status, never transcript
or audio content.

## Required WristMemo engineering work

IT cannot complete the security design without these software changes. The
implementation agent should treat them as blocking production requirements.

### Enrollment and request authentication

1. On first managed launch, read the managed app configuration and verify the
   signed/attested registration response from the service.
2. Generate or obtain a device-bound key on the iPhone. The private key must
   be non-exportable and never copied to the Watch.
3. Register the app installation to the exact tenant, named worker, Jamf/asset
   reference, iPhone identifier, and permitted service policy. Do not rely on
   a human-entered tenant ID alone.
4. Use Apple App Attest (or an approved equivalent platform integrity proof)
   during registration and for high-value request assertions. Bind a
   server-provided nonce to prevent replay.
5. Authenticate calls with mutually authenticated TLS or another approved
   device-bound mechanism **plus** a short-lived, audience- and scope-limited
   authorization token. Rotate tokens and credentials without an app release.
6. Make the service reject static shared tokens, unknown devices, stale
   attestations, cross-tenant identifiers, replayed requests, and registrations
   from non-approved posture.
7. Support immediate server-side device disablement when Jamf marks a device
   lost, retired, or reassigned.

### Multi-tenant data protection

- Derive tenant and principal from verified server-side authorization, not from
  a request header or app configuration value.
- Enforce tenant scoping in every database query and background job; add tests
  that demonstrate cross-tenant access is impossible.
- Use the existing watch-generated UUID as the memo identity at every hop.
  Never replace it during retriable transfer.
- Store audio only on the Watch/iPhone until confirmed durable hand-off. Do not
  write audio to disk, object storage, application logs, error trackers, or
  server temporary files.
- Redact tokens and identifiers from logs; audit only necessary metadata such
  as tenant, device record, memo UUID, status, timestamp, and reason code.
- Configure the transcription provider under the approved enterprise contract,
  data-retention terms, and regional/privacy requirements. Revalidate those
  terms before production because provider controls change.

### Reliable capture and delivery

- Preserve the capture contract: the Watch haptic means microphone samples are
  being written, not that a network request has started.
- Retain the local audio until the next durable hop acknowledges the same memo
  UUID; show a repairable status if delivery stalls or fails.
- Keep networking, transcription, database activity, and model work off the
  recording start path.
- Do not return transcript content to the Watch as part of delivery
  acknowledgement. The intended boundary is one-way content out, status back.
- Include failures in test coverage: phone unavailable, Bluetooth interrupted,
  background restrictions, restart mid-transfer, expired authorization, lost
  certificate, retry after server error, tenant mismatch, and duplicate upload.

### Service perimeter

- Put the public registration/upload edge behind the organization’s approved
  WAF, DDoS controls, rate limits, and anomaly monitoring.
- Restrict Cloud Run and service-account access to the narrowest feasible
  network/identity path; do not regard a public URL plus a bearer string as a
  security boundary.
- Keep service-provider API credentials in the approved secret-management
  system, accessible only to the runtime identity that needs them.
- Separate development, test, and production projects, tenants, API audiences,
  certificate authorities, and logging sinks.
- Require independent security review before agents or automation can do
  anything consequential with a transcript. Until then, automation may draft
  or tag only; a human approves external actions.

## Pilot issuance runbook

Run this for every pilot participant and keep a ticketed record. A Watch that
was previously paired must be unpaired/erased before its MDM enrollment; do
not attempt to bypass this requirement.

1. Confirm the person, iPhone serial, Watch serial, cost center, business
   owner, and support contact in the asset system.
2. Assign the iPhone in ABM to the correct Jamf server and assign the WristMemo
   Custom App license through ABM/Apps and Books.
3. Erase the corporate iPhone if needed, then enroll it through ADE. Confirm
   supervision, the intended Jamf profile, Wi-Fi/cellular, and security
   baseline before handing it over.
4. Confirm the iPhone is in `WristMemo — Eligible iPhone Hosts — Production`
   and has received the Watch enrollment configuration.
5. Install/verify the required WristMemo iPhone app and its production managed
   configuration. Verify configuration presence without exposing its contents
   in screenshots or tickets.
6. Start pairing a new or erased company Watch in the iPhone Watch app. During
   pairing, accept the Apple **Remote Management** prompt. Confirm that the
   management profile installs and that the Watch reports as supervised/paired
   in the management inventory.
7. Confirm the WristMemo Watch companion is installed. If it is absent, follow
   the Apple/Jamf-supported iPhone-first app installation remediation path.
8. Launch WristMemo on the iPhone while online. Complete the approved device
   registration flow. Confirm only an opaque registration result, device ID,
   tenant, and status—not credentials—in the support record.
9. On the Watch, complete a non-sensitive test capture. Verify start cue,
   local save, phone hand-off, authenticated ingest, deduplication by memo
   UUID, and delivery status. Use an agreed synthetic phrase, not live business
   information.
10. Test a temporary phone-unavailable scenario. Confirm the Watch retains the
    memo and provides a visible recovery state; restore connection and verify
    one successful upload, not a duplicate.
11. Mark the asset as issued only after all acceptance checks pass. Record the
    production readiness evidence in the deployment ticket.

## Loss, replacement, and offboarding

### Lost or stolen

1. Open the incident ticket and identify the person, iPhone, Watch, and active
   WristMemo device-registration record.
2. In Jamf, place the iPhone in Lost Mode and perform the approved remote lock
   or erase action. Use ABM Activation Lock controls under the company’s
   documented authority.
3. Immediately revoke/disable the WristMemo device registration server-side;
   do not wait for the device to check in. Revoke its certificate and short
   lived-token refresh path as applicable.
4. Preserve only permitted security metadata for investigation. Do not attempt
   to retrieve recordings through unapproved channels.
5. Reissue a fresh iPhone/Watch pair using the pilot issuance runbook. The new
   pair gets new device-bound keys and authorization; never clone the old
   device identity.

### Employee transfer, return, or termination

1. Suspend application access and revoke the app/device authorization at the
   effective time.
2. Remove the person from the eligible/authorized production population.
3. Verify final delivery/reconciliation status under the agreed retention and
   legal-hold rules. Never silently destroy unconfirmed local audio just to
   finish offboarding.
4. Unpair/erase the Watch and erase/recover the iPhone following the corporate
   asset-return process. Unenrolling either side of a managed pair causes a
   reset/unpair event; plan this deliberately.
5. Remove or reassign ABM licenses, update inventory ownership, retain audit
   evidence, and validate that the old device cannot register or upload.

## Production acceptance criteria

All of these must pass before expanding beyond the pilot.

### Enrollment and management

- [ ] New iPhone enrolls through ABM/ADE as supervised and reaches the correct
      Jamf scope.
- [ ] Only eligible supervised iPhones receive Apple Watch enrollment
      configuration.
- [ ] New/erased Watch pairs through the Remote Management flow and is visible
      as managed/paired in inventory.
- [ ] An ineligible, personal, unsupervised, or below-minimum iPhone cannot
      receive the production Watch enrollment configuration or production app
      authorization.
- [ ] The configuration/app scopes survive expected inventory refreshes and a
      defined Jamf administrator can explain how to recover a failed pairing.

### App and data security

- [ ] Managed app configuration contains only approved non-secret values.
- [ ] No static shared service token works in production.
- [ ] A registered iPhone proves its device/app identity and receives only
      short-lived, scoped authorization.
- [ ] Requests with a replayed nonce/assertion, wrong audience, expired token,
      revoked certificate, unknown device, or wrong tenant are rejected and
      audit logged.
- [ ] Data access and background jobs cannot cross tenant boundaries; automated
      tests demonstrate this.
- [ ] Audio is absent from Cloud Run local storage, object storage, logs,
      error tracking, database fields, and support exports.
- [ ] Provider/API keys are stored only in approved secret management and never
      delivered by Jamf or embedded in the application.

### Capture reliability

- [ ] A start haptic occurs only after the Watch is writing microphone samples.
- [ ] Phone offline, Bluetooth interruption, app restart, server failure, and
      expired authorization preserve local audio and lead to an actionable
      recovery state.
- [ ] Retried delivery preserves the original UUID and results in exactly-once
      logical ingest (safe duplicate handling).
- [ ] The worker can obtain support without reading aloud, exporting, or
      attaching audio to a ticket.

### Operations

- [ ] Lost-device action disables service access in the defined target time.
- [ ] A returned/reassigned device cannot upload under its old identity.
- [ ] Alerting exists for failed registration, repeated hand-off failures,
      authorization failures, app-version drift, and certificate expiry.
- [ ] Runbooks have named owners and have been tabletop-tested.
- [ ] A security owner signs the pilot evidence and accepts residual risk.

## Evidence package for the security review

Provide this package; redact secrets, identifiers, and employee content.

1. ABM/ADE and Jamf scope design, privilege model, and screenshots of the
   approved configuration (with secrets redacted).
2. App distribution and managed configuration schema, including a negative
   check proving it contains no credentials.
3. Architecture diagram and request sequence for device registration,
   attestation, mTLS/device identity, token issuance, upload, and revocation.
4. Threat model covering a stolen Watch, stolen/unlocked phone, malicious
   enrolled device, replay, cross-tenant access, exposed log, compromised Jamf
   admin, and service-provider credential leak.
5. Test evidence for every production acceptance criterion above.
6. Retention/deletion policy, OpenAI or other transcription-provider data
   terms, data-processing approval, and incident-response contacts.
7. A list of residual risks with an accountable business owner for each.

## Suggested implementation order

1. Establish ABM, Jamf Cloud, ADE, APNs, Apps and Books, and a test iPhone
   cohort.
2. Build the eligible-host group and validate iPhone → Watch enrollment on two
   non-production pairs.
3. Publish/deploy the test Custom App and validate iPhone-first companion
   installation.
4. Implement the per-device registration and authorization changes in
   WristMemo; remove reliance on shared ingest authorization.
5. Add managed configuration parsing, PKI/App Attest integration, service
   revocation, tenant isolation tests, and privacy-preserving reconciliation.
6. Run the issuance and failure tests with a small named pilot.
7. Complete security review, operational handoff, and a measured phased rollout.

Do not reverse this order. A Watch that can be MDM-enrolled but uploads through
a shared token is not a secure enterprise deployment.

## Prompt for an IT implementation agent

The following is deliberately scoped so an IT team can give it to its own
assistant without granting it secrets or unbounded administration:

> We need to deploy company-owned iPhone + Apple Watch pairs for WristMemo in
> Jamf Pro. Read this entire implementation brief and its companion secure
> deployment document. First produce a read-only gap assessment against our
> ABM/Jamf configuration, current Jamf version, supported Apple OS versions,
> identity/PKI platform, app-distribution process, and mobile baseline. Then
> produce a change plan with exact Jamf objects, scopes, dependencies, rollback
> steps, named owners, and evidence to collect. Do not create, change, scope,
> delete, or export any production object without a human-approved change
> ticket. Do not request or store secrets, API keys, certificates, employee
> content, or production configuration exports. Identify which items belong to
> IT versus WristMemo engineering; flag the shared-token/default-user issue as
> a production blocker until engineering demonstrates per-device, tenant-bound,
> short-lived authorization and server-side revocation. Use the current Jamf
> documentation to verify all UI paths and capabilities before proposing final
> click-by-click instructions.

## Sources to verify during implementation

- Apple, [Use Apple Watch with MDM](https://support.apple.com/en-ie/guide/deployment/dep04f0c5414/web)
- Apple, [Manage device enrollment in Apple Business Manager](https://support.apple.com/guide/deployment/automated-device-enrollment-management-dep73069dd57/1/web/1.0)
- Apple, [Managed Device Attestation](https://support.apple.com/guide/deployment/deploy-managed-device-attestation-dep54e5ac1fd/web)
- Apple, [ManagedApp framework](https://support.apple.com/en-ca/guide/deployment/dep575bfed86/web)
- Apple Developer, [Establishing your app’s integrity with App Attest](https://developer.apple.com/documentation/DeviceCheck/establishing-your-app-s-integrity)
- Jamf, [Enable Apple Watch enrollment](https://learn.jamf.com/r/en-US/jamf-pro-documentation-11.14.0/Enabling_Enrollment_for_an_Apple_Watch_Device)
- Jamf, [Managed App Configuration](https://learn.jamf.com/r/en-US/jamf-pro-documentation-current/Managed_App_Configuration)
- Jamf, [Mobile device configuration profiles](https://learn.jamf.com/r/en-US/jamf-pro-documentation-current/Mobile_Device_Configuration_Profiles)
- OpenAI, [API data controls](https://developers.openai.com/api/docs/guides/your-data#default-usage-policies-by-endpoint)

The Jamf Apple Watch article above is version-specific; use it for the
documented prerequisites and flow, then check the matching **current** Jamf
documentation for your tenant before executing a change.
