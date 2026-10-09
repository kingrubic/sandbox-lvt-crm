import Foundation

struct DetailContext: Equatable, Sendable {
    let yearId: String
    let classId: String
    let date: String
    let from: String
    let to: String

    func validate() throws {
        guard !yearId.isEmpty, !classId.isEmpty, VietnamDate.date(from: date) != nil,
              VietnamDate.date(from: from) != nil, VietnamDate.date(from: to) != nil, from <= to else {
            throw ConvexException(code: "INVALID_CONTEXT")
        }
    }
}

struct StudentIdentity: Decodable, Sendable {
    let _id: String
    let studentCode: String
    let fullName: String
    let dateOfBirth: String?
    let gender: String?
}

struct RosterEnrollment: Decodable, Sendable {
    let _id: String
    let rosterNumber: Int?
    let startDate: String
}

struct RosterRow: Decodable, Sendable {
    let enrollment: RosterEnrollment
    let student: StudentIdentity
}

struct ClassRoster: Decodable, Sendable {
    let rows: [RosterRow]
    let showContacts: Bool
}

struct ScopedClass: Decodable, Sendable {
    struct Klass: Decodable, Sendable {
        let _id: String
        let schoolYearId: String
        let code: String
        let name: String
        let status: String
    }
    struct Year: Decodable, Sendable { let _id: String; let name: String }
    struct Permissions: Decodable, Sendable {
        let canManage: Bool
        let canImportAttendance: Bool
        let canCorrect: Bool
        let canEditContacts: Bool
    }
    let `class`: Klass
    let schoolYear: Year?
    let currentTeacherName: String
    let rosterCount: Int
    let permissions: Permissions
}

struct AttendanceRecord: Decodable, Sendable {
    let _id: String
    let rawObservation: String
    let rawObservedAt: Double?
    let disposition: String
    let effectiveStatus: String
    let reasonCode: String?
    let note: String?
}

struct DailyRow: Decodable, Sendable {
    struct Enrollment: Decodable, Sendable { let _id: String; let rosterNumber: Int? }
    let enrollment: Enrollment
    let student: StudentIdentity
    let day: AttendanceRecord?
}

struct ClassDaily: Decodable, Sendable {
    struct CalendarDay: Decodable, Sendable {
        let isSchoolDay: Bool
        let kind: String
        let note: String?
        let outsideYear: Bool
    }
    let date: String
    let rows: [DailyRow]
    let published: Bool
    let archived: Bool
    let canCorrect: Bool
    let schoolDay: CalendarDay
}

struct StudentProfile: Decodable, Sendable {
    struct Guardian: Decodable, Sendable {
        let _id: String
        let relationship: String
        let fullName: String
        let phone: String?
        let isPrimaryContact: Bool
        let notes: String?
    }
    struct Student: Decodable, Sendable {
        let _id: String
        let studentCode: String
        let fullName: String
        let dateOfBirth: String?
        let gender: String?
        let status: String
    }
    struct Enrollment: Decodable, Sendable {
        let _id: String
        let classId: String
        let classCode: String
        let className: String
        let startDate: String
        let endDate: String?
        let status: String
        let rosterNumber: Int?
        let transferReason: String?
        let current: Bool
    }
    struct Permissions: Decodable, Sendable { let canManage: Bool; let canEditContacts: Bool }
    let student: Student
    let enrollments: [Enrollment]
    let showContacts: Bool
    let permissions: Permissions
    let studentPhone: String?
    let guardians: [Guardian]

    enum CodingKeys: String, CodingKey { case student, enrollments, showContacts, permissions, guardians }
    enum PhoneKey: String, CodingKey { case studentPhone }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        student = try values.decode(Student.self, forKey: .student)
        enrollments = try values.decode([Enrollment].self, forKey: .enrollments)
        showContacts = try values.decode(Bool.self, forKey: .showContacts)
        permissions = try values.decode(Permissions.self, forKey: .permissions)
        if showContacts {
            let identity = try values.nestedContainer(keyedBy: PhoneKey.self, forKey: .student)
            studentPhone = try identity.decodeIfPresent(String.self, forKey: .studentPhone)
            guardians = try values.decode([Guardian].self, forKey: .guardians)
        } else {
            studentPhone = nil
            guardians = []
        }
    }
}

struct StudentHistory: Decodable, Sendable {
    struct Day: Decodable, Sendable {
        let _id: String
        let studentId: String
        let classId: String
        let attendanceDate: String
        let rawObservation: String
        let rawObservedAt: Double?
        let disposition: String
        let effectiveStatus: String
        let reasonCode: String?
        let note: String?
    }
    struct Correction: Decodable, Sendable {
        let _id: String
        let attendanceDayId: String
        let studentId: String
        let attendanceDate: String
        let previousDisposition: String
        let nextDisposition: String
        let previousEffectiveStatus: String
        let nextEffectiveStatus: String
        let reasonCode: String?
        let note: String?
        let actorUserId: String
        let at: Double
    }
    let days: [Day]
    let corrections: [Correction]
}

