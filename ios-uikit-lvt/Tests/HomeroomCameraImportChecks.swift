import Foundation

private final class OfflineImportProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var statusCode = 401
    nonisolated(unsafe) static var responseBody = ""
    private static let lock = NSLock()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var recorded = request
        if recorded.httpBody == nil, let stream = recorded.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                bytes.append(contentsOf: buffer.prefix(count))
            }
            recorded.httpBody = bytes
        }
        Self.lock.lock(); Self.requests.append(recorded); let status = Self.statusCode; let body = Self.responseBody; Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
private final class Fixture {
    var access = "supervisor"
    var role = "user"
    var actor = "actor"
    var active = true
    var password = false
    var current = true
    var conflict = false
    var fail: String?
    var malformed: String?
    var error: Error = URLError(.networkConnectionLost)
    var statusFails = false
    var duringBinary: (() async -> Void)?
    var duringWrite: ((String) async -> Void)?
    var calls: [(String, [String: Any])] = []
    var writes: [(String, [String: Any])] = []
    var ack: [String: Any] = ["importId": "upload", "published": true, "count": 0, "classCount": 0, "skippedClassCodes": [String]()]
    static func preview(conflict: Bool = false) -> [String: Any] {
        ["uploadId": "upload", "attendanceDate": "2026-10-06", "fileName": "camera.xlsx", "sheetName": "Sheet1", "ok": false, "totalRows": 2, "matchedCount": 1, "errorCount": 1, "warningCount": 1, "issuesTruncated": true,
         "issues": [["rowNumber": 3, "field": "name", "column": "Họ tên", "rejectedValue": NSNull(), "code": "UNMATCHED", "message": "Không khớp", "severity": "error"]],
         "classes": [["classId": "class", "code": "10A", "name": "Lớp 10A", "rowCount": 1, "matchedCount": 1, "present": 1, "late": 0, "absent": 0, "rosterCount": 2, "missingCount": 1, "errorCount": 0, "warningCount": 1, "publishable": true, "alreadyPublished": conflict]],
         "classesWithoutRows": [["classId": "empty", "code": "10B", "name": "Lớp 10B", "alreadyPublished": false]],
         "schoolDay": ["isSchoolDay": true, "kind": "school_day", "note": "", "outsideYear": false]]
    }
    func query(_ path: String, _ args: [String: Any]) throws -> [String: Any] {
        calls.append((path, args)); if fail == path { throw error }
        switch path {
        case "users:sessionContext": return ["user": ["_id": actor, "role": role, "status": active ? "active" : "disabled", "mustChangePassword": password], "menuAccess": ["homeroom": access]]
        case "schoolYears:list": return ["items": [["_id": "year", "name": "2026", "startDate": "2026-08-01", "endDate": "2027-06-01", "active": true]]]
        case "attendanceImport:uploadsForDate": if statusFails { throw URLError(.timedOut) }; return ["publishedClassCount": 0, "uploads": [Any]()]
        default: throw ConvexException(code: "UNEXPECTED_QUERY")
        }
    }
    lazy var store = makeStore()
    func makeStore(date: String = "2026-10-06", year: String = "year") -> CameraImportStore {
        CameraImportStore(yearId: year, date: date, query: { path, args in try self.query(path, args) }, write: { kind, path, args in
            guard kind == (path.hasSuffix("validate") ? "action" : "mutation") else { throw ConvexException(code: "WRONG_KIND") }
            self.calls.append((path, args)); self.writes.append((path, args))
            await self.duringWrite?(path)
            if self.fail == path { throw self.error }
            if self.malformed == path { return [:] }
            switch path {
            case "attendanceImport:generateUploadUrl": return ["value": "https://offline.invalid/upload"]
            case "attendanceImport:registerUpload": return ["uploadId": "upload"]
            case "attendanceImport:validate": return Self.preview(conflict: self.conflict)
            case "attendanceImport:publish": return self.ack
            default: throw ConvexException(code: "UNEXPECTED_WRITE")
            }
        }, binary: { url, data in
            guard url == "https://offline.invalid/upload", data == Data([80, 75, 3, 4]) else { throw ConvexException(code: "WRONG_BINARY") }
            self.calls.append(("binary", [:])); await self.duringBinary?()
            if self.fail == "binary" { throw self.error }
            return self.malformed == "binary" ? "" : "storage"
        }, isCurrent: { self.current })
    }
    func select() async { await store.select(name: "camera.xlsx", data: Data([80, 75, 3, 4])) }
}

