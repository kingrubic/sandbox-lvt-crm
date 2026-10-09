package lvt.crm.data.homeroom

import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import lvt.crm.data.auth.decodeUserSession
import lvt.crm.data.convex.ConvexException
import lvt.crm.data.convex.ConvexHttpClient
import org.json.JSONArray
import org.json.JSONObject

data class ManagementState(
    val busy: Boolean = false,
    val locked: Boolean = false,
    val denied: Boolean = false,
    val classes: List<JSONObject> = emptyList(),
    val candidates: List<JSONObject> = emptyList(),
    val roster: List<JSONObject> = emptyList(),
    val history: List<String> = emptyList(),
    val classId: String? = null,
    val validation: JSONObject? = null,
    val uploadId: String? = null,
    val storageId: String? = null,
    val uploadStatus: String? = null,
    val expiresAt: Long = 0,
    val committed: Boolean = false,
    val acknowledgmentCount: Int = 0,
    val yearName: String = "",
    val message: String = HomeroomManagementStore.lifecycle,
) {
    val canPick get() = !busy && !locked && uploadId == null && storageId == null
    val canDiscard get() = !busy && !locked && (uploadId != null || storageId != null)
    val canCommit get() = !busy && !locked && !committed && uploadStatus == "validated" && expiresAt > System.currentTimeMillis() && validation?.opt("ok") == true && validation.optJSONArray("blockers")?.length() == 0
}

