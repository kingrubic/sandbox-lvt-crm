import Foundation

enum CameraImportFile {
    static let maxBytes = 4 * 1024 * 1024
    static func read(url: URL, maxBytes: Int = maxBytes) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var result: Result<Data, Error> = .failure(ConvexException(code: "IMPORT_READ_FAILED"))
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { target in
            result = Result {
                try boundedRead(url: target, maxBytes: maxBytes)
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }
    static func boundedRead(url: URL, maxBytes: Int = maxBytes) throws -> Data {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var bytes = Data()
        while bytes.count <= maxBytes {
            guard let chunk = try file.read(upToCount: min(8192, maxBytes + 1 - bytes.count)), !chunk.isEmpty else { break }
            bytes.append(chunk)
        }
        return bytes
    }
    static func validate(name: String, data: Data) throws {
        guard name.lowercased().hasSuffix(".xlsx"), !data.isEmpty, data.count <= maxBytes,
              data.starts(with: [80, 75, 3, 4]) else { throw ConvexException(code: "INVALID_IMPORT_FILE", message: "Chỉ nhận .xlsx dạng ZIP, không rỗng, tối đa 4 MiB. Máy chủ kiểm tra nội dung Excel.") }
    }
}

struct CameraPreview: Decodable {
    struct Issue: Decodable {
        let rowNumber: Int
        let field, column: String
        let rejectedValue: String?
        let code, message, severity: String
    }
    struct ClassRow: Decodable {
        let classId, code, name: String
        let rowCount, matchedCount, present, late, absent, rosterCount, missingCount, errorCount, warningCount: Int
        let publishable, alreadyPublished: Bool
    }
    struct EmptyClass: Decodable { let classId, code, name: String; let alreadyPublished: Bool }
    struct Day: Decodable { let isSchoolDay: Bool; let kind, note: String; let outsideYear: Bool }
    let uploadId, attendanceDate, fileName, sheetName: String
    let ok: Bool
    let totalRows, matchedCount, errorCount, warningCount: Int
    let issues: [Issue]
    let issuesTruncated: Bool
    let classes: [ClassRow]
    let classesWithoutRows: [EmptyClass]
    let schoolDay: Day
    var conflicts: Bool { classes.contains { $0.publishable && $0.alreadyPublished } }
    static func decode(_ value: [String: Any], id: String, date: String) throws -> CameraPreview {
        let preview = try JSONDecoder().decode(CameraPreview.self, from: JSONSerialization.data(withJSONObject: value))
        guard preview.uploadId == id, preview.attendanceDate == date,
              (value["issues"] as? [[String: Any]])?.allSatisfy({ $0.keys.contains("rejectedValue") }) == true,
              [preview.totalRows, preview.matchedCount, preview.errorCount, preview.warningCount].allSatisfy({ $0 >= 0 }),
              preview.issues.allSatisfy({ $0.rowNumber >= 0 && ["error", "warning"].contains($0.severity) }),
              preview.classes.allSatisfy({ !$0.classId.isEmpty && [$0.rowCount, $0.matchedCount, $0.present, $0.late, $0.absent, $0.rosterCount, $0.missingCount, $0.errorCount, $0.warningCount].allSatisfy { $0 >= 0 } }) else { throw ConvexException(code: "INVALID_IMPORT_PREVIEW") }
        return preview
    }
}

@MainActor
final class CameraImportStore {
    typealias RPC = (String, [String: Any]) async throws -> [String: Any]
    static let modes = ["supplement", "replace_camera_observations", "cancel"]
    static let lifecycle = "Bản đăng ký có thời hạn sử dụng 2 giờ. Rời màn hình không xóa file/bản đăng ký; không có API hủy/xóa hay xem trạng thái bản nháp. Danh sách chỉ chứa file đã công bố. Không suy ra kết quả từ việc không có trong danh sách. Nhật ký tối thiểu lưu bền vững, không chứa nội dung file; sau khi tắt ứng dụng/đăng xuất, không gửi lại nếu kết quả trước chưa rõ."
    let yearId, date: String
    private let query: RPC
    private let write: (String, String, [String: Any]) async throws -> [String: Any]
    private let binary: (String, Data) async throws -> String
    private let isCurrent: () -> Bool
    private let journal: HomeroomPendingJournal?
    private func send(_ kind: String, _ path: String, _ args: [String: Any]) async throws -> [String: Any] {
        try journal?.before(path, args)
        let value = try await write(kind, path, args)
        try journal?.received(value)
        return value
    }
    private func upload(_ url: String, _ bytes: Data) async throws -> String {
        try journal?.before("storage-upload", [:])
        let storage = try await binary(url, bytes)
        try journal?.received(["storageId": storage])
        return storage
    }
    private var generation = 0
    private var owner: String?
    private var sent = false
    private var acknowledged = false
    private var canAbandonKnown = false
    private(set) var busy = false
    private(set) var locked = false
    private(set) var uploadId: String?
    private(set) var storageId: String?
    private(set) var preview: CameraPreview?
    private(set) var status: HomeroomImportStatus?
    private(set) var message = lifecycle
    private(set) var previousUploads: [String] = []
    var changed: (() -> Void)?
    var canStartNew: Bool { (acknowledged || canAbandonKnown) && !busy }
    func newFile() {
        guard canStartNew else { return }
        do { try journal?.clear() } catch { locked = true; message = "Không lưu được nhật ký; không tiếp tục."; changed?(); return }
        previousUploads.append("Storage: \(storageId ?? "không có ID") · Upload: \(uploadId ?? "không có ID") · \(acknowledged ? "Đã xác nhận công bố; không gửi lại." : "Bản nháp đã bỏ ở ứng dụng; chưa xác nhận công bố, ứng dụng không xóa file/bản đăng ký trên máy chủ.")")
        generation += 1; acknowledged = false; canAbandonKnown = false; sent = false; locked = false; preview = nil; uploadId = nil; storageId = nil
        message = "Chọn file mới là một lần nhập riêng; không xóa file/bản đăng ký/dữ liệu trước. \(Self.lifecycle)"; changed?()
    }

