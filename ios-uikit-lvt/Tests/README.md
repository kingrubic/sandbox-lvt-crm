# Native homeroom source checks (L1 + L2 + L3 + L4 + L5)

## Pending-journal build-repair regression

The import and management sources now share `restore(user)`, `before(path, args)`, `received(value)`, and `clear()`. Include `HomeroomPendingJournal.swift` in every standalone source check. Recovered markers stay write-locked, including after repeated authorization, corrupt marker reads, and changed year/date contexts; readonly refresh is not evidence that a write never happened.

```sh
scratch=/Users/vsc_agent/.hermes/cache/scratch/lvt-build-repair
mkdir -p "$scratch/tmp" "$scratch/swift-cache"
TMPDIR="$scratch/tmp" swiftc -module-cache-path "$scratch/swift-cache" \
  ios-uikit-lvt/LvtCrmUIKit/{AuthModels,CredentialStore,ConvexHttpClient,HomeroomRepository,HomeroomDetail,HomeroomWrites,HomeroomCameraImport,HomeroomManagement,HomeroomPendingJournal}.swift \
  ios-uikit-lvt/Tests/HomeroomPendingJournalChecks.swift -o "$scratch/pending-journal-checks"
TMPDIR="$scratch/tmp" "$scratch/pending-journal-checks"
```

Android `HomeroomPendingJournalTest` plus journal-backed tests in `HomeroomCameraImportTest` and `HomeroomManagementTest` cover recreation, owner/lane isolation, corrupt marker retries, retained IDs, blocked replay/discard, and clearing only after an acknowledged publish/commit. All checks use disposable offline fixtures; they do not complete L6 reconciliation or implement reports/L7.

Run from the repository root. This standalone host check compiles the actual UIKit app's Foundation session, HTTP client, credential types, and homeroom decoder source. It does not instantiate a client, launch the app, use credentials, or make live requests. Payloads are explicit offline contract fixtures, not successful live-data evidence.

```sh
scratch=$(mktemp -d /Users/vsc_agent/.hermes/cache/scratch/lvt-homeroom-checks.XXXXXX)
swiftc -module-cache-path "$scratch/cache" \
  ios-uikit-lvt/LvtCrmUIKit/AuthModels.swift \
  ios-uikit-lvt/LvtCrmUIKit/CredentialStore.swift \
  ios-uikit-lvt/LvtCrmUIKit/ConvexHttpClient.swift \
  ios-uikit-lvt/LvtCrmUIKit/HomeroomRepository.swift \
  ios-uikit-lvt/LvtCrmUIKit/HomeroomDetail.swift \
  ios-uikit-lvt/LvtCrmUIKit/HomeroomWrites.swift \
  ios-uikit-lvt/LvtCrmUIKit/HomeroomCameraImport.swift \
  ios-uikit-lvt/LvtCrmUIKit/HomeroomManagement.swift \
  ios-uikit-lvt/LvtCrmUIKit/HomeroomPendingJournal.swift \
  ios-uikit-lvt/Tests/HomeroomChecks.swift \
  -o "$scratch/homeroom-checks"
"$scratch/homeroom-checks"
```

Coverage: missing/unknown/wrong-type menu access, legacy edit, manager/view_all/supervisor distinctions, inactive/password-change denial, Vietnam midnight, invalid/leap dates, independent no_data/absence counts, empty years/uploads/classes, the backend 500-row pending cap versus total 501, and malformed-response rejection. These are decoding/policy checks, not UIKit layout or authenticated runtime acceptance.

## L2 readonly class/student source checks

```sh
scratch=$(mktemp -d /Users/vsc_agent/.hermes/cache/scratch/lvt-l2-checks.XXXXXX)
swiftc -module-cache-path "$scratch/cache" \
  ios-uikit-lvt/LvtCrmUIKit/AuthModels.swift \
  ios-uikit-lvt/LvtCrmUIKit/CredentialStore.swift \
  ios-uikit-lvt/LvtCrmUIKit/ConvexHttpClient.swift \
  ios-uikit-lvt/LvtCrmUIKit/HomeroomRepository.swift \
  ios-uikit-lvt/LvtCrmUIKit/HomeroomDetail.swift \
  ios-uikit-lvt/LvtCrmUIKit/HomeroomWrites.swift \
  ios-uikit-lvt/LvtCrmUIKit/HomeroomCameraImport.swift \
  ios-uikit-lvt/LvtCrmUIKit/HomeroomManagement.swift \
  ios-uikit-lvt/LvtCrmUIKit/HomeroomPendingJournal.swift \
  ios-uikit-lvt/Tests/HomeroomDetailChecks.swift \
  -o "$scratch/detail-checks"
"$scratch/detail-checks"
```

