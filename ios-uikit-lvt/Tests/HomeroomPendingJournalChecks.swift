import Foundation

@main
struct HomeroomPendingJournalChecks {
    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"]!).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        func journal(_ lane: String = "camera", year: String = "year") -> HomeroomPendingJournal {
            HomeroomPendingJournal(directory: directory, lane: lane, year: year, date: "2026-10-07")
        }
        func blocked(_ operation: () throws -> Void) {
            do { try operation(); fatalError("Recovered operation was allowed") } catch {}
        }
        func check(_ value: @autoclosure () throws -> Bool) throws {
            let result = try value()
            precondition(result)
        }
        let original = journal()
        blocked { try original.before("publish", [:]) }
        try check(original.restore("owner") == nil)
        try original.before("registerUpload", [:])
        try original.received(["uploadId": "upload", "storageId": "storage"])
        let recovered = journal(year: "other-year")
        let marker = try recovered.restore("owner")!
        precondition(marker["year"] as? String == "year")
        precondition(marker["uploadId"] as? String == "upload")
        precondition(marker["storageId"] as? String == "storage")
        try check(recovered.restore("owner") != nil)
        blocked { try recovered.before("publish", [:]) }
        blocked { try recovered.clear() }
        blocked { try recovered.received(["uploadId": "replacement"]) }
        blocked { _ = try recovered.restore("different-owner") }
        try check(journal().restore("different-owner") == nil)
        try check(journal("management").restore("owner") == nil)
        try original.clear()
        try check(journal().restore("owner") == nil)

        try original.before("publish", [:])
        let target = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first!
        try Data("broken-json".utf8).write(to: target)
        let corrupt = journal()
        blocked { _ = try corrupt.restore("owner") }
        blocked { _ = try corrupt.restore("owner") }
        blocked { try corrupt.before("publish", [:]) }
        blocked { try corrupt.clear() }

        var writes = 0
        let query: CameraImportStore.RPC = { path, _ in
            switch path {
            case "users:sessionContext": return ["user": ["_id": "owner", "role": "admin", "status": "active", "mustChangePassword": false], "menuAccess": ["homeroom": "manage"]]
            case "schoolYears:list": return ["items": [["_id": "year", "name": "2026", "startDate": "2026-08-01", "endDate": "2027-06-01", "active": true]]]
            case "attendanceImport:uploadsForDate": return ["publishedClassCount": 0, "uploads": [Any]()]
            case "homeroomClasses:listCatalog": return ["items": [Any]()]
            case "homeroomClasses:listAssignmentCandidates": return ["items": [Any]()]
            default: throw ConvexException(code: "OFFLINE_READ_UNAVAILABLE")
            }
        }
        let camera = CameraImportStore(yearId: "year", date: "2026-10-07", query: query, write: { _, _, _ in writes += 1; return [:] }, binary: { _, _ in writes += 1; return "storage" }, journal: journal())
        await camera.refreshStatus()
        await camera.refreshStatus()
        await camera.select(name: "fixture.xlsx", data: Data([80,75,3,4]))
        precondition(camera.locked && writes == 0)

        let managementOriginal = journal("management")
        _ = try managementOriginal.restore("owner")
        try managementOriginal.before("commit", ["uploadId": "roster-upload", "storageId": "roster-storage"])
        let management = HomeroomManagementStore(yearId: "year", date: "2026-10-07", query: query, write: { _, _, _ in writes += 1; return [:] }, binary: { _, _ in writes += 1; return "storage" }, isCurrent: { true }, journal: journal("management"))
        await management.refresh()
        await management.refresh()
        await management.mutate("createClass", classId: nil, values: ["code": "6a1", "name": "6A1", "gradeLevel": 6])
        management.discardKnown()
        precondition(management.locked && management.uploadId == "roster-upload" && management.storageId == "roster-storage" && writes == 0)
        print("Homeroom pending journal actual-source checks passed")
    }
}