@main
struct HomeroomCameraImportChecks {
    @MainActor static var assertions = 0
    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        assertions += 1
        if !condition() { throw NSError(domain: message, code: assertions) }
    }
    static func fails(_ operation: () throws -> Void) -> Bool { do { try operation(); return false } catch { return true } }
    @MainActor static func main() async throws {
        try CameraImportFile.validate(name: "camera.xlsx", data: Data([80, 75, 3, 4]))
        for (name, data) in [("camera.xls", Data([80, 75, 3, 4])), ("camera.xlsx", Data()), ("camera.xlsx", Data([1, 2, 3, 4])), ("camera.xlsx", Data(repeating: 0, count: CameraImportFile.maxBytes + 1))] {
            try check(fails { try CameraImportFile.validate(name: name, data: data) }, "file guard")
        }
        let scratch = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"]!)
        let oversized = scratch.appendingPathComponent("oversized-fixture.xlsx")
        try Data(repeating: 0, count: CameraImportFile.maxBytes + 20).write(to: oversized)
        let read = try CameraImportFile.boundedRead(url: oversized)
        try check(read.count == CameraImportFile.maxBytes + 1, "bounded provider read")
        try check(fails { _ = try CameraImportFile.boundedRead(url: scratch.appendingPathComponent("missing-fixture.xlsx")) }, "provider read failure")
        let cancelled = Fixture()
        await cancelled.store.picked(name: nil, data: nil)
        try check(cancelled.calls.isEmpty && !cancelled.store.busy && cancelled.store.uploadId == nil, "picker cancel no side effects")
        await cancelled.store.select(name: "camera.xls", data: Data([80, 75, 3, 4]))
        try check(cancelled.calls.isEmpty && !cancelled.store.locked, "invalid file before query")
        let fixture = Fixture(); await fixture.select()
        try check(fixture.writes.map(\.0) == ["attendanceImport:generateUploadUrl", "attendanceImport:registerUpload", "attendanceImport:validate"], "exact writes no implicit publish")
        let register = fixture.writes[1].1
        try check(Set(register.keys) == Set(["storageId", "fileName", "fileSize", "schoolYearId", "attendanceDate"]), "register shape")
        try check(register["storageId"] as? String == "storage" && register["fileSize"] as? Int == 4 && register["attendanceDate"] as? String == "2026-10-06", "register values")
        try check(Set(fixture.writes[2].1.keys) == Set(["uploadId"]), "validate shape")
        try check(fixture.calls.filter { $0.0 == "users:sessionContext" }.count == 5, "fresh authorization each stage and preview readback")
        try check(fixture.store.preview?.ok == false && fixture.store.preview?.classes.first?.publishable == true, "partial preview is publishable")
        try check(fixture.store.preview?.issuesTruncated == true && fixture.store.preview?.issues.first?.rejectedValue == nil && fixture.store.preview?.classesWithoutRows.count == 1, "full errors and omitted classes")
        try check(fixture.calls.allSatisfy { !$0.0.hasPrefix("students:") && !$0.0.hasPrefix("homeroomReports:") && !$0.0.hasPrefix("studentAttendance:") }, "supervisor authority isolation")
        for access in ["view_all", "view", "hidden", "edit", "unknown"] {
            let denied = Fixture(); denied.access = access; await denied.select()
            try check(denied.writes.isEmpty && denied.store.locked, "deny \(access)")
        }
        for kind in 0...1 {
            let denied = Fixture(); if kind == 0 { denied.active = false } else { denied.password = true }; await denied.select()
            try check(denied.writes.isEmpty && denied.store.locked, "account gate")
        }
        for role in ["admin", "moderator"] { let manager = Fixture(); manager.role = role; manager.access = "hidden"; await manager.select(); try check(manager.store.preview != nil, "manager import") }
        for stage in ["attendanceImport:generateUploadUrl", "binary", "attendanceImport:registerUpload", "attendanceImport:validate", "attendanceImport:publish"] {
            for malformed in [false, true] {
                let failure = Fixture(); if stage.hasSuffix("publish") { await failure.select() }
                if malformed { failure.malformed = stage } else { failure.fail = stage }
                if stage.hasSuffix("publish") { await failure.store.publish(mode: nil, confirmed: true) } else { await failure.select() }
                try check(failure.store.locked && failure.store.preview == nil, "unknown \(stage) malformed=\(malformed)")
                let count = failure.calls.filter { $0.0 == stage }.count
                await failure.select(); await failure.store.refreshPreview(); await failure.store.publish(mode: nil, confirmed: true)
                try check(count == 1 && failure.calls.filter { $0.0 == stage }.count == 1, "no retry \(stage)")
                try check(failure.calls.allSatisfy { !$0.0.localizedCaseInsensitiveContains("delete") && !$0.0.localizedCaseInsensitiveContains("cleanup") }, "no invented cleanup")
            }
        }
        for (stage, code) in [("attendanceImport:registerUpload", "INVALID_IMPORT_FILE"), ("attendanceImport:validate", "ATTENDANCE_TEMPLATE_HEADER_NOT_FOUND"), ("attendanceImport:validate", "IMPORT_UPLOAD_EXPIRED"), ("attendanceImport:validate", "IMPORT_TOO_MANY_ROWS")] {
            let failure = Fixture(); failure.fail = stage; failure.error = ConvexException(code: code); await failure.select()
            try check(failure.store.locked == (code == "IMPORT_UPLOAD_EXPIRED") && failure.store.message.contains(code), "explicit source rejection \(code)")
        }
        let revoked = Fixture(); revoked.duringBinary = { revoked.access = "view_all" }; await revoked.select()
        try check(revoked.writes.count == 1 && revoked.store.locked, "revoke before register")
        let revokedPreview = Fixture(); revokedPreview.duringWrite = { path in if path.hasSuffix("validate") { revokedPreview.access = "view_all" } }; await revokedPreview.select()
        try check(revokedPreview.store.preview == nil && revokedPreview.store.locked, "revoke before showing preview")
        let stale = Fixture(); stale.duringWrite = { path in if path.hasSuffix("validate") { stale.store.invalidate() } }; await stale.select()
        try check(stale.store.preview == nil && stale.store.locked && stale.writes.count == 3, "stale validate cannot publish")
        let duplicate = Fixture(); duplicate.duringBinary = { await duplicate.select() }; await duplicate.select()
        try check(duplicate.writes.count == 3, "duplicate tap guard")
        let cancelledRequest = Fixture(); cancelledRequest.fail = "binary"; cancelledRequest.error = CancellationError(); await cancelledRequest.select()
        try check(cancelledRequest.store.locked && cancelledRequest.writes.count == 1, "inflight cancellation uncertain")
        let actorChange = Fixture(); await actorChange.select(); actorChange.actor = "other"; await actorChange.store.publish(mode: nil, confirmed: true)
        try check(actorChange.store.preview == nil && actorChange.writes.count == 3, "actor identity bound")
        for mode in CameraImportStore.modes {
            let conflict = Fixture(); conflict.conflict = true; await conflict.select()
            await conflict.store.publish(mode: nil, confirmed: true); await conflict.store.publish(mode: "replace", confirmed: true); await conflict.store.publish(mode: mode, confirmed: false)
            try check(conflict.writes.count == 3, "explicit mode and confirmation required")
            await conflict.store.publish(mode: mode, confirmed: true)
            try check(conflict.writes.last?.1["replaceMode"] as? String == mode && Set(conflict.writes.last!.1.keys) == Set(["uploadId", "replaceMode"]), "correction preserving wire \(mode)")
            try check(conflict.store.locked && conflict.store.message.hasPrefix("Đã xác nhận"), "zero change acknowledged")
        }
        let concurrent = Fixture(); await concurrent.select(); concurrent.fail = "attendanceImport:publish"; concurrent.error = ConvexException(code: "ATTENDANCE_REPLACE_MODE_REQUIRED")
        await concurrent.store.publish(mode: nil, confirmed: true)
        try check(!concurrent.store.locked && concurrent.store.preview == nil, "conflict clears old preview")
        concurrent.fail = nil; concurrent.conflict = true; await concurrent.store.refreshPreview()
        try check(concurrent.store.preview?.conflicts == true && concurrent.writes.filter { $0.0.hasSuffix("publish") }.count == 1, "explicit revalidation no auto publish")
        let failedStatus = Fixture(); await failedStatus.select(); failedStatus.statusFails = true; await failedStatus.store.publish(mode: nil, confirmed: true)
        try check(failedStatus.store.message.hasPrefix("Đã xác nhận") && failedStatus.store.message.contains("Không tải"), "ack survives status failure")
        await failedStatus.store.publish(mode: nil, confirmed: true); await failedStatus.store.refreshStatus()
        try check(failedStatus.writes.filter { $0.0.hasSuffix("publish") }.count == 1, "ack never republished")
        let published = Fixture(); await published.select(); published.duringWrite = { path in if path.hasSuffix("publish") { published.store.invalidate() } }; await published.store.publish(mode: nil, confirmed: true)
        try check(published.store.message.hasPrefix("Đã xác nhận"), "ack retained after stale completion")
        let idempotent: [String: Any] = ["importId": "u", "published": true, "count": 0, "classCount": 0, "idempotent": true]
        let receipt = try CameraImportStore.receipt(idempotent, id: "u")
        try check(receipt.contains("0 thay đổi"), "idempotent accepted")
        for (key, wrong) in [("published", 1 as Any), ("count", true as Any), ("count", 0.5 as Any), ("count", -1 as Any), ("importId", "other" as Any), ("idempotent", "yes" as Any)] {
            var bad = idempotent; bad[key] = wrong
            try check(fails { _ = try CameraImportStore.receipt(bad, id: "u") }, "strict receipt \(key)")
        }
        for field in ["classes", "issues", "schoolDay", "classesWithoutRows", "totalRows", "ok", "issuesTruncated"] {
            var bad = Fixture.preview(); bad[field] = "bad"
            try check(fails { _ = try CameraPreview.decode(bad, id: "upload", date: "2026-10-06") }, "strict preview \(field)")
        }
        try check(fails { _ = try CameraPreview.decode(Fixture.preview(), id: "other", date: "2026-10-06") }, "wrong preview id")
        try check(fails { _ = try CameraPreview.decode(Fixture.preview(), id: "upload", date: "2026-10-05") }, "wrong preview date")
        for date in ["2026-02-30", "2026-07-31", "2027-10-01", "2027-06-01"] {
            let bad = Fixture(); let store = bad.makeStore(date: date); await store.select(name: "camera.xlsx", data: Data([80, 75, 3, 4]))
            try check(bad.writes.isEmpty && store.message.contains("INVALID_IMPORT_CONTEXT"), "fresh date \(date)")
        }
        let wrongYear = Fixture(); let store = wrongYear.makeStore(year: "missing"); await store.select(name: "camera.xlsx", data: Data([80, 75, 3, 4]))
        try check(wrongYear.writes.isEmpty, "fresh year existence")
        for code in ["ATTENDANCE_REPLACE_MODE_REQUIRED", "ATTENDANCE_TEMPLATE_COLUMNS_MISSING", "IMPORT_UPLOAD_EXPIRED", "IMPORT_ROWS_UNRESOLVED", "SUPERVISOR_REQUIRED", "SCHOOL_YEAR_NOT_FOUND"] {
            try check(ConvexHttpClient.extractImportCode("Uncaught Error: \(code):classCode at handler") == code, "real wrapped source errors")
        }
        let restart = Fixture(); await restart.select(); await restart.store.publish(mode: nil, confirmed: true)
        try check(restart.store.canStartNew, "ack allows separate new file")
        restart.store.newFile(); try check(restart.store.uploadId == nil && restart.store.storageId == nil && !restart.store.locked, "new file resets only local draft")
        restart.fail = "binary"; await restart.select(); restart.store.newFile()
        try check(!restart.store.canStartNew && restart.store.locked, "unknown cannot restart")
        for code in [nil, "ATTENDANCE_TEMPLATE_COLUMNS_MISSING", "IMPORT_UPLOAD_EXPIRED"] as [String?] {
            let abandoned = Fixture(); if let code { abandoned.fail = "attendanceImport:validate"; abandoned.error = ConvexException(code: code) }; await abandoned.select()
            try check(abandoned.store.canStartNew, "known draft can abandon locally")
            let count = abandoned.calls.count; abandoned.store.newFile()
            try check(abandoned.calls.count == count && !abandoned.store.locked && abandoned.store.uploadId == nil, "local abandonment no server writes")
            try check(abandoned.store.previousUploads.first?.contains("upload") == true && abandoned.store.previousUploads.first?.contains("chưa xác nhận công bố") == true, "retained draft IDs and honest lifecycle")
        }
        let statusRevoked = Fixture(); await statusRevoked.select(); statusRevoked.access = "view_all"; await statusRevoked.store.refreshStatus()
        try check(statusRevoked.store.preview == nil && statusRevoked.store.locked, "revoked read clears preview")
        try ConvexHttpClient.validateImportEnvelope("attendanceImport:generateUploadUrl", envelope: ["status": "success", "value": "https://offline.invalid"], statusCode: 200)
        try ConvexHttpClient.validateImportEnvelope("attendanceImport:publish", envelope: ["status": "success", "value": [String: Any]()], statusCode: 200)
        for value in [NSNull(), false, 1, "wrong", [Any]()] as [Any] {
            try check(fails { try ConvexHttpClient.validateImportEnvelope("attendanceImport:publish", envelope: ["status": "success", "value": value], statusCode: 200) }, "HTTP exact result type")
        }
        try check(fails { try ConvexHttpClient.validateImportEnvelope("attendanceImport:publish", envelope: ["status": "success", "value": [String: Any]()], statusCode: 500) }, "HTTP non2xx uncertainty")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineImportProtocol.self]
        let offlineSession = URLSession(configuration: configuration)
        defer { offlineSession.invalidateAndCancel() }
        let http = ConvexHttpClient(baseURL: "https://offline.invalid", tokenProvider: { "offline-token" }, refreshCredentialsProvider: { CredentialSnapshot(accessToken: "offline-token", refreshToken: "offline-refresh", revision: 0) }, onTokensRefreshed: { _, _, _ in false }, sessionOverride: offlineSession)
        for (kind, path, status, body) in [("mutation", "attendanceImport:publish", 401, "{\"status\":\"error\",\"errorMessage\":\"Unauthenticated\"}"), ("action", "attendanceImport:validate", 200, "{\"status\":\"success\",\"value\":null}"), ("mutation", "attendanceImport:registerUpload", 503, "{\"status\":\"success\",\"value\":{}}") ] {
            OfflineImportProtocol.requests = []; OfflineImportProtocol.statusCode = status; OfflineImportProtocol.responseBody = body
            var failure = false
            do { _ = try await http.importCall(kind, path: path, args: ["uploadId": "offline-upload"]) } catch { failure = true }
            try check(failure && OfflineImportProtocol.requests.count == 1, "actual HTTP no replay/refresh on \(status)")
            let request = OfflineImportProtocol.requests[0]
            try check(request.url?.path == "/api/\(kind)" && request.value(forHTTPHeaderField: "Authorization") == "Bearer offline-token", "actual HTTP authenticated endpoint")
            guard let body = request.httpBody else { throw NSError(domain: "Missing actual serialized body", code: 1) }
            let envelope = try JSONSerialization.jsonObject(with: body) as! [String: Any]
            try check(envelope["path"] as? String == path && (envelope["args"] as? [String: String]) == ["uploadId": "offline-upload"], "actual serialized args")
        }
        print("L4 actual Foundation source: \(assertions) assertions PASS; offline only")
    }
}