struct ClassDetail: Sendable { let scoped: ScopedClass; let roster: ClassRoster; let daily: ClassDaily }
struct StudentDetail: Sendable { let profile: StudentProfile; let history: StudentHistory }

enum HomeroomDetailDecoder {
    static let statuses = ["present", "late", "absent_pending", "absent_excused", "absent_unexcused", "no_data", "exempt"]
    static let dispositions = ["none", "pending", "excused", "unexcused", "exempt"]
    static func statusText(_ status: String) -> String {
        ["present": "Có mặt", "late": "Trễ", "absent_pending": "Vắng chờ xử lý", "absent_excused": "Vắng có phép", "absent_unexcused": "Vắng không phép", "no_data": "Chưa có dữ liệu", "exempt": "Miễn"][status] ?? "Trạng thái không hợp lệ"
    }
    static func matchesStudent(name: String, code: String, search: String) -> Bool {
        func normalized(_ value: String) -> String {
            value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "vi_VN")).replacingOccurrences(of: "đ", with: "d")
        }
        let term = normalized(search.trimmingCharacters(in: .whitespacesAndNewlines))
        // Foundation String.contains("") is false; an empty search must keep every row.
        if term.isEmpty { return true }
        return normalized(name).contains(term) || normalized(code).contains(term)
    }
    static func require(_ condition: Bool) throws {
        if !condition { throw ConvexException(code: "INVALID_RESPONSE", message: "Phản hồi lớp/học sinh không hợp lệ.") }
    }
    static func decode<Value: Decodable>(_ value: [String: Any], as type: Value.Type) throws -> Value {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value))
    }
    static func identity(_ value: StudentIdentity) throws {
        try require(!value._id.isEmpty && !value.studentCode.isEmpty && !value.fullName.isEmpty)
        if let date = value.dateOfBirth { try require(VietnamDate.date(from: date) != nil) }
    }
    static func observation(_ raw: String, _ disposition: String, _ status: String) throws {
        try require(["present", "late", "absent", "unknown"].contains(raw) && dispositions.contains(disposition) && statuses.contains(status))
    }
    static func scoped(_ value: [String: Any]) throws -> ScopedClass {
        let result = try decode(value, as: ScopedClass.self)
        try require(!result.class._id.isEmpty && !result.class.schoolYearId.isEmpty && !result.class.code.isEmpty && !result.class.name.isEmpty && ["active", "archived"].contains(result.class.status) && result.rosterCount >= 0)
        try require(value["assignments"] is [[String: Any]])
        return result
    }
    static func roster(_ value: [String: Any]) throws -> ClassRoster {
        let result = try decode(value, as: ClassRoster.self)
        try require((value["rows"] as? [[String: Any]])?.allSatisfy { $0["guardians"] is [[String: Any]] } == true)
        for row in result.rows {
            try identity(row.student)
            try require(!row.enrollment._id.isEmpty && VietnamDate.date(from: row.enrollment.startDate) != nil)
            if let number = row.enrollment.rosterNumber { try require(number >= 0) }
        }
        return result
    }
    static func daily(_ value: [String: Any]) throws -> ClassDaily {
        let result = try decode(value, as: ClassDaily.self)
        try require((value["rows"] as? [[String: Any]])?.allSatisfy { $0.keys.contains("day") } == true)
        try require(VietnamDate.date(from: result.date) != nil)
        for row in result.rows {
            try identity(row.student)
            try require(!row.enrollment._id.isEmpty)
            if let number = row.enrollment.rosterNumber { try require(number >= 0) }
            if let day = row.day {
                try require(!day._id.isEmpty)
                try observation(day.rawObservation, day.disposition, day.effectiveStatus)
            }
        }
        return result
    }
    static func profile(_ value: [String: Any]) throws -> StudentProfile {
        let result = try decode(value, as: StudentProfile.self)
        try require(!result.student._id.isEmpty && !result.student.studentCode.isEmpty && !result.student.fullName.isEmpty && !result.student.status.isEmpty)
        if let date = result.student.dateOfBirth { try require(VietnamDate.date(from: date) != nil) }
        try require(value["guardians"] is [[String: Any]])
        try require(result.guardians.count <= 6 && Set(result.guardians.map(\._id)).count == result.guardians.count)
        for guardian in result.guardians {
            try require(!guardian._id.isEmpty && (1...120).contains(HomeroomWritePayload.trimmed(guardian.fullName).utf16.count) && (guardian.notes?.utf16.count ?? 0) <= 300 && HomeroomWritePayload.relationships.contains(guardian.relationship))
            _ = try HomeroomWritePayload.phone(guardian.phone ?? "")
        }
        if result.showContacts { _ = try HomeroomWritePayload.phone(result.studentPhone ?? "") }
        for enrollment in result.enrollments {
            try require(!enrollment._id.isEmpty && !enrollment.classId.isEmpty && VietnamDate.date(from: enrollment.startDate) != nil)
            if let end = enrollment.endDate { try require(VietnamDate.date(from: end) != nil && end >= enrollment.startDate) }
        }
        return result
    }
    static func history(_ value: [String: Any]) throws -> StudentHistory {
        let result = try decode(value, as: StudentHistory.self)
        for day in result.days {
            try require(!day._id.isEmpty && !day.studentId.isEmpty && !day.classId.isEmpty && VietnamDate.date(from: day.attendanceDate) != nil)
            try observation(day.rawObservation, day.disposition, day.effectiveStatus)
        }
        for correction in result.corrections {
            try require(!correction._id.isEmpty && !correction.studentId.isEmpty && !correction.attendanceDayId.isEmpty && !correction.actorUserId.isEmpty && correction.at.isFinite && correction.at >= 0 && VietnamDate.date(from: correction.attendanceDate) != nil)
            try require(dispositions.contains(correction.previousDisposition) && dispositions.contains(correction.nextDisposition) && statuses.contains(correction.previousEffectiveStatus) && statuses.contains(correction.nextEffectiveStatus))
        }
        return result
    }
}