    init(yearId: String, date: String, query: @escaping RPC, write: @escaping (String, String, [String: Any]) async throws -> [String: Any], binary: @escaping (String, Data) async throws -> String, isCurrent: @escaping () -> Bool = { true }, journal: HomeroomPendingJournal? = nil) {
        self.yearId = yearId; self.date = date; self.query = query; self.write = write; self.binary = binary; self.isCurrent = isCurrent; self.journal = journal
    }
    private var args: [String: Any] { ["schoolYearId": yearId, "attendanceDate": date] }
    private func check(_ token: Int) throws {
        try Task.checkCancellation()
        guard token == generation, isCurrent() else { throw ConvexException(code: "IMPORT_CONTEXT_CHANGED") }
    }
    private func authorize(_ token: Int) async throws {
        try check(token)
        let raw = try await query("users:sessionContext", [:]); try check(token)
        guard let user = raw["user"] as? [String: Any], user["status"] as? String == "active", user["mustChangePassword"] == nil || Self.boolean(user["mustChangePassword"]) == false,
              let session = UserSession(sessionContext: raw), !session.userId.isEmpty, session.isOperationalManager || session.isHomeroomSupervisor,
              owner == nil || owner == session.userId else { throw ConvexException(code: "IMPORT_FORBIDDEN") }
        owner = session.userId
        do {
            if let record = try journal?.restore(session.userId) {
                locked = true; preview = nil; canAbandonKnown = false; message = HomeroomPendingJournal.recovery
                if record["year"] as? String == yearId && record["date"] as? String == date {
                    uploadId = record["uploadId"] as? String; storageId = record["storageId"] as? String
                }
            }
        } catch { locked = true; preview = nil; canAbandonKnown = false; message = HomeroomPendingJournal.recovery; throw error }
        let years = try HomeroomRepository.decodeSchoolYears(await query("schoolYears:list", [:])); try check(token)
        guard let year = years.first(where: { $0.id == yearId }), VietnamDate.date(from: date) != nil, VietnamDate.date(from: year.startDate) != nil, VietnamDate.date(from: year.endDate) != nil, date >= year.startDate, date <= year.endDate, date <= VietnamDate.today() else { throw ConvexException(code: "INVALID_IMPORT_CONTEXT") }
    }
    func invalidate() {
        generation += 1; preview = nil; status = nil
        if sent || uploadId != nil {
            let uncertain = busy && sent && !acknowledged && !locked
            locked = true
            message += uncertain ? " Ngữ cảnh đã đổi trong khi gửi; kết quả chưa xác nhận, không gửi lại." : " Ngữ cảnh đã đổi; không tiếp tục bản này, chỉ tải lại."
        }
        changed?()
    }
    private func perform(_ operation: @escaping (Int) async throws -> Void) async {
        guard !busy, !locked else { return }
        busy = true; sent = false; canAbandonKnown = false; let token = generation; changed?()
        defer { busy = false; changed?() }
        do { try await operation(token) }
        catch {
            if acknowledged { message += " Không tải được dữ liệu sau xác nhận; không gửi lại."; return }
            let code = (error as? ConvexException)?.code ?? "IMPORT_UNCERTAIN"
            let denied = code.contains("FORBIDDEN") || code.contains("SUPERVISOR") || code.contains("AUTHENTICATED") || code.contains("HIDDEN") || code == "Unauthenticated" || ["USER_NOT_ACTIVE", "PASSWORD_CHANGE_REQUIRED", "IMPORT_CONTEXT_CHANGED"].contains(code)
            let explicit = denied || ["INVALID_IMPORT_FILE", "INVALID_IMPORT_CONTEXT", "IMPORT_UPLOAD_EXPIRED", "IMPORT_UPLOAD_NOT_FOUND", "IMPORT_ROWS_UNRESOLVED", "INVALID_REPLACE_MODE", "ATTENDANCE_REPLACE_MODE_REQUIRED", "ATTENDANCE_DATE_IN_FUTURE", "ATTENDANCE_DATE_OUTSIDE_YEAR", "IMPORT_TOO_MANY_ROWS", "IMPORT_FILE_EMPTY", "IMPORT_FILE_TOO_LARGE", "ATTENDANCE_TEMPLATE_HEADER_NOT_FOUND", "ATTENDANCE_TEMPLATE_COLUMNS_MISSING", "SCHOOL_YEAR_NOT_FOUND", "INVALID_DATE"].contains(code)
            canAbandonKnown = !denied && (explicit || !sent) && (storageId != nil || uploadId != nil)
            if denied { preview = nil; status = nil; locked = true }
            if ["IMPORT_UPLOAD_EXPIRED", "IMPORT_UPLOAD_NOT_FOUND"].contains(code) { locked = true; preview = nil }
            if !explicit && sent { locked = true; preview = nil }
            if ["ATTENDANCE_REPLACE_MODE_REQUIRED", "IMPORT_ROWS_UNRESOLVED"].contains(code) { preview = nil }
            message = "\(code): \(error.localizedDescription). \(locked ? "Không gửi lại; chỉ kiểm tra danh sách đã công bố." : "Không tự động thử lại. Có thể kiểm tra bản xem trước bằng thao tác riêng.") \(Self.lifecycle)"
        }
    }
    func select(name: String, data: Data) async {
        guard uploadId == nil, storageId == nil else { return }
        await perform { token in
            try CameraImportFile.validate(name: name, data: data)
            try await self.authorize(token)
            self.sent = true
            let result = try await self.send("mutation", "attendanceImport:generateUploadUrl", self.args); try self.check(token)
            guard let url = result["value"] as? String, let target = URL(string: url), target.scheme == "https", target.host?.isEmpty == false else { throw ConvexException(code: "IMPORT_UNCERTAIN") }
            try await self.authorize(token)
            self.storageId = try await self.upload(url, data); try self.check(token)
            guard let storage = self.storageId, !storage.isEmpty else { throw ConvexException(code: "IMPORT_UNCERTAIN") }
            try await self.authorize(token)
            var args = self.args; args["storageId"] = storage; args["fileName"] = name; args["fileSize"] = data.count
            let registered = try await self.send("mutation", "attendanceImport:registerUpload", args)
            self.uploadId = registered["uploadId"] as? String; try self.check(token)
            guard let id = self.uploadId, !id.isEmpty else { throw ConvexException(code: "IMPORT_UNCERTAIN") }
            try await self.validate(token)
        }
    }
    func picked(name: String?, data: Data?) async {
        guard let name, let data else { return }
        await select(name: name, data: data)
    }
    private func validate(_ token: Int) async throws {
        guard let id = uploadId else { return }
        preview = nil
        try await authorize(token); sent = true
        let value = try await send("action", "attendanceImport:validate", ["uploadId": id]); try check(token)
        try await authorize(token)
        preview = try CameraPreview.decode(value, id: id, date: date)
        canAbandonKnown = true
        message = "Đã kiểm tra; chưa công bố. \(Self.lifecycle)"
    }
    func refreshPreview() async { await perform { try await self.validate($0) } }
    static func receipt(_ value: [String: Any], id: String) throws -> String {
        guard value["importId"] as? String == id, Self.boolean(value["published"]) == true,
              value["idempotent"] == nil || Self.boolean(value["idempotent"]) != nil,
              let count = value["count"] as? NSNumber, let classes = value["classCount"] as? NSNumber,
              CFGetTypeID(count) != CFBooleanGetTypeID(), CFGetTypeID(classes) != CFBooleanGetTypeID(), count.doubleValue == Double(count.intValue), classes.doubleValue == Double(classes.intValue), count.intValue >= 0, classes.intValue >= 0 else { throw ConvexException(code: "IMPORT_UNCERTAIN") }
        let skipped: [String]
        if Self.boolean(value["idempotent"]) == true { guard count.intValue == 0, classes.intValue == 0 else { throw ConvexException(code: "IMPORT_UNCERTAIN") }; skipped = [] }
        else { guard let codes = value["skippedClassCodes"] as? [String] else { throw ConvexException(code: "IMPORT_UNCERTAIN") }; skipped = codes }
        return "Đã xác nhận công bố: \(classes.intValue) lớp, \(count.intValue) thay đổi. Bỏ qua: \(skipped.joined(separator: ", ")). Không gửi lại."
    }
    func publish(mode: String?, confirmed: Bool) async {
        guard confirmed, let preview, preview.classes.contains(where: { $0.publishable }), mode == nil || Self.modes.contains(mode!), !preview.conflicts || mode != nil else { return }
        await perform { token in
            try await self.authorize(token)
            var args: [String: Any] = ["uploadId": preview.uploadId]; if let mode { args["replaceMode"] = mode }
            self.sent = true
            let ack = try await self.send("mutation", "attendanceImport:publish", args)
            let receipt = try Self.receipt(ack, id: preview.uploadId)
            try self.journal?.clear(); self.acknowledged = true; self.locked = true; self.preview = nil; self.message = receipt
            try self.check(token)
        }
        if locked { await refreshStatus() }
    }
    func refreshStatus() async {
        guard !busy else { return }
        busy = true; let token = generation; changed?()
        defer { busy = false; changed?() }
        do {
            try await authorize(token)
            let value = try await query("attendanceImport:uploadsForDate", args); try check(token)
            status = try HomeroomRepository.decodeImportStatus(value)
        } catch {
            status = nil
            let code = (error as? ConvexException)?.code ?? ""
            if code.contains("FORBIDDEN") || code.contains("SUPERVISOR") || code.contains("HIDDEN") || code.contains("AUTHENTICATED") || ["Unauthenticated", "USER_NOT_ACTIVE", "PASSWORD_CHANGE_REQUIRED", "IMPORT_CONTEXT_CHANGED"].contains(code) { preview = nil; locked = true; canAbandonKnown = false }
            message += " Không tải được danh sách công bố: \(error.localizedDescription). Không gửi lại."
        }
    }
    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}

import CoreFoundation

final class CameraUploadRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
