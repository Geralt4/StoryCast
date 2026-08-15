# StoryCast 1.4 (build 12) — Pre-Deployment Plan

Target: major release featuring iCloud / CloudKit sync.

## Readiness Summary

### Green
- **iCloud sync layer** (`StoryCast/Services/Sync/`, 15 files): mature, production-grade. Real CloudKit container `iCloud.IoannisManologlou.StoryCast` matches entitlements. Deterministic conflict resolution (revision → time → device → digest), tombstone deletions, SHA-256 asset verification, exponential-backoff retries with localized user-facing error messages. Audiobookshelf data and credentials are architecturally excluded from iCloud (enforced in code and covered by tests).
- **No TODO / FIXME / HACK** markers in the sync layer.
- **No `print()` / `NSLog()`** in production source — logging goes through `AppLogger` with `.private` privacy annotations.
- **Privacy docs** (`docs/privacy.html`, effective July 18, 2026) already declare iCloud Sync and "Data Not Collected".
- **Tests**: 26 test files (25 unit + 1 UI), including sync-specific coverage (`SyncFoundationTests`, `CloudSyncRecordCodecTests`, `GroupBSyncFixTests`, `GroupAConcurrencyFixTests`, `GroupDFinalFixTests`).
- **Build tooling**: fastlane removed; direct `xcodebuild archive` + `-exportArchive` workflow with committed `ExportOptions.plist` (method `app-store-connect`, team `ZY5G2U9YN3`, automatic signing).
- **Version alignment**: all 6 configs at `MARKETING_VERSION = 1.4`, `CURRENT_PROJECT_VERSION = 12`.
- **Release notes** preserved at `release_notes/v1.4.txt`.

### Blocker-level items
1. **CloudKit Production schema deployment** — must be verified (Phase 4). Development-only schema breaks sync for App Store users. ← **MANDATORY READINESS GATE**
2. **CloudKit Dashboard confirmation** — user must visually confirm the 7 record types in Production (Phase 4 step 2); not verifiable from CLI.

### Minor (non-blocking)
- `SyncLocalMutation` is a registered SwiftData model with no apparent read/write references — possibly vestigial. Harmless; clean up later if desired.

---

## Pre-Deployment Plan

### Phase 1 — Commit pending fixes ✅ DONE
Committed as `792baed` (9 files: build number, play/pause fix, preview safety, sleep timer, logging privacy, support links).

### Phase 2 — Repo hygiene ✅ DONE
`.hermes/` and `.opencode/` gitignored in `b26e4b5`.

### Phase 3 — Version bump ✅ DONE
All 6 configs aligned to 1.4 (`9536272`), build bumped to 12 (`0d9056b`), fastlane auto-increment disabled (`d07ff82`).

### Phase 3.5 — Remove fastlane ✅ DONE
- `fastlane/` directory, `Gemfile`, `Gemfile.lock` deleted.
- Fastlane section removed from `.gitignore`.
- Release notes preserved at `release_notes/v1.4.txt`.
- `ExportOptions.plist` committed at repo root for xcodebuild export.

### Phase 4 — CloudKit Production Environment Verification
**Objective:** Confirm the CloudKit schema (record types and indexes) is deployed to Production.

> **STATUS (Aug 15, 2026): NOT DEPLOYED — both the Development and Production environments currently show only the built-in `Users` record type (user-confirmed in the CloudKit Console). The 7 `SC*V1` record types are absent from both. This is the mandatory go-live gate.** Deployment plan: `docs/cloudkit-production-deployment.md`. Source schema file: `cloudkit-schema.ckdb` (committed alongside this plan). Path: materialize via `xcrun cktool import-schema` into Development, then `Deploy Schema Changes…` from Development to Production.

**Critical:** Development environment data does not carry to Production. If the schema exists only in Development, App Store users will encounter `CKError.unknownItem` on first sync attempt.