The actual Foundation repository/store sources run against offline query fixtures. Covers exact args for all five readonly RPCs; denied class/roster/daily/profile/history queries; refresh revocation and retry; stale student/date completions; wrong identity/date and inverted range rejection; strict malformed decoding; explicit null and unknown-observation `no_data`; 501 history rows without inventing the unrelated pending cap. L2 originally discarded contacts. L3 now decodes profile contacts only when backend `showContacts` is true. `includeSensitiveContacts: false` alone is **not** a redaction guarantee.

## L3 offline writes and contact source checks

```sh
scratch=$(mktemp -d /Users/vsc_agent/.hermes/cache/scratch/lvt-l3-checks.XXXXXX)
TMPDIR="$scratch" swiftc -module-cache-path "$scratch/cache" \
  ios-uikit-lvt/LvtCrmUIKit/{AuthModels,CredentialStore,ConvexHttpClient,HomeroomRepository,HomeroomDetail,HomeroomWrites,HomeroomCameraImport,HomeroomManagement,HomeroomPendingJournal}.swift \
  ios-uikit-lvt/Tests/HomeroomWriteChecks.swift -o "$scratch/write-checks"
"$scratch/write-checks"
```

Android adds `HomeroomWritesTest`. Both use injected offline query/mutation fixtures, not live successful data or production writes. They check fresh denied supervisor/view_all/revoked permissions, raw-absent/date/class/year/student/archived guards, 100/101/deduped atomic batch payloads, contact6/7, validation and exact endpoint args, duplicate/cancelled/stale submits, malformed acknowledgments including the null-return HTTP envelope, definite write failures preserving edit payloads, successful fixture refresh of class/profile/history/overview/pending, and acknowledged-write/readback failure status without retrying writes.

Only `students:updateContacts`, `students:upsertGuardian`, `students:removeGuardian`, `studentAttendance:setDisposition`, and `studentAttendance:setDispositionMany` are added as native homeroom writes. Editors retain invalid edits; denied fresh permission reads clear drafts; uncertain write acknowledgments lock resubmission until explicit read-only refresh. Primary guardian behavior is never optimistically reconstructed.

Android counterparts are `HomeroomDetailTest`, `HomeroomDecodingTest`, and `HomeroomViewModelTest`:

```sh
cd android-app
JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' \
  ./gradlew :app:testDebugUnitTest :app:assembleDebug
```

Fresh unsigned UIKit build (no app launch):

```sh
scratch=$(mktemp -d /Users/vsc_agent/.hermes/cache/scratch/lvt-l2-build.XXXXXX)
xcodebuild -project ios-uikit-lvt/LvtCrmUIKit.xcodeproj -scheme LvtCrmUIKit \
  -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$scratch" CODE_SIGNING_ALLOWED=NO build
```

Read-only policy regression command from repository root:

```sh
node --experimental-strip-types --test tests/homeroom-policy.test.mjs \
  tests/homeroom-routing.test.mjs tests/homeroom-report.test.mjs \
  tests/homeroom-calendar-report.test.mjs tests/attendance-import.test.mjs \
  tests/student-attendance.test.mjs tests/homeroom-class-enrollment.test.mjs
```

No runtime acceptance is claimed by these checks. Do not launch either app against production: automatic device/push registration writes production. Authenticated role/historical access, in-session revocation, rotation, Dynamic Type/font scale, VoiceOver/TalkBack require an owner-approved isolated backend or read-only harness. L6 and later remain out of scope.

## L4 whole-school camera import (offline only)

```sh
scratch=/Users/vsc_agent/.hermes/cache/scratch/lvt-l4
mkdir -p "$scratch"
TMPDIR="$scratch" swiftc -module-cache-path "$scratch/swift-cache" \
  ios-uikit-lvt/LvtCrmUIKit/{AuthModels,CredentialStore,ConvexHttpClient,HomeroomRepository,HomeroomDetail,HomeroomWrites,HomeroomCameraImport,HomeroomManagement,HomeroomPendingJournal}.swift \
  ios-uikit-lvt/Tests/HomeroomCameraImportChecks.swift -o "$scratch/camera-checks"
"$scratch/camera-checks"
```

Tests execute actual Foundation import models/store against deterministic injected RPC/binary fixtures, without credentials or network. Android `HomeroomCameraImportTest` runs with the normal Gradle command above; when sandbox Gradle daemon IPC is blocked, the preserved scratch `manual-android.sh` compiles all actual Kotlin/Compose sources with cached Kotlin 2.0.21/Compose compiler and runs native homeroom JUnit tests. This fallback is not a fresh resource/APK build.

Coverage: bounded reads/provider errors; picker-cancel no side effects; unsupported/empty/oversize/non-ZIP rejection; exact endpoint arguments/kinds; supervisor versus read-only authority; fresh session/year/date before every stage; lost/malformed responses at all five stages; no duplicate/retry/delete; mid-flight revoke/cancel/stale completions; full partial/error/truncated preview; all three conflict modes plus confirmation; explicit concurrent-conflict revalidation; zero/idempotent publication; acknowledgment preserved across failed status refresh; explicit local abandonment of known uncommitted drafts while retaining IDs (no server deletion), never unknown outcomes. Foundation also intercepts actual HTTP requests with an offline URLProtocol and verifies 401/malformed/non-2xx no refresh/replay. Three Android MockWebServer transport tests require local socket permission; compiling them is not running them.

