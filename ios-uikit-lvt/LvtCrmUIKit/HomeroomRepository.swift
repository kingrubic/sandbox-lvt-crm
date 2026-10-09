import Foundation

struct SchoolYear: Equatable, Sendable {
    let id: String
    let name: String
    let startDate: String
    let endDate: String
    let active: Bool
}

struct AttendanceCounts: Equatable, Sendable {
    let present: Int
    let late: Int
    let absentExcused: Int
    let absentUnexcused: Int
    let absentPending: Int
    let noData: Int
    let exempt: Int

    var absent: Int { absentExcused + absentUnexcused + absentPending }
}

struct HomeroomClassSummary: Equatable, Sendable, Identifiable {
    let id: String
    let code: String
    let name: String
    let gradeLevel: Int?
    let rosterCount: Int
    let teacherName: String
    let published: Bool
    let counts: AttendanceCounts
    let pendingTotal: Int
    let canCorrect: Bool
}

struct HomeroomSchoolDay: Equatable, Sendable {
    let isSchoolDay: Bool
    let kind: String
    let note: String
    let outsideYear: Bool
}

struct HomeroomOverview: Equatable, Sendable {
    let date: String
    let today: String
    let mode: String
    let schoolYear: SchoolYear
    let schoolDay: HomeroomSchoolDay
    let classes: [HomeroomClassSummary]
    let studentCount: Int
    let counts: AttendanceCounts
    let attendanceRate: Double
    let ratedRows: Int
    let totalRows: Int
    let missingUploadShouldAlert: Bool
    let missingUploadCutoffTime: String
    let missingClassCodes: [String]
    let pendingTotal: Int
}

struct PendingAbsence: Equatable, Sendable, Identifiable {
    let id: String
    let attendanceDate: String
    let classCode: String
    let studentCode: String
    let fullName: String
    let note: String
    let canCorrect: Bool
    var classId: String = ""
    var studentId: String = ""
}

struct PendingAbsences: Equatable, Sendable {
    let total: Int
    let truncated: Bool
    let rows: [PendingAbsence]
}

struct ImportUpload: Equatable, Sendable, Identifiable {
    let id: String
    let fileName: String
    let publishedAt: Int64
    let uploadedByName: String
    let rowCount: Int
    let matchedCount: Int
}

struct HomeroomImportStatus: Equatable, Sendable {
    let publishedClassCount: Int
    let uploads: [ImportUpload]
}

final class HomeroomRepository: Sendable {
    private let convex: ConvexHttpClient

    init(convex: ConvexHttpClient) { self.convex = convex }

    func queryDetail(_ path: String, args: [String: Any]) async throws -> [String: Any] {
        try await convex.query(path, args: args)
    }