**Steps:**
1. Log into [CloudKit Dashboard](https://icloud.developer.apple.com/dashboard/); confirm container `iCloud.IoannisManologlou.StoryCast` under team `ZY5G2U9YN3`; switch to **Production** environment.
2. In Production, Private Database, confirm all 7 record types are deployed with their indexes:
   - `SCLibraryGenerationV1`, `SCBookV1`, `SCFolderV1`, `SCChapterV1`, `SCAssetV1`, `SCProgressHeadV1`, `SCTombstoneV1`
   - Source: `StoryCast/Services/Sync/CloudSyncRecordCodec.swift:5-11`
   - **Note:** custom zone `StoryCastLibraryV1` is created at runtime by the first Production client via `CKSyncEngine`; it will not appear in the Dashboard until the first App Store user syncs. This is expected — verify record types and indexes only.
3. Confirm the App Store distribution provisioning profile includes the iCloud container `iCloud.IoannisManologlou.StoryCast`.

**Success Criteria (MANDATORY READINESS GATE):**
- All 7 record types confirmed deployed in CloudKit Dashboard → Production environment → Private Database.
- Provisioning profile includes the iCloud container `iCloud.IoannisManologlou.StoryCast`.

**CRITICAL:** This is a go-live blocker. If record types are not in Production, every App Store user attempting to sync will encounter `CKError.unknownItem`. Submission to App Store Connect without Production schema deployment results in a broken sync experience for all users.

**Failure handling:** If record types are missing in Production, deploy via CloudKit Dashboard "Deploy Schema Changes..." (Development → Production), then re-verify. If the provisioning profile lacks the container, regenerate it in the Apple Developer portal with iCloud capability enabled.

### Phase 5 — Archive Build Verification
**Objective:** Build the shippable artifact (app-store archive) and verify code signing, entitlements, and provisioning.

**Prerequisites:**

**Xcode account authentication (required):**
- Apple ID `johnmanologlou@gmail.com` must be signed in via Xcode → Preferences → Accounts with team `ZY5G2U9YN3` visible.
- Xcode's **cloud-managed signing** (Xcode 14+) auto-provisions an "Apple Distribution" certificate during archive/export when an account is signed in.
- The `-allowProvisioningUpdates` flag enables automatic profile downloads and certificate management.

**Note on certificate management:**
- With cloud-managed signing, no manual distribution certificate installation is required — Xcode creates and manages the identity automatically.
- The local keychain may show only an "Apple Development" identity; this is expected — the distribution identity is cloud-managed and not stored locally.
- **Local CLI probes are informational only**: `defaults read com.apple.dt.Xcode IDEProvisioningTeams` and keychain lookups may read negative even when cloud-managed signing works. The archive/export attempt itself is the authoritative signing check — do not gate on probe results.
- Fallback: if cloud-managed signing is unavailable (e.g., older Xcode, team restrictions), manually download an "Apple Distribution" certificate from the Apple Developer portal and install via Keychain Access or Xcode → Preferences → Accounts → Manage Certificates.

**Build steps:**
```bash
# Clean any existing archive and IPA (exportArchive fails if the IPA already exists)
rm -rf ./build/StoryCast.xcarchive ./build/StoryCast.ipa

# Create archive
xcodebuild archive \
  -project StoryCast.xcodeproj \
  -scheme StoryCast \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath ./build/StoryCast.xcarchive \
  -allowProvisioningUpdates

# Export archive for App Store distribution
xcodebuild -exportArchive \
  -archivePath ./build/StoryCast.xcarchive \
  -exportOptionsPlist ./ExportOptions.plist \
  -exportPath ./build
```

**Expected signing behavior:**
- The archive step may log a Development identity (`Apple Development: IOANNIS MANOLOGLOU`) during the build — this is expected with automatic signing.
- The export step re-signs the app with the cloud-managed "Apple Distribution" certificate and store provisioning profile.
- Verify the final IPA's distribution signing via `codesign -dvv` on the app bundle inside the archive (`build/StoryCast.xcarchive/Products/Applications/StoryCast.app`) or extracted from the IPA.

**Verify:**
- Exit code 0 on both commands; no code-signing errors or missing-entitlement warnings in the log.
- Outputs: `./build/StoryCast.xcarchive` and `./build/StoryCast.ipa`.
- (Optional) Xcode → Window → Organizer → select archive → "Validate App" (does not submit).

**Failure handling:**
- No Xcode account session / cloud-managed signing fails → verify Apple ID is signed in via Xcode → Preferences → Accounts with team `ZY5G2U9YN3` visible. If cloud-managed signing is unavailable for your account/team, download and install an "Apple Distribution" certificate manually from the Apple Developer portal, then re-run.
- Xcode account session expired → re-login in Xcode → Preferences → Accounts, re-run.
- Provisioning profile missing iCloud container → verify Phase 4 step 3; download manual profiles in Xcode → Preferences → Accounts, re-run.
- Build failure unrelated to signing → fix code, commit, re-run.

### Phase 6 — Full Test Suite
**Objective:** Run all 26 test files to confirm no regressions.

**Steps:**
1. Configure XcodeBuildMCP session defaults (project `StoryCast.xcodeproj`, scheme `StoryCast`, simulator) via `session_show_defaults` / `session_set_defaults`.
2. Remove any stale result bundle: `rm -rf ./build/TestResults.xcresult`.
3. Run tests via XcodeBuildMCP `test_sim` (preferred). Fallback:
   ```bash
   xcodebuild test \
     -project StoryCast.xcodeproj \
     -scheme StoryCast \
     -destination 'platform=iOS Simulator,name=iPhone 15,OS=latest' \
     -resultBundlePath ./build/TestResults.xcresult
   ```
4. All tests must pass (exit code 0). Pay particular attention to:
   - `SyncFoundationTests`, `CloudSyncRecordCodecTests`, `GroupBSyncFixTests`, `GroupAConcurrencyFixTests`, `GroupDFinalFixTests`.

**Failure handling:** Fix-forward for real regressions (commit fix, re-run). Rollback criteria: if critical sync bugs cannot be quickly fixed, consider reverting to 1.3 and deferring the release — escalate to project owner.

### Phase 7 — Final Readiness Report
- Summarize Phases 4–6 outcomes (CloudKit Production ✅/❌, archive build ✅/❌, test pass/fail counts).
- Confirm clean working tree (except this plan document).
- Provide GO / NO-GO recommendation.
- Do **not** tag, push, or submit in this flow — those are explicit steps that require a separate ask.

**GO/NO-GO Verdict Criteria:**
- Phase 4: CloudKit Production schema verified (user must confirm via Dashboard) ← **MANDATORY**
- Phase 5: Archive build succeeded with valid App Store distribution signing ← verified
- Phase 6: Full test suite passed with 0 failures ← verified
- Working tree clean, no uncommitted changes ← verified

A GO verdict is **conditional** on CloudKit Production schema confirmation (Phase 4). If the user has not verified the Dashboard, the verdict is "CONDITIONAL GO — pending Phase 4 user confirmation."

---

## Decisions Locked
- Marketing version: **1.4**
- Build number: **12**
- Extensions aligned to app marketing version (1.4)
- Verification scope: CloudKit Production schema + app-store archive (xcodebuild) + full test suite
- Commit style: separate commits per phase

## Out of Scope (Requires Separate Ask)
- Tagging the release commit
- Pushing to `origin/main`
- Submitting to TestFlight / App Store Connect (via Xcode Organizer → Distribute App, or Transporter)
- Updating `CHANGELOG` or additional release notes
- Cleaning up the unused `SyncLocalMutation` model
