import Foundation
import CoreFoundation

struct AbsenceTarget: Equatable, Sendable {
    let id: String
    let studentId: String
    let context: DetailContext
}
struct HomeroomWrite {
    let path: String
    let args: [String: Any]
    let context: DetailContext
    var studentId: String? = nil
    var targets: [AbsenceTarget] = []
}
struct WriteReceipt { let status: String; let refreshFailed: Bool }
enum HomeroomWritePayload {
    private static let whitespace = #"\u0009-\u000D\u0020\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000\uFEFF"#
    static func validate(_ write: HomeroomWrite) throws {
        func string(_ key: String, optional: Bool = false) throws -> String {
            if optional && write.args[key] == nil { return "" }
            guard let value = write.args[key] as? String else { throw ConvexException(code: "INVALID_WRITE") }
            return value
        }
        let expected: HomeroomWrite
        switch write.path {
        case "studentAttendance:setDisposition", "studentAttendance:setDispositionMany":
            try require(write.targets.allSatisfy { $0.context.yearId == write.context.yearId }, "INVALID_CONTEXT")
            expected = try disposition(write.targets, next: string("nextDisposition"), reason: string("reasonCode", optional: true), note: string("note", optional: true), batch: write.path.hasSuffix("Many"))
        case "students:updateContacts": expected = try studentPhone(write.context, studentId: write.studentId ?? "", value: string("studentPhone"))
        case "students:upsertGuardian":
            guard let primary = write.args["isPrimaryContact"] as? NSNumber, CFGetTypeID(primary) == CFBooleanGetTypeID() else { throw ConvexException(code: "INVALID_WRITE") }
            expected = try guardian(write.context, studentId: write.studentId ?? "", id: write.args["guardianId"] == nil ? nil : string("guardianId"), relationship: string("relationship"), name: string("fullName"), phone: string("phone"), primary: primary.boolValue, notes: string("notes"))
        case "students:removeGuardian": expected = try remove(write.context, studentId: write.studentId ?? "", id: string("guardianId"))
        default: throw ConvexException(code: "INVALID_WRITE")
        }
        try require(NSDictionary(dictionary: write.args).isEqual(to: expected.args), "INVALID_WRITE_CONTEXT")
    }
    static func isDenied(_ error: Error) -> Bool {
        let code = (error as? ConvexException)?.code ?? ""
        return code == "WRITE_DENIED" || code.contains("FORBIDDEN") || code.contains("HIDDEN") || ["USER_NOT_ACTIVE", "PASSWORD_CHANGE_REQUIRED", "Unauthenticated", "UNAUTHENTICATED", "ATTENDANCE_DAY_NOT_FOUND", "CLASS_NOT_FOUND", "STUDENT_NOT_FOUND", "GUARDIAN_NOT_FOUND", "CLASS_ARCHIVED", "DISPOSITION_NOT_ABSENT"].contains(code)
    }
    static let relationships = ["father", "mother", "guardian", "grandparent", "sibling", "other"]
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw ConvexException(code: "INVALID_WRITE", message: message) }
    }
    static func trimmed(_ text: String) -> String { text.replacingOccurrences(of: "^[\(whitespace)]+|[\(whitespace)]+$", with: "", options: .regularExpression) }
    static func phone(_ text: String) throws -> String {
        let value = trimmed(text)
        try require(value.isEmpty || value.range(of: "^[0-9+().\\-\(whitespace)]{6,20}$", options: .regularExpression) != nil, "Số điện thoại: 6–20 ký tự số, + ( ) . - hoặc khoảng trắng.")
        return value
    }
    static func disposition(_ targets: [AbsenceTarget], next: String, reason: String, note: String, batch: Bool) throws -> HomeroomWrite {
        var unique: [AbsenceTarget] = []
        for target in targets {
            if let existing = unique.first(where: { $0.id == target.id }) { try require(existing == target, "INVALID_CONTEXT") }
            else { unique.append(target) }
        }
        try require(!unique.isEmpty && unique.count <= 100 && (batch || unique.count == 1), "Chọn từ 1 đến 100 buổi duy nhất.")
        for target in unique { try target.context.validate(); try require(!target.id.isEmpty && !target.studentId.isEmpty, "INVALID_CONTEXT") }
        try require(["pending", "excused", "unexcused"].contains(next), "Phân loại không hợp lệ.")
        try require(trimmed(note).utf16.count <= 500, "Ghi chú tối đa 500 ký tự.")
        try require(next == "pending" || !trimmed(reason).isEmpty || !trimmed(note).isEmpty, "Cần lý do hoặc ghi chú.")
        var args: [String: Any] = ["nextDisposition": next]
        if batch { args["attendanceDayIds"] = unique.map(\.id) } else { args["attendanceDayId"] = unique[0].id }
        if !trimmed(reason).isEmpty { args["reasonCode"] = trimmed(reason) }
        if !trimmed(note).isEmpty { args["note"] = trimmed(note) }
        return HomeroomWrite(path: batch ? "studentAttendance:setDispositionMany" : "studentAttendance:setDisposition", args: args, context: unique[0].context, targets: unique)
    }
    static func studentPhone(_ context: DetailContext, studentId: String, value: String) throws -> HomeroomWrite {
        HomeroomWrite(path: "students:updateContacts", args: ["studentId": studentId, "studentPhone": try phone(value)], context: context, studentId: studentId)
    }
    static func guardian(_ context: DetailContext, studentId: String, id: String?, relationship: String, name: String, phone: String, primary: Bool, notes: String) throws -> HomeroomWrite {
        let normalized = trimmed(name).replacingOccurrences(of: "[\(whitespace)]+", with: " ", options: .regularExpression)
        try require((1...120).contains(normalized.utf16.count) && trimmed(notes).utf16.count <= 300 && relationships.contains(relationship), "Tên 1–120 ký tự; ghi chú tối đa 300; chọn quan hệ hợp lệ.")
        var args: [String: Any] = ["studentId": studentId, "relationship": relationship, "fullName": normalized, "phone": try self.phone(phone), "isPrimaryContact": primary, "notes": trimmed(notes)]
        if let id { args["guardianId"] = id }
        return HomeroomWrite(path: "students:upsertGuardian", args: args, context: context, studentId: studentId)
    }
    static func remove(_ context: DetailContext, studentId: String, id: String) -> HomeroomWrite {
        HomeroomWrite(path: "students:removeGuardian", args: ["studentId": studentId, "guardianId": id], context: context, studentId: studentId)
    }
}