    @MainActor var detailOperations: HomeroomDetailRepository {
        HomeroomDetailRepository { path, args in try await self.queryDetail(path, args: args) }
    }
    @MainActor var writeOperations: HomeroomWriteRepository {
        HomeroomWriteRepository(query: { path, args in try await self.convex.query(path, args: args) }, mutation: { path, args in try await self.convex.mutation(path, args: args) })
    }
    @MainActor func management(yearId: String, date: String, isCurrent: @escaping () -> Bool) -> HomeroomManagementStore {
        HomeroomManagementStore(yearId: yearId, date: date, query: { path, args in try await self.convex.query(path, args: args) }, write: { kind, path, args in try await self.convex.importCall(kind, path: path, args: args) }, binary: { url, bytes in try await self.uploadWorkbook(url, bytes) }, isCurrent: isCurrent, journal: HomeroomPendingJournal(directory: HomeroomPendingJournal.directory, lane: "management", year: yearId, date: date))
    }
    @MainActor func cameraImport(yearId: String, date: String, isCurrent: @escaping () -> Bool) -> CameraImportStore {
        CameraImportStore(yearId: yearId, date: date, query: { path, args in try await self.convex.query(path, args: args) }, write: { kind, path, args in try await self.convex.importCall(kind, path: path, args: args) }, binary: { url, bytes in try await self.uploadWorkbook(url, bytes) }, isCurrent: isCurrent, journal: HomeroomPendingJournal(directory: HomeroomPendingJournal.directory, lane: "camera", year: yearId, date: date))
    }
    private func uploadWorkbook(_ url: String, _ bytes: Data) async throws -> String {
            guard let target = URL(string: url), target.scheme == "https", target.host?.isEmpty == false else { throw ConvexException(code: "INVALID_IMPORT_URL") }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 45
            configuration.timeoutIntervalForResource = 60
            let session = URLSession(configuration: configuration, delegate: CameraUploadRedirectGuard(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            var request = URLRequest(url: target)
            request.httpMethod = "POST"
            request.setValue("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", forHTTPHeaderField: "Content-Type")
            request.httpBody = bytes
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode), let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let id = json["storageId"] as? String, !id.isEmpty else { throw ConvexException(code: "IMPORT_UNCERTAIN") }
            return id
    }

    func listSchoolYears() async throws -> [SchoolYear] {
        try Self.decodeSchoolYears(await convex.query("schoolYears:list"))
    }

    func overview(schoolYearId: String, date: String) async throws -> HomeroomOverview {
        try Self.decodeOverview(await convex.query(
            "homeroomReports:overview",
            args: ["schoolYearId": schoolYearId, "date": date]
        ))
    }

    func pendingAbsences(schoolYearId: String) async throws -> PendingAbsences {
        try Self.decodePending(await convex.query(
            "homeroomReports:pendingAbsences",
            args: ["schoolYearId": schoolYearId]
        ))
    }

    func importStatus(schoolYearId: String, date: String) async throws -> HomeroomImportStatus {
        try Self.decodeImportStatus(await convex.query(
            "attendanceImport:uploadsForDate",
            args: ["schoolYearId": schoolYearId, "attendanceDate": date]
        ))
    }

    static func decodeSchoolYears(_ value: [String: Any]) throws -> [SchoolYear] {
        guard let items = value["items"] as? [[String: Any]] else { throw invalidResponse() }
        return try items.map { row in
            guard let id = row["_id"] as? String, !id.isEmpty else { throw invalidResponse() }
            return SchoolYear(
                id: id,
                name: row.string("name"),
                startDate: row.string("startDate"),
                endDate: row.string("endDate"),
                active: row.bool("active")
            )
        }
    }

    static func decodeOverview(_ value: [String: Any]) throws -> HomeroomOverview {
        guard let year = value["schoolYear"] as? [String: Any], !year.string("_id").isEmpty,
              VietnamDate.date(from: value.string("date")) != nil,
              VietnamDate.date(from: value.string("today")) != nil,
              value["classes"] is [[String: Any]], value["schoolDay"] is [String: Any],
              value["missingUpload"] is [String: Any],
              let summary = value["summary"] as? [String: Any], summary["counts"] is [String: Any] else {
            throw ConvexException(code: "INVALID_RESPONSE", message: "Phản hồi tổng quan lớp chủ nhiệm không hợp lệ.")
        }
        let schoolDay = value["schoolDay"] as? [String: Any] ?? [:]
        let missing = value["missingUpload"] as? [String: Any] ?? [:]
        let classes = try (value["classes"] as? [[String: Any]] ?? []).map { row in
            HomeroomClassSummary(
                id: row.string("_id"),
                code: row.string("code"),
                name: row.string("name"),
                gradeLevel: row.optionalInt("gradeLevel"),
                rosterCount: row.int("rosterCount"),
                teacherName: row.string("teacherName"),
                published: row.bool("published"),
                counts: try decodeCounts(row["counts"] as? [String: Any]),
                pendingTotal: row.int("pendingTotal"),
                canCorrect: row.bool("canCorrect")
            )
        }
        return HomeroomOverview(
            date: value.string("date"),
            today: value.string("today"),
            mode: value.string("mode"),
            schoolYear: SchoolYear(
                id: year.string("_id"),
                name: year.string("name"),
                startDate: year.string("startDate"),
                endDate: year.string("endDate"),
                active: false
            ),
            schoolDay: HomeroomSchoolDay(
                isSchoolDay: schoolDay.bool("isSchoolDay"),
                kind: schoolDay.string("kind"),
                note: schoolDay.string("note"),
                outsideYear: schoolDay.bool("outsideYear")
            ),
            classes: classes,
            studentCount: value.int("studentCount"),
            counts: try decodeCounts(summary["counts"] as? [String: Any]),
            attendanceRate: summary.double("attendanceRate"),
            ratedRows: summary.int("ratedRows"),
            totalRows: summary.int("totalRows"),
            missingUploadShouldAlert: missing.bool("shouldAlert"),
            missingUploadCutoffTime: missing.string("cutoffTime"),
            missingClassCodes: (missing["missingClasses"] as? [[String: Any]] ?? []).map { $0.string("code") },
            pendingTotal: value.int("pendingTotal")
        )
    }

    static func decodePending(_ value: [String: Any]) throws -> PendingAbsences {
        guard value["total"] is NSNumber, value["truncated"] is Bool, value["rows"] is [[String: Any]] else {
            throw ConvexException(code: "INVALID_RESPONSE", message: "Phản hồi vắng chờ xử lý không hợp lệ.")
        }
        return PendingAbsences(
            total: value.int("total"),
            truncated: value.bool("truncated"),
            rows: (value["rows"] as? [[String: Any]] ?? []).map { row in
                PendingAbsence(
                    id: row.string("_id"),
                    attendanceDate: row.string("attendanceDate"),
                    classCode: row.string("classCode"),
                    studentCode: row.string("studentCode"),
                    fullName: row.string("fullName"),
                    note: row.string("note"),
                    canCorrect: row.bool("canCorrect"),
                    classId: row.string("classId"),
                    studentId: row.string("studentId")
                )
            }
        )
    }

    static func decodeImportStatus(_ value: [String: Any]) throws -> HomeroomImportStatus {
        guard value["publishedClassCount"] is NSNumber, value["uploads"] is [[String: Any]] else {
            throw invalidResponse()
        }
        return HomeroomImportStatus(
            publishedClassCount: value.int("publishedClassCount"),
            uploads: (value["uploads"] as? [[String: Any]] ?? []).map { row in
                ImportUpload(
                    id: row.string("_id"),
                    fileName: row.string("fileName"),
                    publishedAt: Int64(row.int("publishedAt")),
                    uploadedByName: row.string("uploadedByName"),
                    rowCount: row.int("rowCount"),
                    matchedCount: row.int("matchedCount")
                )
            }
        )
    }

    private static func decodeCounts(_ value: [String: Any]?) throws -> AttendanceCounts {
        guard let row = value else { throw invalidResponse() }
        for key in ["present", "late", "absent_excused", "absent_unexcused", "absent_pending", "no_data", "exempt"] {
            guard let number = row[key] as? NSNumber, number.intValue >= 0 else { throw invalidResponse() }
        }
        return AttendanceCounts(
            present: row.int("present"),
            late: row.int("late"),
            absentExcused: row.int("absent_excused"),
            absentUnexcused: row.int("absent_unexcused"),
            absentPending: row.int("absent_pending"),
            noData: row.int("no_data"),
            exempt: row.int("exempt")
        )
    }

    private static func invalidResponse() -> ConvexException {
        ConvexException(code: "INVALID_RESPONSE", message: "Phản hồi lớp chủ nhiệm không hợp lệ.")
    }
}

enum VietnamDate {
    static let timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!

    static func today(now: Date = Date()) -> String {
        string(from: now)
    }

    static func string(from date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func date(from ymd: String) -> Date? {
        guard ymd.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let parts = ymd.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              string(from: date) == ymd else { return nil }
        return date
    }

    static func display(_ ymd: String) -> String {
        guard let date = date(from: ymd) else { return ymd }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "vi_VN")
        formatter.dateFormat = "dd/MM/yyyy"
        return formatter.string(from: date)
    }
}

private extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String { self[key] as? String ?? "" }
    func bool(_ key: String) -> Bool { self[key] as? Bool ?? false }
    func int(_ key: String) -> Int { (self[key] as? NSNumber)?.intValue ?? self[key] as? Int ?? 0 }
    func optionalInt(_ key: String) -> Int? { self[key] is NSNull || self[key] == nil ? nil : int(key) }
    func double(_ key: String) -> Double { (self[key] as? NSNumber)?.doubleValue ?? self[key] as? Double ?? 0 }
}