class HomeroomManagementStore(
    val year: String,
    val date: String,
    private val query: suspend (String, JSONObject) -> JSONObject,
    private val write: suspend (String, String, JSONObject) -> JSONObject,
    private val binary: suspend (String, ByteArray) -> String,
    private val isCurrent: () -> Boolean,
    private val journal: HomeroomPendingJournal? = null,
) {
    private val mutable = MutableStateFlow(ManagementState())
    val state = mutable.asStateFlow()
    private suspend fun send(kind: String, path: String, args: JSONObject): JSONObject {
        journal?.before(path, JSONObject(args.toString()).also { if (!it.has("classId")) state.value.classId?.let { id -> it.put("classId", id) } })
        val value = write(kind, path, args)
        journal?.received(value)
        return value
    }
    private suspend fun upload(url: String, bytes: ByteArray): String {
        journal?.before("storage-upload", JSONObject().put("classId", state.value.classId))
        val storage = binary(url, bytes)
        journal?.received(JSONObject().put("storageId", storage))
        return storage
    }
    private var generation = 0
    private var owner: String? = null
    private var outstanding = false
    private var uncertain = false
    val retiredIds = mutableListOf<String>()
    private fun update(change: (ManagementState) -> ManagementState) { mutable.value = change(mutable.value) }
    private suspend fun check(token: Int) {
        currentCoroutineContext().ensureActive()
        if (token != generation || !isCurrent()) throw ConvexException("L5_CONTEXT_CHANGED")
    }
    private suspend fun authorize(token: Int, classId: String? = null, active: Boolean = true) {
        check(token)
        val raw = query("users:sessionContext", JSONObject()); check(token)
        val user = raw.optJSONObject("user")
        val session = decodeUserSession(raw)
        if (user?.opt("status") != "active" || user.has("mustChangePassword") && user.opt("mustChangePassword") != false || session == null || !session.isOperationalManager || session.userId.isBlank() || owner != null && owner != session.userId) throw ConvexException("L5_FORBIDDEN")
        owner = session.userId
        try {
            journal?.restore(session.userId)?.let { marker ->
                uncertain = true
                val matching = marker.optString("year") == year && marker.optString("date") == date
                update { it.copy(locked = true, validation = null, classId = if (matching) marker.optString("classId").takeIf(String::isNotBlank) else null, uploadId = if (matching) marker.optString("uploadId").takeIf(String::isNotBlank) else null, storageId = if (matching) marker.optString("storageId").takeIf(String::isNotBlank) else null, message = HomeroomPendingJournal.recovery) }
            }
        } catch (error: Exception) { uncertain = true; update { it.copy(locked = true, validation = null, message = HomeroomPendingJournal.recovery) }; throw error }
        if (outstanding && uncertain) throw ConvexException("PENDING_RECOVERY_REQUIRED")
        val years = decodeSchoolYears(query("schoolYears:list", JSONObject()).optJSONArray("items")); check(token)
        if (years.none { it.id == year } || !validDate(date)) throw ConvexException("INVALID_CONTEXT")
        update { it.copy(yearName = years.first { row -> row.id == year }.name) }
        val fresh = objects(query("homeroomClasses:listCatalog", JSONObject().put("schoolYearId", year).put("date", date).put("includeArchived", true)).getJSONArray("items")); check(token)
        if (fresh.any { it.opt("schoolYearId") != year || it.opt("_id") !is String || it.getString("_id").isBlank() || it.opt("code") !is String || it.opt("name") !is String || it.opt("status") !in listOf("active", "archived") || it.opt("gradeLevel") !is Int || it.opt("rosterCount") !is Int || !validTeacher(it.opt("currentHomeroomTeacher")) || !validTeacher(it.opt("upcomingHomeroomTeacher")) }) throw ConvexException("INVALID_RESPONSE")
        update { it.copy(classes = fresh, denied = false, locked = uncertain) }
        if (classId != null && fresh.none { it.getString("_id") == classId && (!active || it.getString("status") == "active") }) throw ConvexException("CLASS_ARCHIVED")
    }
    private suspend fun run(writing: Boolean = false, body: suspend (Int) -> Unit) {
        if (state.value.busy || writing && state.value.locked) return
        update { it.copy(busy = true) }; val token = generation; val priorAcknowledgments = state.value.acknowledgmentCount
        try { body(token) }
        catch (error: Exception) {
            val code = (error as? ConvexException)?.code ?: "L5_UNCERTAIN"
            val denied = code.contains("FORBIDDEN") || code.contains("AUTHENTICATED") || code in listOf("USER_NOT_ACTIVE", "PASSWORD_CHANGE_REQUIRED", "Unauthenticated", "L5_CONTEXT_CHANGED")
            val definite = denied || code.startsWith("INVALID_") && code != "INVALID_RESPONSE" || code in listOf("CLASS_ARCHIVED", "CLASS_CODE_TAKEN", "STUDENT_CODE_EXISTS", "DUPLICATE_ACTIVE_ENROLLMENT", "ENROLLMENT_YEAR_MISMATCH", "ENROLLMENT_NOT_ACTIVE", "TRANSFER_BEFORE_START", "WITHDRAW_BEFORE_START", "HOMEROOM_TEACHER_OVERLAP", "HOMEROOM_TEACHER_ALREADY_ASSIGNED", "IMPORT_VALIDATION_FAILED", "IMPORT_UPLOAD_EXPIRED", "IMPORT_UPLOAD_ALREADY_COMMITTED", "SCHOOL_YEAR_LOCKED")
            uncertain = uncertain || outstanding && (!definite || code == "L5_CONTEXT_CHANGED")
            val safeCode = if (code.length <= 80 && code.matches(Regex("[A-Z0-9_]+"))) code else if (denied) "L5_FORBIDDEN" else "L5_READ_FAILED"
            update { it.copy(locked = uncertain || denied, denied = denied || it.denied, classes = if (denied) emptyList() else it.classes, candidates = if (denied) emptyList() else it.candidates, roster = if (denied) emptyList() else it.roster, validation = if (denied) null else it.validation, message = if (uncertain) "Kết quả chưa rõ. KHÔNG gửi lại, kể cả mở lại ứng dụng. Chỉ tải trạng thái. $lifecycle" else "Không hoàn tất (${if (definite) safeCode else "L5_READ_FAILED"}); không tự gửi lại.") }
            if (denied) update { it.copy(history = emptyList()) }
            if (state.value.uploadId != null && (outstanding || code == "INVALID_RESPONSE")) update { it.copy(validation = null, uploadStatus = null) }
            outstanding = false
            if (state.value.acknowledgmentCount > priorAcknowledgments) update { it.copy(message = "Máy chủ đã xác nhận; tải lại thất bại. Không gửi lại. Chỉ tải dữ liệu.") }
        } finally { update { it.copy(busy = false) } }
    }
    suspend fun refresh(classId: String? = null) = run {
        authorize(it)
        val candidates = objects(query("homeroomClasses:listAssignmentCandidates", JSONObject()).getJSONArray("items")); check(it)
        if (candidates.any { row -> row.getString("_id").isBlank() || row.get("name") !is String || row.get("role") !is String }) throw ConvexException("INVALID_RESPONSE")
        update { current -> current.copy(candidates = candidates) }
        if (classId != null) loadRoster(classId, it)
        if (state.value.uploadId != null) result(it)
    }
    private suspend fun loadRoster(classId: String, token: Int) {
        if (state.value.classes.none { it.getString("_id") == classId }) throw ConvexException("CLASS_NOT_FOUND")
        val raw = query("students:listByClass", JSONObject().put("classId", classId).put("date", date).put("includeSensitiveContacts", false)); check(token)
        val rows = objects(raw.getJSONArray("rows")).map {
            val enrollment = it.getJSONObject("enrollment")
            val student = it.getJSONObject("student")
            JSONObject().put("enrollment", JSONObject().put("_id", enrollment.getString("_id")).put("startDate", enrollment.getString("startDate")))
                .put("student", JSONObject().put("_id", student.getString("_id")).put("studentCode", student.getString("studentCode")).put("fullName", student.getString("fullName")))
        }
        update { it.copy(roster = rows, classId = classId) }
    }
    suspend fun select(classId: String) { if (state.value.uploadId == null && state.value.storageId == null) refresh(classId) }
    suspend fun showHistory(studentId: String) = run { authorize(it); loadHistory(studentId, it) }
    private suspend fun loadHistory(studentId: String, token: Int) {
        val raw = query("students:getScoped", JSONObject().put("studentId", studentId).put("includeSensitiveContacts", false)); check(token)
        if (raw.getJSONObject("student").getString("_id") != studentId) throw ConvexException("INVALID_RESPONSE")
        val history = objects(raw.getJSONArray("enrollments")).map { "${it.optString("classCode")} · ${it.getString("startDate")} → ${if (it.isNull("endDate")) "đang mở" else it.getString("endDate")} · ${it.getString("status")} · ${it.optString("transferReason")}" }
        update { it.copy(history = history) }
    }
    fun invalidate() { generation++; uncertain = uncertain || outstanding; update { it.copy(locked = true, denied = true, classes = emptyList(), candidates = emptyList(), roster = emptyList(), validation = null, history = emptyList()) } }
    fun discardKnown() {
        if (!state.value.canDiscard) return
        try { journal?.clear() } catch (_: Exception) { uncertain = true; update { it.copy(locked = true, message = HomeroomPendingJournal.recovery) }; return }
        listOfNotNull(state.value.uploadId, state.value.storageId).forEach { retiredIds.add(it) }
        update { it.copy(uploadId = null, storageId = null, validation = null, uploadStatus = null, expiresAt = 0, committed = false, message = lifecycle) }
    }
    suspend fun mutate(operation: String, classId: String?, values: JSONObject, studentId: String? = null) = run(true) { token ->
        val paths = mapOf("createClass" to "homeroomClasses:create", "updateClass" to "homeroomClasses:update", "archive" to "homeroomClasses:archive", "restore" to "homeroomClasses:restore", "assign" to "homeroomClasses:assignUser", "createStudent" to "students:create", "transfer" to "homeroomClasses:transferStudent", "withdraw" to "homeroomClasses:withdrawStudent")
        val path = paths[operation] ?: throw ConvexException("INVALID_OPERATION")
        authorize(token, classId, operation != "restore")
        val args = JSONObject(values.toString())
        when (operation) {
            "createClass", "updateClass" -> {
                val code = values.optString("code").trim().uppercase()
                if (code.length !in 1..20 || !code.matches(Regex("[A-Z0-9_-]+")) || values.optString("name").trim().length !in 1..120 || values.optInt("gradeLevel") !in 6..9) throw ConvexException("INVALID_CLASS_INPUT")
                args.put("code", code).put(if (operation == "createClass") "schoolYearId" else "id", if (operation == "createClass") year else classId)
            }
            "archive", "restore" -> args.put("id", classId)
            "assign" -> {
                val candidates = objects(query("homeroomClasses:listAssignmentCandidates", JSONObject()).getJSONArray("items")); check(token)
                if (candidates.none { it.getString("_id") == values.optString("userId") } || !validDate(values.optString("effectiveFrom"))) throw ConvexException("INVALID_ASSIGNMENT")
                args.put("classId", classId).put("assignmentType", "homeroom_teacher").put("scopeKind", "class")
            }
            "createStudent" -> {
                if (values.optString("studentCode").trim().length !in 1..30 || values.optString("fullName").trim().length !in 1..120 || !validDate(values.optString("startDate")) || values.has("dateOfBirth") && !validDate(values.optString("dateOfBirth"))) throw ConvexException("INVALID_STUDENT_INPUT")
                args.put("classId", classId)
                if (values.has("rosterNumber") && (values.opt("rosterNumber") !is Int || values.getInt("rosterNumber") < 1)) throw ConvexException("INVALID_ROSTER_NUMBER")
            }
            "transfer", "withdraw" -> {
                loadRoster(classId.orEmpty(), token)
                if (state.value.roster.none { it.getJSONObject("enrollment").getString("_id") == values.optString("enrollmentId") && it.getJSONObject("student").getString("_id") == studentId }) throw ConvexException("INVALID_ENROLLMENT")
                val raw = query("students:getScoped", JSONObject().put("studentId", studentId)); check(token)
                if (raw.getJSONObject("student").getString("_id") != studentId) throw ConvexException("INVALID_ENROLLMENT")
                val enrollment = objects(raw.getJSONArray("enrollments")).firstOrNull { it.getString("_id") == values.optString("enrollmentId") } ?: throw ConvexException("INVALID_ENROLLMENT")
                val effective = values.optString("date")
                if (enrollment.getString("classId") != classId || enrollment.getString("status") != "active" || !enrollment.isNull("endDate") || !validDate(effective) || effective < enrollment.getString("startDate") || operation == "withdraw" && effective == enrollment.getString("startDate") || values.optString("reason").length > 300) throw ConvexException("INVALID_ENROLLMENT")
                if (operation == "transfer" && state.value.classes.none { it.getString("_id") == values.optString("toClassId") && it.getString("status") == "active" && it.getString("_id") != classId }) throw ConvexException("INVALID_TRANSFER")
            }
        }
        authorize(token, classId, operation != "restore"); outstanding = true
        val ack = send("mutation", path, args); check(token)
        if (operation in listOf("createClass", "assign", "createStudent", "transfer")) { if (ack.opt("value") !is String || ack.getString("value").isBlank()) throw ConvexException("IMPORT_UNCERTAIN") }
        else if (ack.length() != 0) throw ConvexException("IMPORT_UNCERTAIN")
        journal?.clear(); outstanding = false; update { it.copy(acknowledgmentCount = it.acknowledgmentCount + 1, message = "Máy chủ đã xác nhận; không gửi lại. Đang tải lại.") }
        authorize(token)
        if (classId != null) loadRoster(classId, token)
        if (studentId != null) loadHistory(studentId, token)
        update { it.copy(message = "Đã xác nhận và tải lại danh mục / danh sách / lịch sử từ máy chủ.") }
    }
    suspend fun importFile(name: String, bytes: ByteArray, mode: String) {
        if (!state.value.canPick) return
        val classId = state.value.classId ?: return
        run(true) { token ->
            if (mode !in listOf("create", "merge") || !name.lowercase().endsWith(".xlsx") || bytes.isEmpty() || bytes.size > 2 * 1024 * 1024 || bytes.size < 4 || !bytes.take(4).toByteArray().contentEquals(byteArrayOf(80,75,3,4))) throw ConvexException("INVALID_IMPORT_FILE")
            authorize(token, classId); outstanding = true
            val raw = send("mutation", "studentRosterImport:generateUploadUrl", JSONObject().put("classId", classId)); check(token)
            val url = raw.getString("value")
            val target = java.net.URI(url)
            if (target.scheme != "https" || target.host.isNullOrBlank()) throw ConvexException("IMPORT_UNCERTAIN")
            outstanding = false; authorize(token, classId); outstanding = true
            val storage = upload(url, bytes); check(token)
            if (storage.isBlank()) throw ConvexException("IMPORT_UNCERTAIN")
            update { it.copy(storageId = storage) }; outstanding = false
            authorize(token, classId); outstanding = true
            val registered = send("mutation", "studentRosterImport:registerUpload", JSONObject().put("storageId", storage).put("fileName", name).put("fileSize", bytes.size).put("schoolYearId", year).put("classId", classId).put("mode", mode)); check(token)
            if (registered.opt("uploadId") !is String || registered.getString("uploadId").isBlank() || registered.opt("expiresAt") !is Number) throw ConvexException("IMPORT_UNCERTAIN")
            val id = registered.getString("uploadId")
            update { it.copy(uploadId = id, expiresAt = registered.getLong("expiresAt")) }; outstanding = false
            authorize(token, classId); outstanding = true
            val preview = send("action", "studentRosterImport:validateUpload", JSONObject().put("uploadId", id)); check(token)
            validatePreview(preview, mode)
            outstanding = false
            authorize(token, classId)
            result(token)
            if (state.value.uploadStatus != if (preview.getBoolean("ok")) "validated" else "rejected") throw ConvexException("INVALID_RESPONSE")
            update { it.copy(validation = preview) }
            update { it.copy(message = if (preview.getBoolean("ok")) "Đã kiểm tra. Xem toàn bộ lỗi/cảnh báo rồi xác nhận cam kết." else "File bị từ chối; sửa Excel rồi chọn bản mới.") }
        }
    }
    private suspend fun result(token: Int) {
        val id = state.value.uploadId ?: return
        update { it.copy(uploadStatus = null) }
        val raw = query("studentRosterImport:getResult", JSONObject().put("uploadId", id)); check(token)
        val upload = raw.getJSONObject("upload")
        if (upload.getString("_id") != id || upload.getString("uploadedBy") != owner || upload.getString("classId") != state.value.classId || upload.getString("schoolYearId") != year || upload.getString("status") !in listOf("uploaded", "validated", "rejected", "committing", "committed") || raw.opt("rows") !is JSONArray) throw ConvexException("INVALID_RESPONSE")
        val rows = objects(raw.getJSONArray("rows"))
        if (upload.opt("expiresAt") !is Number || rows.size > 200 || rows.any { it.opt("rowNumber") !is Number || it.opt("payload") !is JSONObject || it.opt("issues") !is JSONArray }) throw ConvexException("INVALID_RESPONSE")
        update { it.copy(expiresAt = upload.getLong("expiresAt"), uploadStatus = upload.getString("status"), committed = it.committed || upload.getString("status") == "committed", validation = if (upload.getString("status") == "committed") null else it.validation) }
    }
    suspend fun commit(confirmed: Boolean) {
        if (!confirmed || !state.value.canCommit) return
        val id = state.value.uploadId ?: return
        val classId = state.value.classId ?: return
        run(true) { token ->
            authorize(token, classId); result(token)
            if (state.value.uploadStatus != "validated" || state.value.committed || state.value.expiresAt <= System.currentTimeMillis()) throw ConvexException("IMPORT_UPLOAD_EXPIRED")
            authorize(token, classId); outstanding = true
            val ack = send("action", "studentRosterImport:commit", JSONObject().put("uploadId", id)); check(token)
            if (ack.opt("uploadId") != id || ack.opt("committed") != true || ack.opt("count") !is Number || ack.getInt("count") !in 0..200) throw ConvexException("IMPORT_UNCERTAIN")
            journal?.clear()
            outstanding = false; update { it.copy(acknowledgmentCount = it.acknowledgmentCount + 1, committed = true, validation = null, message = "Máy chủ đã xác nhận cam kết ${ack.getInt("count")} dòng. Không cam kết lại.") }
            result(token); authorize(token); loadRoster(classId, token)
        }
    }
    companion object {
        const val lifecycle = "Nhập .xlsx tối đa 2 MiB / 200 dòng; đăng ký 1 giờ. Nhập học từ ngày cam kết (Việt Nam). Tạo mới không ghi đè; hợp nhất cập nhật hồ sơ/thêm người giám hộ, không chuyển lớp. Rời màn hình không xóa file. Nhật ký tối thiểu lưu bền vững, không chứa nội dung file; sau tắt ứng dụng/đăng xuất khi kết quả chưa rõ KHÔNG gửi lại. Cam kết công khai không bảo đảm phát lại idempotent."
        const val columns = "ma_hoc_sinh, ho_ten, ngay_sinh, gioi_tinh, so_thu_tu, dien_thoai_hoc_sinh, ho_ten_cha, dien_thoai_cha, ho_ten_me, dien_thoai_me, ho_ten_nguoi_giam_ho, dien_thoai_nguoi_giam_ho, dien_uu_tien, dan_toc, hoan_canh_kho_khan, ghi_chu"
        fun objects(array: JSONArray): List<JSONObject> = (0 until array.length()).map { array.getJSONObject(it) }
        fun validDate(value: String): Boolean = value.matches(Regex("\\d{4}-\\d{2}-\\d{2}")) && runCatching { java.time.LocalDate.parse(value).toString() == value }.getOrDefault(false)
        private fun validTeacher(value: Any?): Boolean {
            if (value == null || value === JSONObject.NULL) return true
            if (value !is JSONObject || value.opt("effectiveFrom") !is String || !validDate(value.getString("effectiveFrom"))) return false
            if (!value.isNull("effectiveTo") && (value.opt("effectiveTo") !is String || !validDate(value.getString("effectiveTo")))) return false
            val user = value.optJSONObject("user") ?: return false
            return listOf("_id", "name", "role").all { user.opt(it) is String }
        }
        fun validatePreview(raw: JSONObject, mode: String) {
            val issues = objects(raw.getJSONArray("issues")); val blockers = objects(raw.getJSONArray("blockers")); val preview = objects(raw.getJSONArray("preview"))
            val expected = columns.split(',').map { it.trim() }
            val mapping = raw.optJSONArray("columns")
            val mappingValid = raw.opt("mode") == mode && mapping != null && (0 until mapping.length()).map { mapping.getString(it) } == expected || raw.opt("ok") == false && !raw.has("mode") && !raw.has("columns")
            if (preview.any { row -> listOf("dateOfBirth", "gender", "studentPhone", "priorityCategory", "ethnicity", "hardshipNote", "notes").any { !row.isNull(it) && row.opt(it) !is String } || !row.isNull("rosterNumber") && row.opt("rosterNumber") !is Int || !row.isNull("guardians") && (row.opt("guardians") !is JSONArray || objects(row.getJSONArray("guardians")).any { guardian -> listOf("relationship", "fullName").any { guardian.opt(it) !is String } || !guardian.isNull("phone") && guardian.opt("phone") !is String || guardian.opt("isPrimaryContact") !is Boolean }) }) throw ConvexException("IMPORT_UNCERTAIN")
            if (raw.opt("ok") !is Boolean || !mappingValid || preview.size > 200 || raw.getBoolean("ok") != blockers.isEmpty() || !raw.getBoolean("ok") && preview.isNotEmpty() || issues.count { it.getString("severity") == "error" } != blockers.size || blockers.any { it.getString("severity") != "error" } || issues.any { it.getString("severity") !in listOf("error", "warning") || it.getInt("rowNumber") < 0 || it.get("code") !is String || it.get("message") !is String } || preview.any { it.get("studentCode") !is String || it.get("fullName") !is String || it.getInt("rowNumber") < 1 }) throw ConvexException("IMPORT_UNCERTAIN")
        }
        fun live(convex: ConvexHttpClient, year: String, date: String, isCurrent: () -> Boolean, journal: HomeroomPendingJournal? = null): HomeroomManagementStore {
            return HomeroomManagementStore(year, date, { path, args -> convex.query(path, args) }, { kind, path, args -> convex.importCall(kind, path, args) }, { url, bytes -> uploadRosterWorkbook(url, bytes) }, isCurrent, journal)
        }
    }
}

