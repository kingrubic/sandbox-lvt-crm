import Foundation

@main struct HomeroomManagementChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ label: String) { checks += 1; precondition(value, label) }
        let classInput: [String: Any] = ["code": "6a1", "name": "Lớp 6A1", "gradeLevel": 6, "notes": "fixture"]
        let student: [String: Any] = ["studentCode": "HS01", "fullName": "Offline student", "startDate": "2026-10-07"]
        let bytes = Data([80,75,3,4,1])
        let readURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"]!).appendingPathComponent("bounded-roster.fixture")
        try Data(repeating: 80, count: 2 * 1024 * 1024 + 20).write(to: readURL)
        check(try CameraImportFile.boundedRead(url: readURL, maxBytes: 2 * 1024 * 1024).count == 2 * 1024 * 1024 + 1, "Actual bounded picker read stops at limit plus sentinel")
        try FileManager.default.removeItem(at: readURL)
        do { _ = try CameraImportFile.boundedRead(url: readURL, maxBytes: 2 * 1024 * 1024); check(false, "Provider missing file accepted") } catch { check(true, "Actual unreadable provider path fails") }
        for (role, access) in [("user", "supervisor"), ("user", "view_all"), ("user", "view"), ("user", "hidden")] {
            let fixture = ManagementFixture(); fixture.role = role; fixture.access = access
            let store = fixture.store()
            await store.refresh()
            await store.mutate("createClass", classId: nil, values: classInput)
            await store.importFile(name: "fixture.xlsx", bytes: bytes, mode: "create")
            check(store.denied && store.classes.isEmpty && store.roster == nil && store.validation == nil, "Negative role clears data")
            check(fixture.writes.isEmpty && fixture.binaries == 0, "Negative role sends nothing")
        }
        for invalid in ["inactive", "password", "missingStatus", "wrongPasswordType"] {
            let fixture = ManagementFixture(); fixture.sessionFault = invalid
            await fixture.store().mutate("createClass", classId: nil, values: classInput)
            check(fixture.writes.isEmpty, "Session fail closed")
        }
        for operation in ["createClass", "updateClass", "archive", "restore", "assign", "createStudent", "transfer", "withdraw"] {
            let fixture = ManagementFixture(); if operation == "restore" { fixture.archived = true }
            let store = fixture.store(); await store.select("class")
            let values: [String: Any]
            switch operation {
            case "createClass", "updateClass": values = classInput
            case "assign": values = ["userId": "teacher", "effectiveFrom": "2026-10-07"]
            case "createStudent": values = student
            case "transfer": values = ["enrollmentId": "enrollment", "toClassId": "target", "date": "2026-10-07", "reason": "fixture"]
            case "withdraw": values = ["enrollmentId": "enrollment", "date": "2026-10-07", "reason": "fixture"]
            default: values = [:]
            }
            await store.mutate(operation, classId: operation == "createClass" ? nil : "class", values: values, studentId: "student")
            check(fixture.writes.count == 1 && store.acknowledgmentCount == 1, "Exact operation acknowledged \(operation)")
            let args = fixture.writes[0].2
            let expectedKeys: Set<String>
            switch operation {
            case "createClass": expectedKeys = ["schoolYearId", "code", "name", "gradeLevel", "notes"]
            case "updateClass": expectedKeys = ["id", "code", "name", "gradeLevel", "notes"]
            case "assign": expectedKeys = ["classId", "userId", "assignmentType", "scopeKind", "effectiveFrom"]
            case "createStudent": expectedKeys = ["classId", "studentCode", "fullName", "startDate"]
            case "transfer": expectedKeys = ["enrollmentId", "toClassId", "date", "reason"]
            case "withdraw": expectedKeys = ["enrollmentId", "date", "reason"]
            default: expectedKeys = ["id"]
            }
            check(Set(args.keys) == expectedKeys, "Exact argument keys \(operation)")
            check(fixture.queries.filter { $0 == "users:sessionContext" }.count >= 3, "Fresh session before write and refresh")
            if operation == "assign" { check(args["assignmentType"] as? String == "homeroom_teacher" && args["scopeKind"] as? String == "class", "Fixed assignment semantics") }
            if operation == "transfer" || operation == "withdraw" { check(fixture.queries.filter { $0 == "students:getScoped" }.count == 2, "Enrollment history read back") }
        }
        for (operation, values) in [("assign", ["userId": "teacher", "effectiveFrom": "2026-02-30"] as [String: Any]), ("createStudent", ["studentCode": "HS", "fullName": "Student", "startDate": "2026-02-30"]), ("withdraw", ["enrollmentId": "enrollment", "date": "2026-08-01"]), ("transfer", ["enrollmentId": "enrollment", "date": "2026-07-31", "toClassId": "target"]), ("transfer", ["enrollmentId": "enrollment", "date": "2026-10-07", "toClassId": "class"]), ("createClass", ["code": "invalid code", "name": "Name", "gradeLevel": 6])] {
            let fixture = ManagementFixture(); let store = fixture.store()
            await store.mutate(operation, classId: "class", values: values, studentId: "student")
            check(fixture.writes.isEmpty && !store.locked, "Invalid input before write \(operation)")
        }
        for operation in ["updateClass", "archive", "assign", "createStudent", "transfer", "withdraw"] {
            let fixture = ManagementFixture(); fixture.archived = true; let store = fixture.store()
            await store.mutate(operation, classId: "class", values: classInput)
            check(fixture.writes.isEmpty, "Archived class misuse blocked")
        }
        for code in ["DUPLICATE_ACTIVE_ENROLLMENT", "HOMEROOM_TEACHER_OVERLAP", "IMPORT_VALIDATION_FAILED", "CLASS_CODE_TAKEN"] {
            let fixture = ManagementFixture(); fixture.failCode = code; fixture.failStage = "homeroomClasses:create"; let store = fixture.store()
            await store.mutate("createClass", classId: nil, values: classInput)
            check(!store.locked && store.message.contains(code) && fixture.writes.count == 1, "Definite backend conflict surfaced")
        }
        let malformed = ManagementFixture(); malformed.badAck = true; let malformedStore = malformed.store()
        await malformedStore.mutate("createClass", classId: nil, values: classInput)
        await malformedStore.mutate("createClass", classId: nil, values: classInput)
        check(malformedStore.locked && malformed.writes.count == 1, "Wrong acknowledgment locks duplicate write")
        let readback = ManagementFixture(); readback.failReadAfterAck = true; let readbackStore = readback.store()
        await readbackStore.mutate("createClass", classId: nil, values: classInput)
        check(readbackStore.acknowledgmentCount == 1 && readbackStore.message.contains("đã xác nhận") && readback.writes.count == 1, "Ack survives failed readback")
        for mode in ["create", "merge"] {
            let fixture = ManagementFixture(); let store = fixture.store(); await store.select("class")
            await store.importFile(name: "fixture.xlsx", bytes: bytes, mode: mode)
            check(store.canCommit && store.uploadId == "upload" && store.storageId == "storage", "Actual roster preview/result decoded")
            check(fixture.writes.map { $0.1 } == ["studentRosterImport:generateUploadUrl", "studentRosterImport:registerUpload", "studentRosterImport:validateUpload"], "Exact endpoints not camera")
            check(Set(fixture.writes[0].2.keys) == ["classId"] && Set(fixture.writes[1].2.keys) == ["storageId", "fileName", "fileSize", "schoolYearId", "classId", "mode"], "Exact upload args")
            check(fixture.writes[1].2["mode"] as? String == mode && fixture.writes[2].0 == "action", "Mode and action")
            check(fixture.queries.filter { $0 == "users:sessionContext" }.count == 6, "Fresh permission before binary and every stage and preview")
            await store.commit(confirmed: false); check(fixture.writes.count == 3, "Explicit confirm mandatory")
            await store.commit(confirmed: true); await store.commit(confirmed: true)
            check(fixture.writes.count == 4 && store.committed && store.validation == nil && store.uploadStatus == "committed", "Commit once authoritative refreshed state")
            check(Set(fixture.writes.last!.2.keys) == ["uploadId"], "No roster date/idempotency invented")
            store.discardKnown(); check(store.retiredIds == ["upload", "storage"] && store.canPick, "Only known local reset preserves IDs")
        }
        for fault in ["zero", "already", "commitReadFailure"] {
            let fixture = ManagementFixture(); fixture.importFault = fault; let store = fixture.store(); await store.select("class")
            await store.importFile(name: "fixture.xlsx", bytes: bytes, mode: "create"); await store.commit(confirmed: true)
            if fault == "already" { check(store.locked && !store.committed, "Unexpected internal alreadyCommitted envelope is not public success") }
            else { check(store.committed && store.acknowledgmentCount == 1, "Zero commit or failed readback acknowledgment preserved") }
            let count = fixture.writes.count; await store.commit(confirmed: true); check(fixture.writes.count == count, "No commit replay")
        }
        for code in ["CLASS_CODE_TAKEN", "DUPLICATE_ACTIVE_ENROLLMENT", "IMPORT_VALIDATION_FAILED", "IMPORT_UPLOAD_ALREADY_COMMITTED", "ENROLLMENT_YEAR_MISMATCH"] { check(ConvexHttpClient.extractImportCode("Uncaught Error: \(code) at handler") == code, "Exact safe backend error extraction") }
        for invalid in [Data(), Data([1,2,3,4]), Data(repeating: 80, count: 2 * 1024 * 1024 + 1)] {
            let fixture = ManagementFixture(); let store = fixture.store(); await store.select("class")
            await store.importFile(name: "fixture.xlsx", bytes: invalid, mode: "create")
            check(fixture.writes.isEmpty && fixture.binaries == 0, "Invalid file sends nothing")
        }
        for stage in ["studentRosterImport:generateUploadUrl", "binary", "studentRosterImport:registerUpload", "studentRosterImport:validateUpload", "studentRosterImport:commit"] {
            let fixture = ManagementFixture(); fixture.failStage = stage; let store = fixture.store(); await store.select("class")
            await store.importFile(name: "fixture.xlsx", bytes: bytes, mode: "create")
            await store.commit(confirmed: true)
            let sentCount = fixture.writes.count
            await store.importFile(name: "fixture.xlsx", bytes: bytes, mode: "create"); await store.commit(confirmed: true); store.discardKnown()
            check(store.locked && fixture.writes.count == sentCount, "Unknown stage locked no retry \(stage)")
            await store.refresh(classId: "class"); check(store.locked && fixture.writes.count == sentCount, "Read-only recovery never unlocks \(stage)")
        }
        for fault in ["parse", "rows", "wrongEnvelope", "wrongOwner", "expired", "wrongClass", "wrongYear"] {
            let fixture = ManagementFixture(); fixture.importFault = fault; let store = fixture.store(); await store.select("class")
            await store.importFile(name: "fixture.xlsx", bytes: bytes, mode: "create")
            if ["parse", "rows"].contains(fault) { check(!store.canCommit && !store.locked && store.validation?.issues.count == 1, "Genuine validation rejection not unknown") }
            else if fault == "expired" { check(!store.canCommit && !store.locked, "Expired import cannot commit") }
            else { check(!store.canCommit && store.validation == nil || store.locked || store.uploadStatus == nil, "Wrong result/preview cannot commit") }
            await store.commit(confirmed: true); check(!fixture.writes.contains { $0.1 == "studentRosterImport:commit" }, "Invalid commit not sent")
        }
        let duplicate = ManagementFixture(); duplicate.suspendWrite = true; let duplicateStore = duplicate.store()
        let first = Task { await duplicateStore.mutate("createClass", classId: nil, values: classInput) }
        while duplicate.continuation == nil { await Task.yield() }
        await duplicateStore.mutate("createClass", classId: nil, values: classInput)
        check(duplicate.writes.count == 1 && duplicateStore.busy, "Concurrent duplicate tap suppressed")
        duplicate.current = false; duplicate.continuation?.resume(returning: ["value": "id"]); await first.value
        check(duplicateStore.locked && duplicateStore.classes.isEmpty && duplicateStore.acknowledgmentCount == 0, "Stale completion discarded")
        let revoke = ManagementFixture(); revoke.revokeAfterWrite = true; let revokeStore = revoke.store(); await revokeStore.select("class")
        await revokeStore.importFile(name: "fixture.xlsx", bytes: bytes, mode: "create")
        check(revokeStore.denied && revoke.binaries == 0 && revoke.writes.count == 1, "Permission revoked before binary")
        for boundary in 2...8 {
            let fixture = ManagementFixture(); fixture.revokeAtSession = boundary; let store = fixture.store(); await store.select("class")
            await store.importFile(name: "fixture.xlsx", bytes: bytes, mode: "create"); await store.commit(confirmed: true)
            check(store.denied && fixture.writes.count == [0, 1, 1, 2, 3, 3, 3][boundary - 2], "Fresh revocation stops exact write boundary \(boundary)")
            check(store.roster == nil && store.validation == nil && store.history.isEmpty, "Fresh denial clears sensitive data")
        }
        let history = ManagementFixture(); let historyStore = history.store(); await historyStore.showHistory(studentId: "student")
        check(historyStore.history.count == 1 && historyStore.history[0].contains("2026-08-01"), "Real read-only enrollment history retained")
        let canceled = ManagementFixture(); canceled.suspendWrite = true; let canceledStore = canceled.store()
        let canceledTask = Task { await canceledStore.mutate("createClass", classId: nil, values: classInput) }
        while canceled.continuation == nil { await Task.yield() }
        canceledTask.cancel(); canceled.continuation?.resume(returning: ["value": "id"]); await canceledTask.value
        check(canceledStore.locked && canceledStore.acknowledgmentCount == 0, "Cancellation of sent write remains uncertain")
        for path in ["homeroomClasses:create", "homeroomClasses:assignUser", "homeroomClasses:transferStudent", "students:create", "studentRosterImport:generateUploadUrl"] {
            try ConvexHttpClient.validateImportEnvelope(path, envelope: ["status": "success", "value": "id"], statusCode: 200); check(true, "String envelope")
            do { try ConvexHttpClient.validateImportEnvelope(path, envelope: ["status": "success", "value": [:]], statusCode: 200); check(false, "Wrong string envelope") } catch { check(true, "Rejected") }
        }
        for path in ["homeroomClasses:update", "homeroomClasses:archive", "homeroomClasses:restore", "homeroomClasses:withdrawStudent"] {
            try ConvexHttpClient.validateImportEnvelope(path, envelope: ["status": "success", "value": NSNull()], statusCode: 200); check(true, "Null envelope")
            for envelope in [["status": "success"], ["status": "success", "value": [:]]] as [[String: Any]] { do { try ConvexHttpClient.validateImportEnvelope(path, envelope: envelope, statusCode: 200); check(false, "Missing/wrong null accepted") } catch { check(true, "Rejected") } }
        }
        check(HomeroomManagementStore.lifecycle.contains("1 giờ") && HomeroomManagementStore.lifecycle.contains("KHÔNG") && HomeroomManagementStore.columns.split(separator: ",").count == 16, "Honest lifecycle and mappings")
        print("L5 PASS \(checks) actual-source offline assertions")
    }
}

