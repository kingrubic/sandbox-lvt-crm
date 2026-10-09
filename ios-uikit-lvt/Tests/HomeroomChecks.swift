import Foundation

@main
struct HomeroomChecks {
    static func main() throws {
        func session(_ access: Any? = nil, role: String = "user", status: String = "active", password: Bool = false) -> UserSession {
            UserSession(sessionContext: ["user": ["_id": "test-user", "role": role, "status": status, "mustChangePassword": password],
                                         "menuAccess": ["homeroom": access ?? NSNull()]])!
        }
        for access: Any in [NSNull(), "unknown", true, 1, ["bad": "view"]] {
            precondition(!session(access).canSeeHomeroom)
        }
        precondition(session("edit").homeroomAccess == .view)
        precondition(session("view_all").canSeeHomeroom && !session("view_all").isHomeroomSupervisor)
        precondition(session("supervisor").isHomeroomSupervisor)
        precondition(session(role: "admin").canSeeHomeroom)
        precondition(session(role: "moderator").canSeeHomeroom)
        precondition(!session(role: "admin", status: "inactive").canSeeHomeroom)
        let missingMenu = UserSession(sessionContext: ["user": ["_id": "test-user", "status": "active"]])!
        let malformedMenu = UserSession(sessionContext: ["user": ["_id": "test-user", "status": "active"], "menuAccess": ["view"]])!
        precondition(!missingMenu.canSeeHomeroom && !malformedMenu.canSeeHomeroom)
        precondition(!session("view", status: "inactive").canSeeHomeroom)
        precondition(!session(role: "admin", password: true).canSeeHomeroom)
        let instant = ISO8601DateFormatter().date(from: "2026-10-07T17:00:00Z")!
        precondition(VietnamDate.today(now: instant) == "2026-10-08")
        precondition(VietnamDate.today(now: instant.addingTimeInterval(-1)) == "2026-10-07")
        precondition(VietnamDate.date(from: "2024-02-29") != nil)
        for date in ["2026-02-29", "2026-02-30", "2026-13-01", "2026-1-01", "bad"] {
            precondition(VietnamDate.date(from: date) == nil)
        }
        let overview = try HomeroomRepository.decodeOverview([
            "date": "2026-10-07", "today": "2026-10-07", "mode": "teacher",
            "schoolYear": ["_id": "test-year", "name": "2026–2027"], "classes": [[String: Any]](),
            "schoolDay": [String: Any](), "missingUpload": [String: Any](),
            "summary": ["counts": ["present": 0, "late": 0, "absent_excused": 0, "absent_unexcused": 0, "no_data": 3, "absent_pending": 2, "exempt": 0], "ratedRows": 2, "totalRows": 5]
        ])
        precondition(overview.counts.noData == 3 && overview.counts.absent == 2 && overview.classes.isEmpty)
        let pending = try HomeroomRepository.decodePending([
            "total": 501, "truncated": true,
            "rows": (0..<500).map { ["_id": "test-row-\($0)", "canCorrect": false] as [String: Any] }
        ])
        precondition(pending.total == 501 && pending.truncated && pending.rows.count == 500 && !pending.rows[0].canCorrect)
        let years = try HomeroomRepository.decodeSchoolYears(["items": [[String: Any]]()])
        let status = try HomeroomRepository.decodeImportStatus(["publishedClassCount": 0, "uploads": [[String: Any]]()])
        precondition(years.isEmpty && status.uploads.isEmpty)
        func rejects(_ decode: () throws -> Void) {
            do { try decode(); preconditionFailure("Malformed response accepted") } catch {}
        }
        rejects { _ = try HomeroomRepository.decodeOverview([:]) }
        rejects { _ = try HomeroomRepository.decodePending([:]) }
        rejects { _ = try HomeroomRepository.decodeSchoolYears([:]) }
        rejects { _ = try HomeroomRepository.decodeImportStatus([:]) }
        print("PASS: actual UIKit source checks — role denial, Vietnam dates, no_data, empty, truncation, malformed payloads; no live requests")
    }
}
