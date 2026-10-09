import Foundation

struct CatalogClass: Decodable {
    struct Teacher: Decodable {
        struct User: Decodable { let _id, name, role: String }
        let user: User
        let effectiveFrom: String
        let effectiveTo: String?
    }
    let _id, schoolYearId, code, name, status: String
    let gradeLevel, rosterCount: Int
    let notes: String?
    let currentHomeroomTeacher, upcomingHomeroomTeacher: Teacher?
}
struct AssignmentCandidate: Decodable { let _id, name, role: String }
struct RosterValidation: Decodable {
    struct Issue: Decodable { let rowNumber: Int; let field, column, code, message, severity: String }
    struct Student: Decodable {
        struct Guardian: Decodable { let relationship, fullName: String; let phone: String?; let isPrimaryContact: Bool }
        let rowNumber: Int
        let studentCode, fullName: String
        let dateOfBirth, gender, studentPhone, priorityCategory, ethnicity, hardshipNote, notes: String?
        let rosterNumber: Int?
        let guardians: [Guardian]?
        var details: String { [dateOfBirth, gender, rosterNumber.map { "STT \($0)" }, studentPhone, priorityCategory, ethnicity, hardshipNote, notes].compactMap { $0 }.joined(separator: " · ") + (guardians ?? []).map { "\n\($0.relationship) · \($0.fullName) · \($0.phone ?? "")\($0.isPrimaryContact ? " (liên hệ chính)" : "")" }.joined() }
    }
    let ok: Bool
    let issues, blockers: [Issue]
    let preview: [Student]
    let mode: String?
    let columns: [String]?
}

@MainActor
final class HomeroomManagementStore {
    typealias RPC = (String, [String: Any]) async throws -> [String: Any]
    static let lifecycle = "Nhập danh sách: .xlsx tối đa 2 MiB / 200 dòng, bản đăng ký 1 giờ. Nhập học từ ngày cam kết theo giờ Việt Nam. Tạo mới không ghi đè; hợp nhất cập nhật hồ sơ và thêm người giám hộ, không chuyển lớp. Rời màn hình không xóa file. Nhật ký tối thiểu lưu bền vững, không chứa nội dung file; nếu tắt ứng dụng/đăng xuất khi kết quả chưa rõ, KHÔNG gửi lại. Cam kết công khai không bảo đảm phát lại idempotent."
    static let columns = "ma_hoc_sinh, ho_ten, ngay_sinh, gioi_tinh, so_thu_tu, dien_thoai_hoc_sinh, ho_ten_cha, dien_thoai_cha, ho_ten_me, dien_thoai_me, ho_ten_nguoi_giam_ho, dien_thoai_nguoi_giam_ho, dien_uu_tien, dan_toc, hoan_canh_kho_khan, ghi_chu"
    let yearId, date: String
    private let query: RPC
    private let write: (String, String, [String: Any]) async throws -> [String: Any]
    private let binary: (String, Data) async throws -> String
    private let isCurrent: () -> Bool
    private let journal: HomeroomPendingJournal?
    private func send(_ kind: String, _ path: String, _ args: [String: Any]) async throws -> [String: Any] {
        var pending = args
        if pending["classId"] == nil { pending["classId"] = selectedClassId }
        try journal?.before(path, pending)
        let value = try await write(kind, path, args)
        try journal?.received(value)
        return value
    }
    private func upload(_ url: String, _ bytes: Data) async throws -> String {
        try journal?.before("storage-upload", ["classId": selectedClassId as Any])
        let storage = try await binary(url, bytes)
        try journal?.received(["storageId": storage])
        return storage
    }
    private var generation = 0
    private var owner: String?
    private var outstanding = false
    private var uncertain = false
    private(set) var busy = false
    private(set) var denied = false
    private(set) var message = lifecycle
    private(set) var classes: [CatalogClass] = []
    private(set) var candidates: [AssignmentCandidate] = []
    private(set) var roster: ClassRoster?
    private(set) var selectedClassId: String?
    private(set) var validation: RosterValidation?
    private(set) var uploadId: String?
    private(set) var storageId: String?
    private(set) var uploadStatus: String?
    private(set) var expiresAt: Double?
    private(set) var committed = false
    private(set) var acknowledgmentCount = 0
    private(set) var retiredIds: [String] = []
    private(set) var history: [String] = []
    private(set) var yearName = ""
    var changed: (() -> Void)?
    var locked: Bool { uncertain || denied }
    var canPick: Bool { !busy && !locked && uploadId == nil && storageId == nil && !outstanding }
    var canCommit: Bool { !busy && !locked && !committed && validation?.ok == true && validation?.blockers.isEmpty == true && uploadStatus == "validated" && (expiresAt ?? 0) > Date().timeIntervalSince1970 * 1000 }
    var canDiscard: Bool { !busy && !locked && (uploadId != nil || storageId != nil) }