Lifecycle limits: no public staged status/delete/cancel RPC and no proven storage cleanup job. The two-hour TTL does not mean deletion. Unknown outcomes remain locked in the current homeroom screen context and only allow published-list refresh; absence from that list proves nothing. Known storage/upload IDs are retained in memory. There is no durable recovery across process death/sign-out or a newly constructed homeroom controller; do not interpret reopening as permission to retry an uncertain write. Authenticated provider UI/security-scoped coordination (host sandbox blocks NSFileCoordinator IPC), real workbook/backend publishing/correction preservation, accessibility/rotation and transport/process-death recovery remain runtime gates. URLSession has no supported blanket transport-retry-disable switch: native code never retries import RPCs, refreshes/replays authentication for them, or follows redirects; underlying OS transport behavior remains a runtime gate.

## L5 manager catalog, assignments, enrollments and roster XLSX (offline only)

```sh
scratch=/Users/vsc_agent/.hermes/cache/scratch/lvt-l5
mkdir -p "$scratch"
TMPDIR="$scratch" swiftc -module-cache-path "$scratch/swift-cache" \
  ios-uikit-lvt/LvtCrmUIKit/{AuthModels,CredentialStore,ConvexHttpClient,HomeroomRepository,HomeroomDetail,HomeroomWrites,HomeroomCameraImport,HomeroomManagement,HomeroomPendingJournal}.swift \
  ios-uikit-lvt/Tests/HomeroomManagementChecks.swift -o "$scratch/l5-checks"
TMPDIR="$scratch" "$scratch/l5-checks"
node --experimental-strip-types --test tests/student-roster-import.test.mjs \
  tests/homeroom-class-enrollment.test.mjs tests/user-import.test.mjs
```

Android adds `HomeroomManagementTest` to the normal Gradle test/build command above. Scratch `lvt-l5/manual-android.sh` compiles all actual Kotlin/Compose and test sources with cached compiler/resources and runs every non-socket test; it is not a fresh APK build. Source-negative controls exist only in scratch and deliberately bypass manager admission, proving the same tests fail before the real-source GREEN run. Never replace app source with those controls.

Native entry: manager-only **Danh mục / Học sinh** from the existing year/date homeroom screen. Class create/edit/archive/restore, active-user GVCN picker/effective date, student create, server enrollment-ID transfer/withdraw, enrollment history, and native XLSX picker/validate/issues/normalized preview/explicit commit are connected. Refresh uses actual catalog/roster/scoped enrollment/result contracts, not optimistic reconstructed history. Existing L3 contact/disposition authority is unchanged; `students:update` is intentionally not added in L5.

Source admission: `assertClassRosterWritable` calls manager-only `assertCanBulkImportRoster`; assigned-roster maintenance is not bulk-import permission. Supervisor/view_all/GVCN/hidden non-managers cannot catalog or upload. Fresh active/password/owner/year/class checks precede each write, binary upload, and preview presentation. Archive/invalid dates/closed enrollment/year-target mismatch and server overlap errors fail closed. Duplicate taps, wrong envelopes, stale/cancelled completions, uncertainty locks, and acknowledgment/readback failures are injected actual-source tests, not live-success fixtures.

Roster differs from camera: `.xlsx` ≤2 MiB / 200 rows, 1-hour expiry, 16 required named columns, create/merge modes. `generateUploadUrl` takes only classId; `registerUpload` includes storageId/fileName/fileSize/schoolYearId/classId/mode; validateUpload/commit are actions taking only uploadId; getResult returns owned upload and raw row payload/issues. Enrollment begins on server Vietnam commit-today, not selected overview date. Parse rejection legitimately omits mode/columns; it still carries issues/blockers/preview. No client workbook parsing or column remapping is fabricated.

Idempotency: public commit validates first; `storeValidationInternal` rejects committed uploads. `assertImportUploadUsable(forCommit:true)` also rejects committed uploads before the internal alreadyCommitted return. Do not promise repeatable public commit, auto-retry or invent idempotency keys. Uncertain sent writes stay locked even after read-only getResult shows a commit; inspect known IDs, never blindly replay. Explicit abandonment of known staging retains IDs in memory and does not delete server storage. No public lookup by owner/storage, cancel/delete endpoint, or durable recovery is available; expiry is not proof of cleanup. Warnings persist for process death/sign-out/reconstructed controllers. Real workbook persistence/guardian merge/auth revocation/providers/accessibility/rotation remain isolated-runtime gates. No app launch or production requests. L6/L7 not implemented.