@MainActor protocol HomeroomDetailOperations {
    func loadClass(_ context: DetailContext) async throws -> ClassDetail
    func loadStudent(_ context: DetailContext, studentId: String) async throws -> StudentDetail
}

@MainActor final class HomeroomDetailRepository: HomeroomDetailOperations {
    private let query: (String, [String: Any]) async throws -> [String: Any]

    init(query: @escaping (String, [String: Any]) async throws -> [String: Any]) { self.query = query }

    func loadClass(_ context: DetailContext) async throws -> ClassDetail {
        try context.validate()
        let scoped = try HomeroomDetailDecoder.scoped(await query("homeroomClasses:getScoped", ["classId": context.classId, "date": context.date]))
        try HomeroomDetailDecoder.require(scoped.class._id == context.classId && scoped.class.schoolYearId == context.yearId)
        try Task.checkCancellation()
        let roster = try HomeroomDetailDecoder.roster(await query("students:listByClass", ["classId": context.classId, "date": context.date, "includeSensitiveContacts": false]))
        try Task.checkCancellation()
        let daily = try HomeroomDetailDecoder.daily(await query("studentAttendance:listDailyClass", ["classId": context.classId, "attendanceDate": context.date]))
        try HomeroomDetailDecoder.require(daily.date == context.date)
        return ClassDetail(scoped: scoped, roster: roster, daily: daily)
    }
    func loadStudent(_ context: DetailContext, studentId: String) async throws -> StudentDetail {
        try context.validate()
        try HomeroomDetailDecoder.require(!studentId.isEmpty)
        let profile = try HomeroomDetailDecoder.profile(await query("students:getScoped", ["studentId": studentId, "includeSensitiveContacts": false]))
        try HomeroomDetailDecoder.require(profile.student._id == studentId)
        try Task.checkCancellation()
        let history = try HomeroomDetailDecoder.history(await query("studentAttendance:getStudentHistory", ["studentId": studentId, "from": context.from, "to": context.to]))
        try HomeroomDetailDecoder.require(profile.student._id == studentId && history.days.allSatisfy { $0.studentId == studentId && $0.attendanceDate >= context.from && $0.attendanceDate <= context.to } && history.corrections.allSatisfy { $0.studentId == studentId && $0.attendanceDate >= context.from && $0.attendanceDate <= context.to })
        return StudentDetail(profile: profile, history: history)
    }
}

@MainActor final class HomeroomDetailStore {
    private let operations: HomeroomDetailOperations
    private var generation = 0
    var context: DetailContext
    var studentId: String?
    private(set) var classData: ClassDetail?
    private(set) var studentData: StudentDetail?
    private(set) var loading = false
    private(set) var error: String?
    var onChange: (() -> Void)?

    init(operations: HomeroomDetailOperations, context: DetailContext) {
        self.operations = operations
        self.context = context
    }
    func clear() {
        generation += 1
        classData = nil
        studentData = nil
        error = nil
        loading = false
        onChange?()
    }
    func load() async {
        clear()
        let version = generation
        let requested = context
        let student = studentId
        loading = true
        onChange?()
        do {
            try requested.validate()
            if let student {
                let result = try await operations.loadStudent(requested, studentId: student)
                guard version == generation, !Task.isCancelled, requested == context, studentId == student else { return }
                studentData = result
            } else {
                let result = try await operations.loadClass(requested)
                guard version == generation, !Task.isCancelled, requested == context, studentId == nil else { return }
                classData = result
            }
        } catch {
            guard version == generation, !Task.isCancelled else { return }
            classData = nil
            studentData = nil
            self.error = error.localizedDescription
        }
        loading = false
        onChange?()
    }
}