object RosterImportFile {
    fun read(stream: java.io.InputStream): ByteArray {
        val output = java.io.ByteArrayOutputStream(); val buffer = ByteArray(8192)
        while (output.size() <= 2 * 1024 * 1024) {
            val count = stream.read(buffer, 0, minOf(buffer.size, 2 * 1024 * 1024 + 1 - output.size()))
            if (count < 0) break
            if (count == 0) throw ConvexException("IMPORT_READ_FAILED")
            output.write(buffer, 0, count)
        }
        return output.toByteArray()
    }
}

private suspend fun uploadRosterWorkbook(url: String, bytes: ByteArray): String = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
    val http = okhttp3.OkHttpClient.Builder().retryOnConnectionFailure(false).followRedirects(false).followSslRedirects(false).callTimeout(60, java.util.concurrent.TimeUnit.SECONDS).build()
    try {
        val body = with(okhttp3.RequestBody.Companion) { bytes.toRequestBody(with(okhttp3.MediaType.Companion) { "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet".toMediaType() }) }
        http.newCall(okhttp3.Request.Builder().url(url).post(body).build()).execute().use {
            if (!it.isSuccessful) throw ConvexException("IMPORT_UNCERTAIN")
            val raw = JSONObject(it.body?.string().orEmpty())
            if (raw.opt("storageId") !is String || raw.getString("storageId").isBlank()) throw ConvexException("IMPORT_UNCERTAIN")
            raw.getString("storageId")
        }
    } finally { http.dispatcher.executorService.shutdown(); http.connectionPool.evictAll() }
}