@MainActor private final class ManagementFixture {
    var role = "admin", access = "hidden", sessionFault = "", failStage = "", failCode = "L5_UNCERTAIN", importFault = ""
    var archived = false, current = true, badAck = false, failReadAfterAck = false, suspendWrite = false, revokeAfterWrite = false
    var binaries = 0, committed = false
    var revokeAtSession = Int.max
    var writes: [(String, String, [String: Any])] = []
    var queries: [String] = []
    var continuation: CheckedContinuation<[String: Any], Never>?
    func store() -> HomeroomManagementStore {
        HomeroomManagementStore(yearId: "year", date: "2026-10-07", query: query, write: write, binary: { _, _ in self.binaries += 1; if self.failStage == "binary" { throw ConvexException(code: self.failCode) }; return "storage" }, isCurrent: { self.current })
    }
    func query(_ path: String, _ args: [String: Any]) async throws -> [String: Any] {
        queries.append(path)
        if failReadAfterAck && !writes.isEmpty { throw ConvexException(code: "OFFLINE_READ_FAILURE") }
        switch path {
        case "users:sessionContext":
            var user: [String: Any] = ["_id": "owner", "status": "active", "mustChangePassword": false, "role": role]
            if sessionFault == "inactive" { user["status"] = "inactive" }; if sessionFault == "password" { user["mustChangePassword"] = true }; if sessionFault == "missingStatus" { user.removeValue(forKey: "status") }; if sessionFault == "wrongPasswordType" { user["mustChangePassword"] = "false" }
            if revokeAfterWrite && !writes.isEmpty || queries.filter({ $0 == "users:sessionContext" }).count >= revokeAtSession { user["role"] = "user" }
            return ["user": user, "menuAccess": ["homeroom": access]]
        case "schoolYears:list": return ["items": [["_id": "year", "name": "2026–2027", "startDate": "2026-08-01", "endDate": "2027-06-01", "active": true]]]
        case "homeroomClasses:listCatalog": return ["items": [klass("class", archived), klass("target", false)]]
        case "homeroomClasses:listAssignmentCandidates": return ["items": [["_id": "teacher", "name": "Offline teacher", "role": "user"]]]
        case "students:listByClass": return ["showContacts": false, "rows": [["enrollment": ["_id": "enrollment", "startDate": "2026-08-01"], "student": ["_id": "student", "studentCode": "HS01", "fullName": "Offline student"]]]]
        case "students:getScoped": return ["student": ["_id": "student"], "enrollments": [["_id": "enrollment", "classId": "class", "status": "active", "startDate": "2026-08-01"]]]
        case "studentRosterImport:getResult": return ["upload": ["_id": "upload", "uploadedBy": importFault == "wrongOwner" ? "other" : "owner", "classId": importFault == "wrongClass" ? "target" : "class", "schoolYearId": importFault == "wrongYear" ? "other" : "year", "status": committed ? "committed" : ["parse", "rows"].contains(importFault) ? "rejected" : "validated", "expiresAt": Date().timeIntervalSince1970 * 1000 + (importFault == "expired" ? -1 : 3600000)], "rows": []]
        default: throw ConvexException(code: "UNEXPECTED_OFFLINE_QUERY")
        }
    }
    func klass(_ id: String, _ archived: Bool) -> [String: Any] { ["_id": id, "schoolYearId": "year", "code": "6A1", "name": "Fixture class", "status": archived ? "archived" : "active", "gradeLevel": 6, "rosterCount": 1, "currentHomeroomTeacher": NSNull(), "upcomingHomeroomTeacher": NSNull()] }
    func write(_ kind: String, _ path: String, _ args: [String: Any]) async throws -> [String: Any] {
        writes.append((kind, path, args))
        if path == failStage { throw ConvexException(code: failCode) }
        if suspendWrite { return await withCheckedContinuation { continuation = $0 } }
        if badAck { return ["ok": true] }
        switch path {
        case "studentRosterImport:generateUploadUrl": return ["value": "https://offline.invalid/upload"]
        case "studentRosterImport:registerUpload": return ["uploadId": "upload", "expiresAt": Date().timeIntervalSince1970 * 1000 + (importFault == "expired" ? -1 : 3600000)]
        case "studentRosterImport:validateUpload":
            if importFault == "wrongEnvelope" { return ["ok": true, "uploadId": "upload", "classes": []] }
            let issue: [String: Any] = ["rowNumber": 0, "field": "file", "column": "", "code": "INVALID_IMPORT_FILE", "message": "Offline rejected file", "severity": "error"]
            if importFault == "parse" { return ["ok": false, "issues": [issue], "blockers": [issue], "preview": []] }
            return ["ok": importFault != "rows", "issues": importFault == "rows" ? [issue] : [], "blockers": importFault == "rows" ? [issue] : [], "preview": importFault == "rows" ? [] : [["rowNumber": 2, "studentCode": "HS01", "fullName": "Offline student"]], "mode": writes.first(where: { $0.1 == "studentRosterImport:registerUpload" })!.2["mode"]!, "columns": HomeroomManagementStore.columns.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }]
        case "studentRosterImport:commit":
            if importFault == "already" { return ["uploadId": "upload", "alreadyCommitted": true] }
            committed = true; if importFault == "commitReadFailure" { failReadAfterAck = true }
            return ["uploadId": "upload", "committed": true, "count": importFault == "zero" ? 0 : 1]
        case "homeroomClasses:create", "homeroomClasses:assignUser", "homeroomClasses:transferStudent", "students:create": return ["value": "fixture-id"]
        default: return [:]
        }
    }
}