    init(yearId: String, date: String, query: @escaping RPC, write: @escaping (String, String, [String: Any]) async throws -> [String: Any], binary: @escaping (String, Data) async throws -> String, isCurrent: @escaping () -> Bool, journal: HomeroomPendingJournal? = nil) {
        self.yearId = yearId; self.date = date; self.query = query; self.write = write; self.binary = binary; self.isCurrent = isCurrent; self.journal = journal
    }
    private func decode<Value: Decodable>(_ type: Value.Type, _ raw: Any) throws -> Value {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: raw))
    }
    private func check(_ token: Int) throws {
        try Task.checkCancellation()
        guard token == generation, isCurrent() else { throw ConvexException(code: "L5_CONTEXT_CHANGED") }
    }
    private func authorize(_ token: Int, classId: String? = nil, active: Bool = true) async throws {
        try check(token)
        let raw = try await query("users:sessionContext", [:]); try check(token)
        guard let user = raw["user"] as? [String: Any], user["status"] as? String == "active", user["mustChangePassword"] == nil || user["mustChangePassword"] as? Bool == false,
              let session = UserSession(sessionContext: raw), session.isOperationalManager, !session.userId.isEmpty, owner == nil || owner == session.userId else { throw ConvexException(code: "L5_FORBIDDEN") }
        owner = session.userId
        do {
            if let record = try journal?.restore(session.userId) {
                uncertain = true; validation = nil; message = HomeroomPendingJournal.recovery
                if record["year"] as? String == yearId && record["date"] as? String == date {
                    uploadId = record["uploadId"] as? String; storageId = record["storageId"] as? String
                    selectedClassId = record["classId"] as? String
                }
            }
        } catch { uncertain = true; validation = nil; message = HomeroomPendingJournal.recovery; throw error }
        let years = try HomeroomRepository.decodeSchoolYears(await query("schoolYears:list", [:])); try check(token)
        guard years.contains(where: { $0.id == yearId }), VietnamDate.date(from: date) != nil else { throw ConvexException(code: "INVALID_CONTEXT") }
        yearName = years.first(where: { $0.id == yearId })?.name ?? ""
        let catalog = try await query("homeroomClasses:listCatalog", ["schoolYearId": yearId, "date": date, "includeArchived": true]); try check(token)
        let fresh = try decode([CatalogClass].self, catalog["items"] ?? NSNull())
        guard fresh.allSatisfy({ $0.schoolYearId == yearId && !$0._id.isEmpty && ["active", "archived"].contains($0.status) }) else { throw ConvexException(code: "INVALID_RESPONSE") }
        classes = fresh; denied = false
        if let classId { guard let klass = fresh.first(where: { $0._id == classId }), !active || klass.status == "active" else { throw ConvexException(code: "CLASS_ARCHIVED") } }
    }
    private func run(_ body: (Int) async throws -> Void, writeOperation: Bool = false) async {
        guard !busy, !writeOperation || !locked else { return }
        busy = true; let token = generation; let priorAcknowledgments = acknowledgmentCount; changed?()
        defer { busy = false; changed?() }
        do { try await body(token) }
        catch {
            let code = (error as? ConvexException)?.code ?? "L5_UNCERTAIN"
            let forbidden = code.contains("FORBIDDEN") || code.contains("AUTHENTICATED") || ["USER_NOT_ACTIVE", "PASSWORD_CHANGE_REQUIRED", "Unauthenticated", "L5_CONTEXT_CHANGED"].contains(code)
            if forbidden { denied = true; classes = []; candidates = []; roster = nil; validation = nil; history = [] }
            let definite = forbidden || code.hasPrefix("INVALID_") && code != "INVALID_RESPONSE" || ["CLASS_ARCHIVED", "CLASS_CODE_TAKEN", "STUDENT_CODE_EXISTS", "DUPLICATE_ACTIVE_ENROLLMENT", "ENROLLMENT_YEAR_MISMATCH", "ENROLLMENT_NOT_ACTIVE", "TRANSFER_BEFORE_START", "WITHDRAW_BEFORE_START", "HOMEROOM_TEACHER_OVERLAP", "HOMEROOM_TEACHER_ALREADY_ASSIGNED", "IMPORT_VALIDATION_FAILED", "IMPORT_UPLOAD_EXPIRED", "IMPORT_UPLOAD_ALREADY_COMMITTED", "SCHOOL_YEAR_LOCKED"].contains(code)
            if outstanding && (!definite || code == "L5_CONTEXT_CHANGED") { uncertain = true }
            if uploadId != nil && (outstanding || code == "INVALID_RESPONSE") { validation = nil; uploadStatus = nil }
            outstanding = false
            let safeCode = code.count <= 80 && code.range(of: "^[A-Z0-9_]+$", options: .regularExpression) != nil ? code : forbidden ? "L5_FORBIDDEN" : "L5_READ_FAILED"
            message = acknowledgmentCount > priorAcknowledgments ? "Máy chủ đã xác nhận; tải lại thất bại. Không gửi lại. Chỉ tải dữ liệu." : uncertain ? "Kết quả gửi chưa rõ. Không gửi lại, kể cả mở lại ứng dụng. Chỉ tải trạng thái; cần quản trị kiểm tra. \(Self.lifecycle)" : "Không hoàn tất (\(definite ? safeCode : "L5_READ_FAILED")). Không tự gửi lại."
        }
    }
    func refresh(classId: String? = nil) async {
        await run { token in
            try await self.authorize(token)
            let candidates = try self.decode([AssignmentCandidate].self, await self.query("homeroomClasses:listAssignmentCandidates", [:])["items"] ?? NSNull()); try self.check(token)
            self.candidates = candidates
            if let classId { try await self.loadRoster(classId, token) }
            if self.uploadId != nil { try await self.result(token) }
        }
    }
    private func loadRoster(_ classId: String, _ token: Int) async throws {
        guard classes.contains(where: { $0._id == classId }) else { throw ConvexException(code: "CLASS_NOT_FOUND") }
        let raw = try await query("students:listByClass", ["classId": classId, "date": date, "includeSensitiveContacts": false]); try check(token)
        roster = try decode(ClassRoster.self, raw); selectedClassId = classId
    }
    func select(_ classId: String) async { guard uploadId == nil && storageId == nil else { return }; await refresh(classId: classId) }
    func showHistory(studentId: String) async {
        await run { token in try await self.authorize(token); try await self.loadHistory(studentId, token) }
    }
    private func loadHistory(_ studentId: String, _ token: Int) async throws {
        let raw = try await query("students:getScoped", ["studentId": studentId, "includeSensitiveContacts": false]); try check(token)
        guard let student = raw["student"] as? [String: Any], student["_id"] as? String == studentId, let rows = raw["enrollments"] as? [[String: Any]], rows.allSatisfy({ $0["classId"] is String && $0["startDate"] is String && $0["status"] is String }) else { throw ConvexException(code: "INVALID_RESPONSE") }
        history = rows.map { "\($0["classCode"] as? String ?? "") · \($0["startDate"] as? String ?? "") → \($0["endDate"] as? String ?? "đang mở") · \($0["status"] as? String ?? "") · \($0["transferReason"] as? String ?? "")" }
    }
    func invalidate() { generation += 1; denied = true; if outstanding { uncertain = true }; classes = []; candidates = []; roster = nil; validation = nil; history = []; changed?() }
    func discardKnown() {
        guard canDiscard else { return }
        do { try journal?.clear() } catch { uncertain = true; message = "Không lưu được nhật ký; không tiếp tục."; changed?(); return }
        retiredIds += [uploadId, storageId].compactMap { $0 }
        uploadId = nil; storageId = nil; validation = nil; uploadStatus = nil; expiresAt = nil; committed = false; message = Self.lifecycle; changed?()
    }
    func mutate(_ operation: String, classId: String?, values: [String: Any], studentId: String? = nil) async {
        await run({ token in
            let paths = ["createClass": "homeroomClasses:create", "updateClass": "homeroomClasses:update", "archive": "homeroomClasses:archive", "restore": "homeroomClasses:restore", "assign": "homeroomClasses:assignUser", "createStudent": "students:create", "transfer": "homeroomClasses:transferStudent", "withdraw": "homeroomClasses:withdrawStudent"]
            guard let path = paths[operation] else { throw ConvexException(code: "INVALID_OPERATION") }
            try await self.authorize(token, classId: classId, active: operation != "restore")
            var args = values
            switch operation {
            case "createClass", "updateClass":
                let code = (values["code"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                guard code.count <= 20, code.range(of: "^[A-Z0-9_-]+$", options: .regularExpression) != nil, let name = values["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 120, let grade = values["gradeLevel"] as? Int, (6...9).contains(grade) else { throw ConvexException(code: "INVALID_CLASS_INPUT") }
                args["code"] = code; args[operation == "createClass" ? "schoolYearId" : "id"] = operation == "createClass" ? self.yearId : classId
            case "archive", "restore": args = ["id": classId ?? ""]
            case "assign":
                let candidates = try self.decode([AssignmentCandidate].self, await self.query("homeroomClasses:listAssignmentCandidates", [:])["items"] ?? NSNull()); try self.check(token)
                guard candidates.contains(where: { $0._id == values["userId"] as? String }), VietnamDate.date(from: values["effectiveFrom"] as? String ?? "") != nil else { throw ConvexException(code: "INVALID_ASSIGNMENT") }
                args["classId"] = classId; args["assignmentType"] = "homeroom_teacher"; args["scopeKind"] = "class"
            case "createStudent":
                guard let code = values["studentCode"] as? String, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, code.count <= 30, let name = values["fullName"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 120, VietnamDate.date(from: values["startDate"] as? String ?? "") != nil else { throw ConvexException(code: "INVALID_STUDENT_INPUT") }
                if let dob = values["dateOfBirth"] as? String { guard VietnamDate.date(from: dob) != nil else { throw ConvexException(code: "INVALID_DATE") } }
                if let number = values["rosterNumber"] { guard let number = number as? Int, number > 0 else { throw ConvexException(code: "INVALID_ROSTER_NUMBER") } }
                args["classId"] = classId
            case "transfer", "withdraw":
                try await self.loadRoster(classId ?? "", token)
                guard self.roster?.rows.contains(where: { $0.enrollment._id == values["enrollmentId"] as? String && $0.student._id == studentId }) == true else { throw ConvexException(code: "INVALID_ENROLLMENT") }
                let raw = try await self.query("students:getScoped", ["studentId": studentId ?? ""]); try self.check(token)
                guard let identity = raw["student"] as? [String: Any], identity["_id"] as? String == studentId, let enrollments = raw["enrollments"] as? [[String: Any]], let enrollment = enrollments.first(where: { $0["_id"] as? String == values["enrollmentId"] as? String }), enrollment["classId"] as? String == classId, enrollment["status"] as? String == "active", enrollment["endDate"] == nil || enrollment["endDate"] is NSNull,
                      let start = enrollment["startDate"] as? String, let effective = values["date"] as? String, VietnamDate.date(from: effective) != nil, operation == "withdraw" ? effective > start : effective >= start, (values["reason"] as? String ?? "").count <= 300 else { throw ConvexException(code: "INVALID_ENROLLMENT") }
                if operation == "transfer" { guard let target = self.classes.first(where: { $0._id == values["toClassId"] as? String }), target.status == "active", target._id != classId else { throw ConvexException(code: "INVALID_TRANSFER") } }
            default: break
            }
            try await self.authorize(token, classId: classId, active: operation != "restore")
            self.outstanding = true
            let ack = try await self.send("mutation", path, args); try self.check(token)
            if ["createClass", "assign", "createStudent", "transfer"].contains(operation) { guard let id = ack["value"] as? String, !id.isEmpty else { throw ConvexException(code: "IMPORT_UNCERTAIN") } }
            else { guard ack.isEmpty else { throw ConvexException(code: "IMPORT_UNCERTAIN") } }
            try self.journal?.clear(); self.outstanding = false; self.acknowledgmentCount += 1; self.message = "Máy chủ đã xác nhận; đang tải lại. Không gửi lại thao tác vừa xác nhận."
            try await self.authorize(token)
            if let classId { try await self.loadRoster(classId, token) }
            if let studentId { try await self.loadHistory(studentId, token) }
            self.message = "Đã xác nhận và tải lại danh mục / danh sách / lịch sử từ máy chủ."
        }, writeOperation: true)
    }
    func importFile(name: String, bytes: Data, mode: String) async {
        guard canPick, let classId = selectedClassId else { return }
        await run({ token in
            guard ["create", "merge"].contains(mode), name.lowercased().hasSuffix(".xlsx"), !bytes.isEmpty, bytes.count <= 2 * 1024 * 1024, bytes.starts(with: [80,75,3,4]) else { throw ConvexException(code: "INVALID_IMPORT_FILE") }
            try await self.authorize(token, classId: classId)
            self.outstanding = true
            let raw = try await self.send("mutation", "studentRosterImport:generateUploadUrl", ["classId": classId]); try self.check(token)
            guard let url = raw["value"] as? String, let target = URL(string: url), target.scheme == "https", target.host?.isEmpty == false else { throw ConvexException(code: "IMPORT_UNCERTAIN") }
            self.outstanding = false; try await self.authorize(token, classId: classId); self.outstanding = true
            self.storageId = try await self.upload(url, bytes); try self.check(token)
            guard let storage = self.storageId, !storage.isEmpty else { throw ConvexException(code: "IMPORT_UNCERTAIN") }
            self.outstanding = false; try await self.authorize(token, classId: classId); self.outstanding = true
            let registered = try await self.send("mutation", "studentRosterImport:registerUpload", ["storageId": storage, "fileName": name, "fileSize": bytes.count, "schoolYearId": self.yearId, "classId": classId, "mode": mode]); try self.check(token)
            guard let id = registered["uploadId"] as? String, !id.isEmpty, let expiry = registered["expiresAt"] as? Double, expiry.isFinite else { throw ConvexException(code: "IMPORT_UNCERTAIN") }
            self.uploadId = id; self.expiresAt = expiry; self.outstanding = false
            try await self.authorize(token, classId: classId); self.outstanding = true
            let validated = try await self.send("action", "studentRosterImport:validateUpload", ["uploadId": id]); try self.check(token)
            let preview = try self.decode(RosterValidation.self, validated)
            let columns = Self.columns.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard (preview.mode == mode && preview.columns == columns || !preview.ok && preview.mode == nil && preview.columns == nil), preview.preview.count <= 200, preview.preview.allSatisfy({ $0.rowNumber > 0 && !$0.studentCode.isEmpty && !$0.fullName.isEmpty }), preview.ok == preview.blockers.isEmpty, preview.ok || preview.preview.isEmpty, preview.issues.filter({ $0.severity == "error" }).count == preview.blockers.count, preview.blockers.allSatisfy({ $0.severity == "error" }), preview.issues.allSatisfy({ $0.rowNumber >= 0 && ["error", "warning"].contains($0.severity) }) else { throw ConvexException(code: "IMPORT_UNCERTAIN") }
            self.outstanding = false
            try await self.authorize(token, classId: classId)
            try await self.result(token)
            guard self.uploadStatus == (preview.ok ? "validated" : "rejected") else { throw ConvexException(code: "INVALID_RESPONSE") }
            self.validation = preview
            self.message = preview.ok ? "Đã kiểm tra. Xem toàn bộ lỗi/cảnh báo và xác nhận trước khi cam kết." : "File bị từ chối; sửa Excel rồi chọn bản mới."
        }, writeOperation: true)
    }
    private func result(_ token: Int) async throws {
        guard let id = uploadId else { return }
        uploadStatus = nil
        let raw = try await query("studentRosterImport:getResult", ["uploadId": id]); try check(token)
        guard let upload = raw["upload"] as? [String: Any], upload["_id"] as? String == id, upload["uploadedBy"] as? String == owner, upload["classId"] as? String == selectedClassId, upload["schoolYearId"] as? String == yearId, let status = upload["status"] as? String, ["uploaded", "validated", "rejected", "committing", "committed"].contains(status), raw["rows"] is [[String: Any]] else { throw ConvexException(code: "INVALID_RESPONSE") }
        guard let expiry = upload["expiresAt"] as? Double, expiry.isFinite, let rows = raw["rows"] as? [[String: Any]], rows.count <= 200, rows.allSatisfy({ $0["rowNumber"] is Int && $0["payload"] is [String: Any] && $0["issues"] is [[String: Any]] }) else { throw ConvexException(code: "INVALID_RESPONSE") }
        expiresAt = expiry; uploadStatus = status; if status == "committed" { committed = true; validation = nil }
    }
    func commit(confirmed: Bool) async {
        guard confirmed, canCommit, let id = uploadId, let classId = selectedClassId else { return }
        await run({ token in
            try await self.authorize(token, classId: classId)
            try await self.result(token)
            guard self.uploadStatus == "validated", !self.committed, (self.expiresAt ?? 0) > Date().timeIntervalSince1970 * 1000 else { throw ConvexException(code: "IMPORT_UPLOAD_EXPIRED") }
            try await self.authorize(token, classId: classId); self.outstanding = true
            let ack = try await self.send("action", "studentRosterImport:commit", ["uploadId": id]); try self.check(token)
            guard ack["uploadId"] as? String == id, ack["committed"] as? Bool == true, let count = ack["count"] as? Int, count >= 0, count <= 200 else { throw ConvexException(code: "IMPORT_UNCERTAIN") }
            try self.journal?.clear()
            self.outstanding = false; self.acknowledgmentCount += 1; self.committed = true; self.validation = nil; self.message = "Máy chủ đã xác nhận cam kết \(count) dòng. Không cam kết lại."
            try await self.result(token); try await self.authorize(token); try await self.loadRoster(classId, token)
        }, writeOperation: true)
    }
}