@MainActor final class HomeroomWriteRepository {
    private let query: (String, [String: Any]) async throws -> [String: Any]
    private let mutation: (String, [String: Any]) async throws -> [String: Any]
    private var submitting = false
    init(query: @escaping (String, [String: Any]) async throws -> [String: Any], mutation: @escaping (String, [String: Any]) async throws -> [String: Any]) { self.query = query; self.mutation = mutation }
    private func denied() -> ConvexException { ConvexException(code: "WRITE_DENIED", message: "Quyền hoặc dữ liệu đã thay đổi. Đã xóa nội dung gửi; tải lại trước khi sửa.") }
    func submit(_ write: HomeroomWrite, isCurrent: () -> Bool, onAcknowledged: () -> Void = {}) async throws -> WriteReceipt {
        guard !submitting else { throw ConvexException(code: "WRITE_BUSY", message: "Đang gửi; không gửi trùng.") }
        submitting = true
        defer { submitting = false }
        try write.context.validate()
        try HomeroomWritePayload.validate(write)
        guard isCurrent() else { throw denied() }
        if !write.targets.isEmpty {
            try HomeroomWritePayload.require((1...100).contains(write.targets.count) && ["studentAttendance:setDisposition", "studentAttendance:setDispositionMany"].contains(write.path), "INVALID_WRITE")
            var contexts: [DetailContext] = []
            for target in write.targets where !contexts.contains(target.context) { contexts.append(target.context) }
            for context in contexts {
                let scoped = try HomeroomDetailDecoder.scoped(await query("homeroomClasses:getScoped", ["classId": context.classId, "date": context.date]))
                guard scoped.class._id == context.classId, scoped.class.schoolYearId == context.yearId, scoped.class.status == "active" else { throw denied() }
                try Task.checkCancellation()
                let daily = try HomeroomDetailDecoder.daily(await query("studentAttendance:listDailyClass", ["classId": context.classId, "attendanceDate": context.date]))
                guard daily.date == context.date, !daily.archived, daily.canCorrect, write.targets.filter({ $0.context == context }).allSatisfy({ target in daily.rows.contains { $0.student._id == target.studentId && $0.day?._id == target.id && $0.day?.rawObservation == "absent" } }) else { throw denied() }
            }
        } else {
            guard let id = write.studentId, !id.isEmpty, ["students:updateContacts", "students:upsertGuardian", "students:removeGuardian"].contains(write.path) else { throw denied() }
            let profile = try HomeroomDetailDecoder.profile(await query("students:getScoped", ["studentId": id, "includeSensitiveContacts": false]))
            guard profile.student._id == id, profile.showContacts, profile.permissions.canEditContacts, profile.enrollments.contains(where: { $0.classId == write.context.classId }) else { throw denied() }
            if let guardianId = write.args["guardianId"] as? String, !profile.guardians.contains(where: { $0._id == guardianId }) { throw denied() }
            if write.path == "students:upsertGuardian", write.args["guardianId"] == nil { try HomeroomWritePayload.require(profile.guardians.count < 6, "Tối đa 6 người giám hộ.") }
            let scoped = try HomeroomDetailDecoder.scoped(await query("homeroomClasses:getScoped", ["classId": write.context.classId, "date": write.context.date]))
            guard scoped.class._id == write.context.classId, scoped.class.schoolYearId == write.context.yearId, scoped.class.status == "active" else { throw denied() }
        }
        try Task.checkCancellation()
        guard isCurrent() else { throw denied() }
        let ack: [String: Any]
        do {
            ack = try await mutation(write.path, write.args)
            try validateAck(write, ack)
        } catch is CancellationError { throw CancellationError() }
        catch {
            if HomeroomWritePayload.isDenied(error) { throw denied() }
            if ["INVALID_PHONE", "INVALID_NAME", "INVALID_TEXT", "INVALID_DISPOSITION", "INVALID_DISPOSITION_NOTE", "CORRECTION_REASON_REQUIRED", "GUARDIAN_LIMIT"].contains((error as? ConvexException)?.code ?? "") { throw error }
            throw ConvexException(code: "WRITE_UNCERTAIN", message: "Chưa xác nhận được kết quả ghi. Không gửi lại; tải lại để kiểm tra. \(error.localizedDescription)")
        }
        try Task.checkCancellation()
        guard isCurrent() else { return WriteReceipt(status: "Ghi đã được xác nhận; ngữ cảnh đã đổi. Tải lại dữ liệu.", refreshFailed: true) }
        onAcknowledged()
        let message = (ack["updated"] as? Int).map { "Máy chủ xác nhận \($0)/\(write.targets.count) buổi thay đổi (các buổi còn lại không đổi)." } ?? (ack["unchanged"] as? Bool == true ? "Máy chủ xác nhận buổi này không thay đổi." : "Máy chủ đã xác nhận ghi.")
        do {
            let details = HomeroomDetailRepository(query: query)
            var contexts: [DetailContext] = []
            for context in write.targets.map(\.context) + [write.context] where !contexts.contains(context) { contexts.append(context) }
            for context in contexts {
                try Task.checkCancellation()
                guard isCurrent() else { throw denied() }
                _ = try await details.loadClass(context)
                let ids = Set(write.targets.filter { $0.context == context }.map(\.studentId) + [write.studentId].compactMap { $0 })
                for id in ids { _ = try await details.loadStudent(context, studentId: id) }
            }
            let overview = try HomeroomRepository.decodeOverview(await query("homeroomReports:overview", ["schoolYearId": write.context.yearId, "date": write.context.date]))
            try HomeroomDetailDecoder.require(overview.schoolYear.id == write.context.yearId && overview.date == write.context.date)
            _ = try HomeroomRepository.decodePending(await query("homeroomReports:pendingAbsences", ["schoolYearId": write.context.yearId]))
            return WriteReceipt(status: message, refreshFailed: false)
        } catch is CancellationError { throw CancellationError() }
        catch { return WriteReceipt(status: "\(message) Không tải được dữ liệu sau ghi; không gửi lại. Chỉ tải lại.", refreshFailed: true) }
    }
    func validateAck(_ write: HomeroomWrite, _ value: [String: Any]) throws {
        var valid = false
        switch write.path {
        case "students:updateContacts", "students:removeGuardian": valid = value.isEmpty
        case "students:upsertGuardian":
            if let id = value["value"] as? String { valid = value.count == 1 && !HomeroomWritePayload.trimmed(id).isEmpty && (write.args["guardianId"] == nil || id == write.args["guardianId"] as? String) }
        case "studentAttendance:setDispositionMany":
            if let count = value["updated"] as? NSNumber, CFGetTypeID(count) != CFBooleanGetTypeID() { valid = value.count == 1 && count.doubleValue == Double(count.intValue) && (0...write.targets.count).contains(count.intValue) }
        case "studentAttendance:setDisposition":
            let status = ["pending": "absent_pending", "excused": "absent_excused", "unexcused": "absent_unexcused"][write.args["nextDisposition"] as? String ?? ""]
            if let unchanged = value["unchanged"] as? NSNumber { valid = CFGetTypeID(unchanged) == CFBooleanGetTypeID() && value["attendanceDayId"] as? String == write.targets.first?.id && value["effectiveStatus"] as? String == status }
        default: break
        }
        if !valid { throw ConvexException(code: "INVALID_MUTATION_ACK") }
    }
}
