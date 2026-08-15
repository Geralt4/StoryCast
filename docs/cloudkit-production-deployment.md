# CloudKit Production Schema Deployment

**Status (Aug 15, 2026):** The CloudKit container `iCloud.IoannisManologlou.StoryCast` has **no record types deployed to either environment** (confirmed in the CloudKit Console — both Development and Production show only the built-in `Users` type). This is the mandatory go-live gate from `Pre Deployment.md` Phase 4: without it, every App Store user's first sync fails with `CKError.unknownItem`.

The shipped IPA is signed with `com.apple.developer.icloud-container-environment = Production`, so App Store builds talk to the Production environment directly.

## The exact schema StoryCast needs

Source of truth: `StoryCast/Services/Sync/CloudSyncRecordCodec.swift`.

### Record types (7)

| Record type | Extra field beyond the shared three |
| --- | --- |
| `SCLibraryGenerationV1` | — |
| `SCBookV1` | — |
| `SCFolderV1` | — |
| `SCChapterV1` | — |
| `SCAssetV1` | `asset` (Asset) |
| `SCProgressHeadV1` | — |
| `SCTombstoneV1` | — |

### Fields shared by all types (3)

| Field | CloudKit type |
| --- | --- |
| `schemaVersion` | Int64 |
| `payload` | Bytes |
| `updatedAt` | Date/Time |

### Not part of the schema (expected)

- **Custom zone `StoryCastLibraryV1`** — created at runtime by the first client via `CKSyncEngine`; it will not appear in the Console until a user actually syncs. Do not wait for it.
- **No custom indexes** — StoryCast never issues `CKQuery`; all reads go through `CKSyncEngine` change fetches, so no queryable fields or indexes are required.

The ready-to-import file lives at `cloudkit-schema.ckdb` (repo root). It declares the 7 record types with only the 3 (or 4 for `SCAssetV1`) custom fields above — the CloudKit system fields (`___createTime`, `___createdBy`, `___etag`, `___modTime`, `___modifiedBy`, `___recordID`) are auto-created on every record type by CloudKit and do not need to be declared. Security is left at the default: private-DB records are automatically user-scoped, so no explicit `GRANT` clauses are required.

## Deployment steps (CloudKit Console + `cktool`)

> CloudKit's production schema can only be created via `cktool import-schema` against the **Development** environment. Promotion to **Production** still happens in the Console.

### Step 1 — Save a management token (one-time, browser login)

In Terminal on your Mac:

```bash
xcrun cktool save-token --type management
```

This opens a Safari authentication sheet. Sign in with the Apple ID that belongs to team `ZY5G2U9YN3` and allow access. The token is stored in macOS Keychain and reused by subsequent `cktool` commands.

### Step 2 — Dry-run validate the schema file (safe)

This checks the file format and (where possible) the schema compatibility without touching the container:

```bash
xcrun cktool validate-schema \
  --team-id ZY5G2U9YN3 \
  --container-id iCloud.IoannisManologlou.StoryCast \
  --environment development \
  --file ./cloudkit-schema.ckdb
```

Expected output: a success report listing the 7 record types. If the tool reports a parse error, paste the message back to the developer — the file format may need a tweak.

### Step 3 — Import into Development

```bash
xcrun cktool import-schema \
  --team-id ZY5G2U9YN3 \
  --container-id iCloud.IoannisManologlou.StoryCast \
  --environment development \
  --file ./cloudkit-schema.ckdb
```

Refresh the CloudKit Console → switch environment to **Development** → **Schema → Record Types**. You should now see the 7 record types listed alongside the built-in `Users` type.

### Step 4 — Deploy to Production

In the **Development** environment view, click **"Deploy Schema Changes…"** (bottom-left of the sidebar) → select all 7 record types → **Deploy**.

### Step 5 — Verify Production

Switch the environment selector to **Production** → **Schema → Record Types**. All 7 types should appear (allow a few minutes for propagation).

Optional CLI check:

```bash
xcrun cktool export-schema \
  --team-id ZY5G2U9YN3 \
  --container-id iCloud.IoannisManologlou.StoryCast \
  --environment production \
  --output-file ./production-schema.ckdb
```

`./production-schema.ckdb` should contain the same 7 types.

## After deployment

- Release gate satisfied → the GO verdict becomes unconditional (tests ✅, signing ✅, schema ✅).
- The `StoryCastLibraryV1` zone still will not exist in Production until the first real user syncs — expected and harmless.
- No code or build changes are required; the existing `build/StoryCast.ipa` is already correct.
- Production record types cannot be deleted or renamed once promoted — only fields can be added. Plan future schema additions with this constraint in mind.
