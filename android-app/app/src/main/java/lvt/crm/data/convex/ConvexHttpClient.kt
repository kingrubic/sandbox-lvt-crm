package lvt.crm.data.convex

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit
import lvt.crm.data.auth.CredentialSnapshot

class ConvexException(val code: String, message: String = code) : Exception(message)

interface AuthApi {
    suspend fun query(path: String, args: JSONObject = JSONObject(), authenticated: Boolean = true): JSONObject
    suspend fun action(path: String, args: JSONObject = JSONObject(), authenticated: Boolean = true): JSONObject
    suspend fun actionWithToken(path: String, args: JSONObject, accessToken: String): JSONObject
}

class ConvexHttpClient(
    private val baseUrl: String,
    private val tokenProvider: () -> String?,
    private val onTokensRefreshed: ((CredentialSnapshot, String, String) -> Boolean)? = null,
    private val refreshCredentialsProvider: (() -> CredentialSnapshot?)? = null,
) : AuthApi {
    private val jsonMedia = "application/json; charset=utf-8".toMediaType()
    private val refreshMutex = Mutex()
    private val http = OkHttpClient.Builder()
        .connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(45, TimeUnit.SECONDS)
        .writeTimeout(45, TimeUnit.SECONDS)
        .build()
    private val importHttp = http.newBuilder().retryOnConnectionFailure(false).followRedirects(false).followSslRedirects(false).build()

    suspend fun importCall(kind: String, path: String, args: JSONObject): JSONObject =
        call(kind, path, args, authenticated = true, noRetry = true)

    override suspend fun query(path: String, args: JSONObject, authenticated: Boolean): JSONObject =
        call("query", path, args, authenticated)

    suspend fun mutation(path: String, args: JSONObject = JSONObject(), authenticated: Boolean = true): JSONObject =
        call("mutation", path, args, authenticated)

    override suspend fun action(path: String, args: JSONObject, authenticated: Boolean): JSONObject =
        call("action", path, args, authenticated)

    suspend fun mutationWithToken(path: String, args: JSONObject, accessToken: String): JSONObject =
        call("mutation", path, args, authenticated = true, accessTokenOverride = accessToken)

    override suspend fun actionWithToken(path: String, args: JSONObject, accessToken: String): JSONObject =
        call("action", path, args, authenticated = true, accessTokenOverride = accessToken)

    private suspend fun call(
        kind: String,
        path: String,
        args: JSONObject,
        authenticated: Boolean,
        retried: Boolean = false,
        accessTokenOverride: String? = null,
        noRetry: Boolean = false,
    ): JSONObject = withContext(Dispatchers.IO) {
        val body = JSONObject()
            .put("path", path)
            .put("args", args)
            .put("format", "json")
            .toString()
            .toRequestBody(jsonMedia)

        val builder = Request.Builder()
            .url("${baseUrl.trimEnd('/')}/api/$kind")
            .post(body)
            .header("Content-Type", "application/json")

        val requestToken = if (authenticated) accessTokenOverride ?: tokenProvider() else null
        if (authenticated) {
            val token = requestToken
            if (!token.isNullOrBlank()) {
                builder.header("Authorization", "Bearer $token")
            }
        }

        (if (noRetry) importHttp else http).newCall(builder.build()).execute().use { response ->
            val raw = response.body?.string().orEmpty()
            if (!noRetry && authenticated && accessTokenOverride == null && response.code == 401 && !retried) {
                val refreshedToken = tryRefresh(requestToken)
                if (refreshedToken != null) {
                    return@withContext call(
                        kind,
                        path,
                        args,
                        authenticated = true,
                        retried = true,
                        accessTokenOverride = refreshedToken,
                    )
                }
            }
            val json = runCatching { JSONObject(raw) }.getOrElse {
                throw ConvexException("HTTP_${response.code}", "Phản hồi Convex không hợp lệ (${response.code}).")
            }

            if (json.optString("status") == "success") {
                if (noRetry) validateImportEnvelope(path, json, response.isSuccessful)
                if (kind == "mutation" && path in setOf("students:updateContacts", "students:removeGuardian", "students:upsertGuardian", "studentAttendance:setDisposition", "studentAttendance:setDispositionMany")) {
                    validateHomeroomAcknowledgment(path, json, response.isSuccessful)
                }
                val value = json.opt("value")
                return@withContext when (value) {
                    null, JSONObject.NULL -> JSONObject()
                    is JSONObject -> value
                    is JSONArray -> JSONObject().put("items", value)
                    is Boolean -> JSONObject().put("ok", value)
                    is Number, is String -> JSONObject().put("value", value)
                    else -> JSONObject().put("value", value.toString())
                }
            }

            val errorMessage = (if (noRetry) json.opt("errorData") as? String else null)?.takeIf { it.isNotBlank() } ?: json.optString("errorMessage").ifBlank {
                json.optString("error").ifBlank { "CONVEX_ERROR" }
            }
            val unauthorized = response.code == 401 ||
                errorMessage.contains("Unauthenticated", ignoreCase = true) ||
                errorMessage.contains("Authentication", ignoreCase = true)

            if (!noRetry && authenticated && accessTokenOverride == null && unauthorized && !retried) {
                val refreshedToken = tryRefresh(requestToken)
                if (refreshedToken != null) {
                    return@withContext call(
                        kind,
                        path,
                        args,
                        authenticated = true,
                        retried = true,
                        accessTokenOverride = refreshedToken,
                    )
                }
            }

            throw ConvexException(if (noRetry) extractImportCode(errorMessage) else extractCode(errorMessage), if (noRetry) humanizeImport(errorMessage) else humanize(errorMessage))
        }
    }

    private suspend fun tryRefresh(failedAccessToken: String?): String? = refreshMutex.withLock {
        val expected = refreshCredentialsProvider?.invoke() ?: return@withLock null
        if (failedAccessToken.isNullOrBlank() || expected.accessToken != failedAccessToken) return@withLock null
        val updateTokens = onTokensRefreshed ?: return@withLock null
        val refreshed = try {
            val body = JSONObject()
                .put("path", "auth:signIn")
                .put("args", JSONObject().put("refreshToken", expected.refreshToken))
                .put("format", "json")
                .toString()
                .toRequestBody(jsonMedia)
            val request = Request.Builder()
                .url("${baseUrl.trimEnd('/')}/api/action")
                .post(body)
                .header("Content-Type", "application/json")
                .build()
            http.newCall(request).execute().use { response ->
                val raw = response.body?.string().orEmpty()
                val json = JSONObject(raw)
                if (json.optString("status") != "success") return@use null
                val tokens = json.getJSONObject("value").getJSONObject("tokens")
                val access = tokens.getString("token")
                val nextRefresh = tokens.getString("refreshToken")
                access to nextRefresh
            }
        } catch (_: Exception) {
            return@withLock null
        } ?: return@withLock null
        val persisted = try {
            updateTokens(expected, refreshed.first, refreshed.second)
        } catch (e: Exception) {
            throw ConvexException("TOKEN_PERSIST_FAILED", e.message ?: "TOKEN_PERSIST_FAILED")
        }
        if (persisted) refreshed.first else null
    }

    companion object {
        fun validateImportEnvelope(path: String, envelope: JSONObject, successful: Boolean) {
            val strings = setOf("attendanceImport:generateUploadUrl", "studentRosterImport:generateUploadUrl", "homeroomClasses:create", "homeroomClasses:assignUser", "homeroomClasses:transferStudent", "students:create")
            val nulls = setOf("homeroomClasses:update", "homeroomClasses:archive", "homeroomClasses:restore", "homeroomClasses:withdrawStudent")
            val correct = when (path) {
                in strings -> envelope.opt("value") is String
                in nulls -> envelope.has("value") && envelope.opt("value") === JSONObject.NULL
                else -> envelope.opt("value") is JSONObject
            }
            if (!successful || envelope.opt("status") != "success" || !correct) throw ConvexException("IMPORT_UNCERTAIN")
        }
        internal fun validateHomeroomAcknowledgment(path: String, envelope: JSONObject, successfulHttp: Boolean) {
            require(successfulHttp && envelope.opt("status") == "success" && envelope.has("value")) { "INVALID_MUTATION_ACK" }
            when (path) {
                "students:updateContacts", "students:removeGuardian" -> require(envelope.get("value") == JSONObject.NULL) { "INVALID_MUTATION_ACK" }
                "students:upsertGuardian" -> require(envelope.get("value") is String && envelope.getString("value").isNotBlank()) { "INVALID_MUTATION_ACK" }
                else -> require(envelope.get("value") is JSONObject) { "INVALID_MUTATION_ACK" }
            }
        }
        fun extractImportCode(message: String): String {
            val management = listOf("CLASS_CODE_TAKEN", "INVALID_CLASS_CODE", "INVALID_GRADE_LEVEL", "SCHOOL_YEAR_LOCKED", "STUDENT_CODE_EXISTS", "INVALID_STUDENT_CODE", "ENROLLMENT_NOT_FOUND", "ENROLLMENT_NOT_ACTIVE", "ENROLLMENT_YEAR_MISMATCH", "DUPLICATE_ACTIVE_ENROLLMENT", "TRANSFER_BEFORE_START", "WITHDRAW_BEFORE_START", "INVALID_TRANSFER", "INVALID_REASON", "HOMEROOM_TEACHER_OVERLAP", "HOMEROOM_TEACHER_ALREADY_ASSIGNED", "ASSIGNMENT_BEFORE_START", "INVALID_ASSIGNMENT_TYPE", "INVALID_ASSIGNMENT_SCOPE", "USER_NOT_FOUND", "IMPORT_VALIDATION_FAILED", "IMPORT_UPLOAD_ALREADY_COMMITTED", "IMPORT_UPLOAD_IN_PROGRESS", "STUDENT_ENROLLED_OTHER_CLASS")
            management.firstOrNull { message.contains(it) }?.let { return it }
            val known = listOf("ATTENDANCE_REPLACE_MODE_REQUIRED", "ATTENDANCE_DATE_OUTSIDE_YEAR", "ATTENDANCE_DATE_IN_FUTURE", "ATTENDANCE_TEMPLATE_HEADER_NOT_FOUND", "ATTENDANCE_TEMPLATE_COLUMNS_MISSING", "INVALID_IMPORT_FILE", "IMPORT_FILE_TOO_LARGE", "IMPORT_FILE_EMPTY", "IMPORT_TOO_MANY_ROWS", "IMPORT_UPLOAD_EXPIRED", "IMPORT_UPLOAD_NOT_FOUND", "IMPORT_ROWS_UNRESOLVED", "INVALID_REPLACE_MODE", "SCHOOL_YEAR_NOT_FOUND", "INVALID_DATE", "SUPERVISOR_REQUIRED", "HOMEROOM_MENU_HIDDEN", "HOMEROOM_SCOPE_FORBIDDEN")
            return known.firstOrNull { message.contains(it) } ?: extractCode(message)
        }
        fun humanizeImport(message: String): String = when (extractImportCode(message)) {
            "INVALID_IMPORT_FILE", "IMPORT_FILE_EMPTY", "IMPORT_FILE_TOO_LARGE" -> "File Excel không hợp lệ, rỗng hoặc quá 4 MiB. Kiểm tra file .xlsx camera toàn trường."
            "ATTENDANCE_TEMPLATE_HEADER_NOT_FOUND", "ATTENDANCE_TEMPLATE_COLUMNS_MISSING" -> "Không tìm thấy mẫu/cột camera: Lớp học, Tên học sinh, Ngày sinh, Trạng thái điểm danh."
            "IMPORT_TOO_MANY_ROWS" -> "File vượt quá 3.000 dòng; chuẩn bị file nhỏ hơn."
            "IMPORT_UPLOAD_EXPIRED" -> "Bản đăng ký quá hạn 2 giờ; không thể công bố. File không được ứng dụng tự xóa."
            "IMPORT_UPLOAD_NOT_FOUND" -> "Không tìm thấy bản đăng ký; không tự đăng ký/gửi lại file."
            "IMPORT_ROWS_UNRESOLVED" -> "Không còn lớp có thể công bố; kiểm tra lại bản xem trước."
            "ATTENDANCE_REPLACE_MODE_REQUIRED" -> "Dữ liệu ngày này đã thay đổi; kiểm tra lại bản xem trước và chọn lại chế độ trước khi xác nhận."
            "ATTENDANCE_DATE_OUTSIDE_YEAR", "ATTENDANCE_DATE_IN_FUTURE", "SCHOOL_YEAR_NOT_FOUND", "INVALID_DATE" -> "Năm/ngày học không hợp lệ hoặc ngày ở tương lai; chọn lại ngữ cảnh."
            "SUPERVISOR_REQUIRED", "HOMEROOM_MENU_HIDDEN" -> "Chỉ Giám thị hoặc quản trị viên được nhập camera."
            "INVALID_REPLACE_MODE" -> "Chế độ xử lý dữ liệu trùng không hợp lệ; chọn lại trong ba chế độ."
            else -> humanize(message)
        }
        fun extractCode(message: String): String {
            val known = listOf(
                "INVALID_PHONE", "INVALID_NAME", "INVALID_TEXT", "INVALID_DISPOSITION_NOTE", "INVALID_DISPOSITION", "CORRECTION_REASON_REQUIRED", "GUARDIAN_LIMIT", "ATTENDANCE_DAY_NOT_FOUND", "CLASS_NOT_FOUND", "STUDENT_NOT_FOUND", "GUARDIAN_NOT_FOUND", "CLASS_ARCHIVED", "DISPOSITION_NOT_ABSENT",
                "InvalidAccountId",
                "InvalidSecret",
                "Invalid credentials",
                "USER_NOT_ACTIVE",
                "ACCOUNT_LOCKED",
                "INVALID_AVATAR_FILE",
                "AVATAR_FILE_TOO_LARGE",
                "AVATAR_UPLOAD_NOT_FOUND",
                "AVATAR_NOT_FOUND",
                "AVATAR_UPLOAD_FAILED",
                "PASSWORD_TOO_SHORT",
                "PASSWORD_CHANGE_FAILED",
                "PASSWORD_CHANGED_SYNC_PENDING",
                "PASSWORD_CHANGE_REQUIRED",
                "PASSWORD_RESET_FAILED",
                "PASSWORD_RESET_EMAIL_FAILED",
                "MAIL_NOT_CONFIGURED",
                "MAIL_AUTH_FAILED",
                "PUBLIC_SIGNUP_DISABLED",
                "INVALID_EMAIL",
                "INVALID_AUTH_FLOW",
                "DUTY_CHAT_EMPTY",
                "WORK_CHAT_EMPTY",
                "DUTY_CHAT_TOO_LONG",
                "WORK_CHAT_TOO_LONG",
                "DUTY_CHAT_RECALL_TOO_LATE",
                "WORK_CHAT_RECALL_TOO_LATE",
                "DUTY_CHAT_RECALL_FORBIDDEN",
                "WORK_CHAT_RECALL_FORBIDDEN",
                "DUTY_CHAT_FORBIDDEN",
                "WORK_CHAT_FORBIDDEN",
                "WORK_DOCUMENT_IMMUTABLE",
                "WORK_UPDATE_FORBIDDEN",
                "WORK_DOCUMENT_NOT_FOUND",
                "FORBIDDEN",
                "UNAUTHENTICATED",
                "CANNOT_REVOKE_CURRENT_SESSION",
                "SESSION_NOT_FOUND",
            )
            return known.firstOrNull { message.contains(it, ignoreCase = true) } ?: message
        }

        fun humanize(message: String): String {
            val code = extractCode(message)
            return when {
                code == "INVALID_PHONE" -> "Số điện thoại không hợp lệ (6–20 ký tự)."
                code == "INVALID_NAME" -> "Họ tên phải có 1–120 ký tự."
                code == "INVALID_TEXT" -> "Ghi chú liên hệ tối đa 300 ký tự."
                code == "INVALID_DISPOSITION_NOTE" -> "Ghi chú phân loại tối đa 500 ký tự."
                code == "CORRECTION_REASON_REQUIRED" -> "Cần lý do hoặc ghi chú."
                code == "GUARDIAN_LIMIT" -> "Tối đa 6 người giám hộ đang hoạt động."
                code == "INVALID_AVATAR_FILE" -> "Ảnh đại diện phải là PNG, JPG hoặc WEBP."
                code == "AVATAR_FILE_TOO_LARGE" -> "Ảnh đại diện không được vượt quá 2MB."
                code == "AVATAR_UPLOAD_NOT_FOUND" -> "Không tìm thấy ảnh vừa tải lên. Vui lòng chọn lại."
                code == "AVATAR_NOT_FOUND" -> "Chưa có ảnh đại diện."
                code == "AVATAR_UPLOAD_FAILED" -> "Không thể cập nhật ảnh đại diện. Vui lòng thử lại."
                code.contains("Invalid", ignoreCase = true) ||
                    code.contains("credentials", ignoreCase = true) ->
                    "Email hoặc mật khẩu không đúng."
                code == "ACCOUNT_LOCKED" ->
                    "Tài khoản đã bị khóa do đăng nhập sai quá số lần. Liên hệ quản trị viên để mở khóa."
                code == "USER_NOT_ACTIVE" -> "Tài khoản chưa được kích hoạt hoặc đã bị khóa."
                code == "PASSWORD_TOO_SHORT" -> "Mật khẩu phải có ít nhất 8 ký tự."
                code == "CANNOT_REVOKE_CURRENT_SESSION" -> "Không thể thu hồi phiên đang dùng."
                code == "SESSION_NOT_FOUND" -> "Phiên đăng nhập không còn tồn tại."
                code == "PASSWORD_CHANGE_FAILED" -> "Không đổi được mật khẩu. Thử lại sau."
                code == "PASSWORD_CHANGED_SYNC_PENDING" ->
                    "Mật khẩu đã đổi nhưng hồ sơ chưa đồng bộ. Đăng nhập lại."
                code == "PASSWORD_CHANGE_REQUIRED" -> "Bạn cần đổi mật khẩu trước khi tiếp tục."
                code == "PASSWORD_RESET_FAILED" -> "Không thể đặt lại mật khẩu. Thử lại sau."
                code == "PASSWORD_RESET_EMAIL_FAILED" ->
                    "Đã tạo mật khẩu tạm nhưng chưa gửi được email. Liên hệ quản trị viên."
                code == "MAIL_NOT_CONFIGURED" || code == "MAIL_AUTH_FAILED" ->
                    "Hệ thống chưa gửi được email. Liên hệ quản trị viên."
                code == "INVALID_EMAIL" -> "Email không hợp lệ."
                code == "ATTENDANCE_OUTSIDE_WINDOW" -> "Chỉ xác nhận trong thời gian công tác đang diễn ra."
                code == "ATTENDANCE_CONFIRMATION_DISABLED" -> "Hệ thống đang tắt xác nhận tham dự."
                code == "NOT_A_PARTICIPANT" -> "Bạn không nằm trong danh sách tham dự."
                code == "QUALITY_PERCENT_REQUIRED" -> "Cần nhập phần trăm chất lượng."
                code == "ASSIGNMENT_CREATE_FORBIDDEN" ->
                    "Bạn không có quyền tạo công tác hoặc công việc."
                code == "INVALID_WORK_TITLE" -> "Vui lòng nhập tên công việc (tối đa 200 ký tự)."
                code == "INVALID_WORK_CONTENT" -> "Nội dung công việc bắt buộc và tối đa 2.000 ký tự."
                code == "INVALID_WORK_DEADLINE" -> "Hạn chót công việc không hợp lệ."
                code == "INVALID_WORK_ASSIGNEE" ->
                    "Người thực hiện phải cùng phòng ban và có cấp sao thấp hơn bạn."
                code == "INVALID_WORK_FILE" -> "Tệp công văn không đúng định dạng được hỗ trợ."
                code == "DOCUMENT_TYPE_REQUIRED" -> "Vui lòng chọn loại văn bản cho file đính kèm."
                code == "INVALID_DOCUMENT_TYPE" -> "Loại văn bản không hợp lệ hoặc đã ngưng sử dụng."
                code == "WORK_ASSIGNMENTS_REQUIRED" -> "Vui lòng thêm ít nhất một phân công."
                code == "WORK_DEPARTMENT_FORBIDDEN" ->
                    "Tổ trưởng/tổ phó chỉ được giao công việc cho cấp dưới, không chọn cả phòng ban."
                code == "WORK_DEPARTMENT_DUPLICATE" ->
                    "Mỗi phòng ban chỉ được nhận một đầu việc trong cùng công văn."
                code == "NOT_A_SUBORDINATE" ->
                    "Chỉ được giao hoặc cập nhật cấp dưới trong cùng phòng ban."
                code == "DUTY_CHAT_EMPTY" || code == "WORK_CHAT_EMPTY" ->
                    "Vui lòng nhập nội dung tin nhắn."
                code == "DUTY_CHAT_TOO_LONG" || code == "WORK_CHAT_TOO_LONG" ->
                    "Tin nhắn quá dài (tối đa 4000 ký tự)."
                code == "DUTY_CHAT_RECALL_TOO_LATE" || code == "WORK_CHAT_RECALL_TOO_LATE" ->
                    "Đã quá 15 phút, không thể thu hồi tin nhắn này."
                code == "DUTY_CHAT_RECALL_FORBIDDEN" || code == "WORK_CHAT_RECALL_FORBIDDEN" ->
                    "Bạn chỉ có thể thu hồi tin nhắn của mình."
                code == "DUTY_CHAT_FORBIDDEN" || code == "WORK_CHAT_FORBIDDEN" ->
                    "Bạn không có quyền trao đổi mục này."
                code == "WORK_DOCUMENT_IMMUTABLE" -> "Đã có người nộp · Không thể sửa hoặc xóa"
                code == "WORK_UPDATE_FORBIDDEN" -> "Bạn không có quyền sửa hoặc xóa công việc này."
                code == "WORK_DOCUMENT_NOT_FOUND" -> "Công việc không còn tồn tại."
                code.contains("FORBIDDEN", ignoreCase = true) -> "Bạn không có quyền thực hiện thao tác này."
                else -> code.take(180)
            }
        }
    }
}
