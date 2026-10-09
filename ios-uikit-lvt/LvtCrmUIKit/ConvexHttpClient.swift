import Foundation

struct ConvexException: Error, LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }

    init(code: String, message: String? = nil) {
        self.code = code
        self.message = message ?? ConvexHttpClient.humanize(code)
    }
}

actor ConvexHttpClient {
    private let baseURL: String
    private let tokenProvider: @Sendable () -> String?
    private let refreshCredentialsProvider: @Sendable () -> CredentialSnapshot?
    private let onTokensRefreshed: @Sendable (CredentialSnapshot, String, String) -> Bool
    private let session: URLSession
    private let importSession: URLSession
    private var inFlightRefresh: Task<String?, Never>?

    init(
        baseURL: String,
        tokenProvider: @escaping @Sendable () -> String?,
        refreshCredentialsProvider: @escaping @Sendable () -> CredentialSnapshot?,
        onTokensRefreshed: @escaping @Sendable (CredentialSnapshot, String, String) -> Bool,
        sessionOverride: URLSession? = nil
    ) {
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.tokenProvider = tokenProvider
        self.refreshCredentialsProvider = refreshCredentialsProvider
        self.onTokensRefreshed = onTokensRefreshed
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = false
        session = sessionOverride ?? URLSession(configuration: configuration)
        importSession = sessionOverride ?? URLSession(configuration: configuration, delegate: CameraUploadRedirectGuard(), delegateQueue: nil)
    }

    func query(_ path: String, args: [String: Any] = [:], authenticated: Bool = true) async throws -> [String: Any] {
        try await call(kind: "query", path: path, args: args, authenticated: authenticated)
    }

    func mutation(_ path: String, args: [String: Any] = [:], authenticated: Bool = true) async throws -> [String: Any] {
        try await call(kind: "mutation", path: path, args: args, authenticated: authenticated)
    }
    func importCall(_ kind: String, path: String, args: [String: Any]) async throws -> [String: Any] {
        try await call(kind: kind, path: path, args: args, authenticated: true, noRetry: true)
    }
    static func validateHomeroomAcknowledgment(_ path: String, envelope: [String: Any], statusCode: Int) throws {
        guard (200..<300).contains(statusCode), envelope["status"] as? String == "success", let value = envelope["value"] else { throw ConvexException(code: "INVALID_MUTATION_ACK") }
        if ["students:updateContacts", "students:removeGuardian"].contains(path) {
            guard value is NSNull else { throw ConvexException(code: "INVALID_MUTATION_ACK") }
        } else if path == "students:upsertGuardian" {
            guard let id = value as? String, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConvexException(code: "INVALID_MUTATION_ACK") }
        } else { guard value is [String: Any] else { throw ConvexException(code: "INVALID_MUTATION_ACK") } }
    }

    func action(_ path: String, args: [String: Any] = [:], authenticated: Bool = true) async throws -> [String: Any] {
        try await call(kind: "action", path: path, args: args, authenticated: authenticated)
    }

    func actionWithToken(_ path: String, args: [String: Any], accessToken: String) async throws -> [String: Any] {
        try await call(kind: "action", path: path, args: args, authenticated: true, accessTokenOverride: accessToken)
    }

    func mutationWithToken(_ path: String, args: [String: Any], accessToken: String) async throws -> [String: Any] {
        try await call(kind: "mutation", path: path, args: args, authenticated: true, accessTokenOverride: accessToken)
    }

    private func call(
        kind: String,
        path: String,
        args: [String: Any],
        authenticated: Bool,
        retried: Bool = false,
        accessTokenOverride: String? = nil,
        noRetry: Bool = false
    ) async throws -> [String: Any] {
        guard let url = URL(string: "\(baseURL)/api/\(kind)") else {
            throw ConvexException(code: "INVALID_URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "path": path,
            "args": args,
            "format": "json",
        ])

        let requestToken = authenticated ? (accessTokenOverride ?? tokenProvider()) : nil
        if authenticated, let requestToken, !requestToken.isEmpty {
            request.setValue("Bearer \(requestToken)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await (noRetry ? importSession : session).data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !noRetry, authenticated, accessTokenOverride == nil, statusCode == 401, !retried,
           let refreshed = await tryRefresh(failedAccessToken: requestToken) {
            return try await call(
                kind: kind, path: path, args: args, authenticated: true,
                retried: true, accessTokenOverride: refreshed
            )
        }

        let json = try parseJSONObject(data)
        if (json["status"] as? String) == "success" {
            if noRetry { try Self.validateImportEnvelope(path, envelope: json, statusCode: statusCode) }
            if kind == "mutation", ["students:updateContacts", "students:removeGuardian", "students:upsertGuardian", "studentAttendance:setDisposition", "studentAttendance:setDispositionMany"].contains(path) {
                try Self.validateHomeroomAcknowledgment(path, envelope: json, statusCode: statusCode)
            }
            return unwrapValue(json["value"])
        }
        let errorMessage = (json["errorData"] as? String)?.nilIfBlank
            ?? (json["errorMessage"] as? String)?.nilIfBlank
            ?? (json["error"] as? String)?.nilIfBlank
            ?? "CONVEX_ERROR"
        let unauthorized = statusCode == 401
            || errorMessage.localizedCaseInsensitiveContains("Unauthenticated")
            || errorMessage.localizedCaseInsensitiveContains("Authentication")
        if !noRetry, authenticated, accessTokenOverride == nil, unauthorized, !retried,
           let refreshed = await tryRefresh(failedAccessToken: requestToken) {
            return try await call(
                kind: kind, path: path, args: args, authenticated: true,
                retried: true, accessTokenOverride: refreshed
            )
        }
        throw ConvexException(code: noRetry ? Self.extractImportCode(errorMessage) : Self.extractCode(errorMessage), message: noRetry ? Self.humanizeImport(errorMessage) : Self.humanize(errorMessage))
    }

    private func tryRefresh(failedAccessToken: String?) async -> String? {
        if let inFlightRefresh {
            return await inFlightRefresh.value
        }
        let task = Task { await self.performRefresh(failedAccessToken: failedAccessToken) }
        inFlightRefresh = task
        let result = await task.value
        inFlightRefresh = nil
        return result
    }
    static func validateImportEnvelope(_ path: String, envelope: [String: Any], statusCode: Int) throws {
        let stringPaths = ["attendanceImport:generateUploadUrl", "studentRosterImport:generateUploadUrl", "homeroomClasses:create", "homeroomClasses:assignUser", "homeroomClasses:transferStudent", "students:create"]
        let nullPaths = ["homeroomClasses:update", "homeroomClasses:archive", "homeroomClasses:restore", "homeroomClasses:withdrawStudent"]
        let correct = stringPaths.contains(path) ? envelope["value"] is String : nullPaths.contains(path) ? envelope["value"] is NSNull : envelope["value"] is [String: Any]
        guard (200..<300).contains(statusCode), envelope["status"] as? String == "success", correct else { throw ConvexException(code: "IMPORT_UNCERTAIN") }
    }

    private func performRefresh(failedAccessToken: String?) async -> String? {
        guard let expected = refreshCredentialsProvider() else { return nil }
        if let failedAccessToken, !failedAccessToken.isEmpty, expected.accessToken != failedAccessToken {
            return expected.accessToken
        }
        guard let failedAccessToken, !failedAccessToken.isEmpty else { return nil }
        do {
            guard let url = URL(string: "\(baseURL)/api/action") else { return nil }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "path": "auth:signIn",
                "args": ["refreshToken": expected.refreshToken],
                "format": "json",
            ])
            let (data, _) = try await session.data(for: request)
            let json = try parseJSONObject(data)
            guard (json["status"] as? String) == "success",
                  let value = json["value"] as? [String: Any],
                  let tokens = value["tokens"] as? [String: Any],
                  let access = tokens["token"] as? String,
                  let refresh = tokens["refreshToken"] as? String else { return nil }
            return onTokensRefreshed(expected, access, refresh) ? access : nil
        } catch {
            return nil
        }
    }

    private func unwrapValue(_ value: Any?) -> [String: Any] {
        switch value {
        case nil, is NSNull: return [:]
        case let object as [String: Any]: return object
        case let array as [Any]: return ["items": array]
        case let bool as Bool: return ["ok": bool]
        case let number as NSNumber: return ["value": number]
        case let string as String: return ["value": string]
        default: return ["value": "\(value!)"]
        }
    }

    private func parseJSONObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConvexException(code: "INVALID_JSON", message: "Phản hồi Convex không hợp lệ.")
        }
        return object
    }

    static func extractImportCode(_ message: String) -> String {
        let management = ["CLASS_CODE_TAKEN", "INVALID_CLASS_CODE", "INVALID_GRADE_LEVEL", "SCHOOL_YEAR_LOCKED", "STUDENT_CODE_EXISTS", "INVALID_STUDENT_CODE", "ENROLLMENT_NOT_FOUND", "ENROLLMENT_NOT_ACTIVE", "ENROLLMENT_YEAR_MISMATCH", "DUPLICATE_ACTIVE_ENROLLMENT", "TRANSFER_BEFORE_START", "WITHDRAW_BEFORE_START", "INVALID_TRANSFER", "INVALID_REASON", "HOMEROOM_TEACHER_OVERLAP", "HOMEROOM_TEACHER_ALREADY_ASSIGNED", "ASSIGNMENT_BEFORE_START", "INVALID_ASSIGNMENT_TYPE", "INVALID_ASSIGNMENT_SCOPE", "USER_NOT_FOUND", "IMPORT_VALIDATION_FAILED", "IMPORT_UPLOAD_ALREADY_COMMITTED", "IMPORT_UPLOAD_IN_PROGRESS", "STUDENT_ENROLLED_OTHER_CLASS"]
        if let code = management.first(where: { message.contains($0) }) { return code }
        let known = ["ATTENDANCE_REPLACE_MODE_REQUIRED", "ATTENDANCE_DATE_OUTSIDE_YEAR", "ATTENDANCE_DATE_IN_FUTURE", "ATTENDANCE_TEMPLATE_HEADER_NOT_FOUND", "ATTENDANCE_TEMPLATE_COLUMNS_MISSING", "INVALID_IMPORT_FILE", "IMPORT_FILE_TOO_LARGE", "IMPORT_FILE_EMPTY", "IMPORT_TOO_MANY_ROWS", "IMPORT_UPLOAD_EXPIRED", "IMPORT_UPLOAD_NOT_FOUND", "IMPORT_ROWS_UNRESOLVED", "INVALID_REPLACE_MODE", "SCHOOL_YEAR_NOT_FOUND", "INVALID_DATE", "SUPERVISOR_REQUIRED", "HOMEROOM_MENU_HIDDEN", "HOMEROOM_SCOPE_FORBIDDEN"]
        return known.first { message.contains($0) } ?? extractCode(message)
    }
    static func humanizeImport(_ message: String) -> String {
        let code = extractImportCode(message)
        switch code {
        case "INVALID_IMPORT_FILE", "IMPORT_FILE_EMPTY", "IMPORT_FILE_TOO_LARGE": return "File Excel không hợp lệ, rỗng hoặc quá 4 MiB. Kiểm tra file .xlsx camera toàn trường."
        case "ATTENDANCE_TEMPLATE_HEADER_NOT_FOUND", "ATTENDANCE_TEMPLATE_COLUMNS_MISSING": return "Không tìm thấy mẫu/cột camera: Lớp học, Tên học sinh, Ngày sinh, Trạng thái điểm danh."
        case "IMPORT_TOO_MANY_ROWS": return "File vượt quá 3.000 dòng; chuẩn bị file nhỏ hơn."
        case "IMPORT_UPLOAD_EXPIRED": return "Bản đăng ký quá hạn 2 giờ; không thể công bố. File không được ứng dụng tự xóa."
        case "IMPORT_UPLOAD_NOT_FOUND": return "Không tìm thấy bản đăng ký; không tự đăng ký/gửi lại file."
        case "IMPORT_ROWS_UNRESOLVED": return "Không còn lớp có thể công bố; kiểm tra lại bản xem trước."
        case "ATTENDANCE_REPLACE_MODE_REQUIRED": return "Dữ liệu ngày này đã thay đổi; kiểm tra lại bản xem trước và chọn lại chế độ trước khi xác nhận."
        case "ATTENDANCE_DATE_OUTSIDE_YEAR", "ATTENDANCE_DATE_IN_FUTURE", "SCHOOL_YEAR_NOT_FOUND", "INVALID_DATE": return "Năm/ngày học không hợp lệ hoặc ngày ở tương lai; chọn lại ngữ cảnh."
        case "SUPERVISOR_REQUIRED", "HOMEROOM_MENU_HIDDEN": return "Chỉ Giám thị hoặc quản trị viên được nhập camera."
        case "INVALID_REPLACE_MODE": return "Chế độ xử lý dữ liệu trùng không hợp lệ; chọn lại trong ba chế độ."
        default: return humanize(message)
        }
    }
    static func extractCode(_ message: String) -> String {
        let known = [
            "INVALID_PHONE", "INVALID_NAME", "INVALID_TEXT", "INVALID_DISPOSITION_NOTE", "INVALID_DISPOSITION", "CORRECTION_REASON_REQUIRED", "GUARDIAN_LIMIT", "ATTENDANCE_DAY_NOT_FOUND", "CLASS_NOT_FOUND", "STUDENT_NOT_FOUND", "GUARDIAN_NOT_FOUND", "CLASS_ARCHIVED", "DISPOSITION_NOT_ABSENT",
            "INVALID_CREDENTIALS", "InvalidAccountId", "InvalidSecret", "Invalid credentials", "USER_NOT_ACTIVE",
            "ACCOUNT_LOCKED", "PASSWORD_TOO_SHORT", "PASSWORD_CHANGE_FAILED", "PASSWORD_CHANGED_SYNC_PENDING",
            "PASSWORD_CHANGE_REQUIRED", "PASSWORD_RESET_FAILED", "PASSWORD_RESET_EMAIL_FAILED",
            "MAIL_NOT_CONFIGURED", "MAIL_AUTH_FAILED", "PUBLIC_SIGNUP_DISABLED", "INVALID_EMAIL",
            "INVALID_AUTH_FLOW",
            "DUTY_CHAT_EMPTY", "WORK_CHAT_EMPTY", "DUTY_CHAT_TOO_LONG", "WORK_CHAT_TOO_LONG",
            "DUTY_CHAT_RECALL_TOO_LATE", "WORK_CHAT_RECALL_TOO_LATE",
            "DUTY_CHAT_RECALL_FORBIDDEN", "WORK_CHAT_RECALL_FORBIDDEN",
            "DUTY_CHAT_FORBIDDEN", "WORK_CHAT_FORBIDDEN",
            "WORK_DOCUMENT_IMMUTABLE", "WORK_UPDATE_FORBIDDEN", "WORK_DOCUMENT_NOT_FOUND",
            "FORBIDDEN", "UNAUTHENTICATED", "CANNOT_REVOKE_CURRENT_SESSION",
            "SESSION_NOT_FOUND", "DOCUMENT_TYPE_REQUIRED", "INVALID_DOCUMENT_TYPE", "SESSION_TIMEOUT",
            "INVALID_AVATAR_FILE", "AVATAR_FILE_TOO_LARGE", "AVATAR_UPLOAD_NOT_FOUND", "AVATAR_NOT_FOUND",
            "AVATAR_UPLOAD_FAILED",
        ]
        return known.first { message.localizedCaseInsensitiveContains($0) } ?? message
    }

    static func humanize(_ message: String) -> String {
        let code = extractCode(message)
        switch true {
        case code == "INVALID_PHONE": return "Số điện thoại không hợp lệ (6–20 ký tự)."
        case code == "INVALID_NAME": return "Họ tên phải có 1–120 ký tự."
        case code == "INVALID_TEXT": return "Ghi chú liên hệ tối đa 300 ký tự."
        case code == "INVALID_DISPOSITION_NOTE": return "Ghi chú phân loại tối đa 500 ký tự."
        case code == "CORRECTION_REASON_REQUIRED": return "Cần lý do hoặc ghi chú."
        case code == "GUARDIAN_LIMIT": return "Tối đa 6 người giám hộ đang hoạt động."
        case code == "INVALID_AVATAR_FILE":
            return "Ảnh đại diện phải là PNG, JPG hoặc WEBP."
        case code == "AVATAR_FILE_TOO_LARGE":
            return "Ảnh đại diện không được vượt quá 2MB."
        case code == "AVATAR_UPLOAD_NOT_FOUND":
            return "Không tìm thấy ảnh vừa tải lên. Vui lòng chọn lại."
        case code == "AVATAR_NOT_FOUND":
            return "Chưa có ảnh đại diện."
        case code == "AVATAR_UPLOAD_FAILED":
            return "Không thể cập nhật ảnh đại diện. Vui lòng thử lại."
        case code.localizedCaseInsensitiveContains("Invalid"), code.localizedCaseInsensitiveContains("credentials"):
            return "Email hoặc mật khẩu không đúng."
        case code == "ACCOUNT_LOCKED":
            return "Tài khoản đã bị khóa do đăng nhập sai quá số lần. Liên hệ quản trị viên để mở khóa."
        case code == "USER_NOT_ACTIVE": return "Tài khoản chưa được kích hoạt hoặc đã bị khóa."
        case code == "PASSWORD_TOO_SHORT": return "Mật khẩu phải có ít nhất 8 ký tự."
        case code == "PASSWORD_CHANGE_FAILED": return "Không đổi được mật khẩu. Thử lại sau."
        case code == "PASSWORD_CHANGED_SYNC_PENDING": return "Mật khẩu đã đổi nhưng hồ sơ chưa đồng bộ. Đăng nhập lại."
        case code == "PASSWORD_CHANGE_REQUIRED": return "Bạn cần đổi mật khẩu trước khi tiếp tục."
        case code == "SESSION_TIMEOUT":
            return "Không kết nối được máy chủ. Thử mở lại ứng dụng."
        case code == "PASSWORD_RESET_FAILED": return "Không thể đặt lại mật khẩu. Thử lại sau."
        case code == "PASSWORD_RESET_EMAIL_FAILED":
            return "Đã tạo mật khẩu tạm nhưng chưa gửi được email. Liên hệ quản trị viên."
        case code == "MAIL_NOT_CONFIGURED", code == "MAIL_AUTH_FAILED":
            return "Hệ thống chưa gửi được email. Liên hệ quản trị viên."
        case code == "INVALID_EMAIL": return "Email không hợp lệ."
        case code == "ASSIGNMENT_CREATE_FORBIDDEN":
            return "Bạn không có quyền tạo công tác hoặc công việc."
        case code == "INVALID_WORK_TITLE": return "Vui lòng nhập tên công việc (tối đa 200 ký tự)."
        case code == "INVALID_WORK_CONTENT": return "Nội dung công việc bắt buộc và tối đa 2.000 ký tự."
        case code == "INVALID_WORK_DEADLINE": return "Hạn chót công việc không hợp lệ."
        case code == "INVALID_WORK_ASSIGNEE":
            return "Người thực hiện phải cùng phòng ban và có cấp sao thấp hơn bạn."
        case code == "INVALID_WORK_FILE": return "Tệp công văn không đúng định dạng được hỗ trợ."
        case code == "DOCUMENT_TYPE_REQUIRED": return "Vui lòng chọn loại văn bản cho file đính kèm."
        case code == "INVALID_DOCUMENT_TYPE": return "Loại văn bản không hợp lệ hoặc đã ngưng sử dụng."
        case code == "WORK_ASSIGNMENTS_REQUIRED": return "Vui lòng thêm ít nhất một phân công."
        case code == "WORK_DEPARTMENT_FORBIDDEN":
            return "Tổ trưởng/tổ phó chỉ được giao công việc cho cấp dưới, không chọn cả phòng ban."
        case code == "WORK_DEPARTMENT_DUPLICATE":
            return "Mỗi phòng ban chỉ được nhận một đầu việc trong cùng công văn."
        case code == "NOT_A_SUBORDINATE":
            return "Chỉ được giao hoặc cập nhật cấp dưới trong cùng phòng ban."
        case code == "DUTY_CHAT_EMPTY", code == "WORK_CHAT_EMPTY":
            return "Vui lòng nhập nội dung tin nhắn."
        case code == "DUTY_CHAT_TOO_LONG", code == "WORK_CHAT_TOO_LONG":
            return "Tin nhắn quá dài (tối đa 4000 ký tự)."
        case code == "DUTY_CHAT_RECALL_TOO_LATE", code == "WORK_CHAT_RECALL_TOO_LATE":
            return "Đã quá 15 phút, không thể thu hồi tin nhắn này."
        case code == "DUTY_CHAT_RECALL_FORBIDDEN", code == "WORK_CHAT_RECALL_FORBIDDEN":
            return "Bạn chỉ có thể thu hồi tin nhắn của mình."
        case code == "DUTY_CHAT_FORBIDDEN", code == "WORK_CHAT_FORBIDDEN":
            return "Bạn không có quyền trao đổi mục này."
        case code == "WORK_DOCUMENT_IMMUTABLE":
            return "Đã có người nộp · Không thể sửa hoặc xóa"
        case code == "WORK_UPDATE_FORBIDDEN":
            return "Bạn không có quyền sửa hoặc xóa công việc này."
        case code == "WORK_DOCUMENT_NOT_FOUND":
            return "Công việc không còn tồn tại."
        case code.localizedCaseInsensitiveContains("FORBIDDEN"):
            return "Bạn không có quyền thực hiện thao tác này."
        default: return String(code.prefix(180))
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
