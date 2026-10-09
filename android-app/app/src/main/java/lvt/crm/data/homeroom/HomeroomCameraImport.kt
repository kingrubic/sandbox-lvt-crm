package lvt.crm.data.homeroom

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import lvt.crm.data.auth.decodeUserSession
import lvt.crm.data.convex.ConvexException
import lvt.crm.data.convex.ConvexHttpClient
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import org.json.JSONArray
import java.net.URI
import java.util.concurrent.TimeUnit

private fun JSONArray.objects(): List<JSONObject> = (0 until length()).map { getJSONObject(it) }

object CameraImportFile {
    const val maxBytes = 4 * 1024 * 1024
    fun read(input: java.io.InputStream): ByteArray {
        val output = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        while (output.size() <= maxBytes) {
            val count = input.read(buffer, 0, minOf(buffer.size, maxBytes + 1 - output.size()))
            if (count < 0) break
            require(count > 0) { "Không đọc được file." }
            output.write(buffer, 0, count)
        }
        return output.toByteArray()
    }
    fun validate(name: String, bytes: ByteArray) {
        if (!name.lowercase().endsWith(".xlsx") || bytes.size !in 4..maxBytes || !bytes.take(4).toByteArray().contentEquals(byteArrayOf(80, 75, 3, 4))) throw ConvexException("INVALID_IMPORT_FILE", "Chỉ nhận .xlsx dạng ZIP, không rỗng, tối đa 4 MiB. Máy chủ kiểm tra nội dung Excel.")
    }
}

data class CameraPreview(val value: JSONObject) {
    val id: String get() = value.getString("uploadId")
    val classes: List<JSONObject> get() = value.getJSONArray("classes").objects()
    val conflicts: Boolean get() = classes.any { it.getBoolean("publishable") && it.getBoolean("alreadyPublished") }
    companion object {
        fun decode(value: JSONObject, id: String, date: String): CameraPreview {
            fun text(row: JSONObject, key: String) { require(row.get(key) is String) }
            fun bool(row: JSONObject, key: String) { require(row.get(key) is Boolean) }
            fun count(row: JSONObject, key: String) { require(row.get(key) is Number && row.getDouble(key) >= 0 && row.getDouble(key) == row.getInt(key).toDouble()) }
            require(value.get("uploadId") == id && value.get("attendanceDate") == date)
            listOf("fileName", "sheetName").forEach { text(value, it) }
            listOf("ok", "issuesTruncated").forEach { bool(value, it) }
            listOf("totalRows", "matchedCount", "errorCount", "warningCount").forEach { count(value, it) }
            value.getJSONArray("classes").objects().forEach { row ->
                listOf("classId", "code", "name").forEach { text(row, it) }; require(row.getString("classId").isNotBlank())
                listOf("rowCount", "matchedCount", "present", "late", "absent", "rosterCount", "missingCount", "errorCount", "warningCount").forEach { count(row, it) }
                listOf("publishable", "alreadyPublished").forEach { bool(row, it) }
            }
            value.getJSONArray("issues").objects().forEach { row ->
                count(row, "rowNumber"); listOf("field", "column", "code", "message", "severity").forEach { text(row, it) }
                require(row.getString("severity") in listOf("error", "warning") && row.has("rejectedValue") && (row.isNull("rejectedValue") || row.get("rejectedValue") is String))
            }
            value.getJSONArray("classesWithoutRows").objects().forEach { row -> listOf("classId", "code", "name").forEach { text(row, it) }; bool(row, "alreadyPublished") }
            value.getJSONObject("schoolDay").let { row -> listOf("kind", "note").forEach { text(row, it) }; listOf("isSchoolDay", "outsideYear").forEach { bool(row, it) } }
            return CameraPreview(value)
        }
    }
}

data class CameraImportState(val busy: Boolean = false, val locked: Boolean = false, val preview: CameraPreview? = null, val status: ImportStatus? = null, val message: String = CameraImportStore.lifecycle)

class CameraImportStore(
    val yearId: String,
    val date: String,
    private val query: suspend (String, JSONObject) -> JSONObject,
    private val write: suspend (String, String, JSONObject) -> JSONObject,
    private val binary: suspend (String, ByteArray) -> String,
    private val isCurrent: () -> Boolean = { true },
    private val journal: HomeroomPendingJournal? = null,
) {
    private val mutable = MutableStateFlow(CameraImportState())
    val state = mutable.asStateFlow()
    private suspend fun send(kind: String, path: String, args: JSONObject): JSONObject {
        journal?.before(path, args)
        val value = write(kind, path, args)
        journal?.received(value)
        return value
    }
    private suspend fun upload(url: String, bytes: ByteArray): String {
        journal?.before("storage-upload", JSONObject())
        val storage = binary(url, bytes)
        journal?.received(JSONObject().put("storageId", storage))
        return storage
    }
    private var generation = 0
    private var owner: String? = null
    private var sent = false
    private var acknowledged = false
    private var canAbandonKnown = false
    var previousUploads: List<String> = emptyList(); private set
    var uploadId: String? = null; private set
    var storageId: String? = null; private set
    val canStartNew: Boolean get() = (acknowledged || canAbandonKnown) && !mutable.value.busy
    fun newFile() {
        if (!canStartNew) return
        try { journal?.clear() } catch (_: Exception) { mutable.value = mutable.value.copy(locked = true, message = HomeroomPendingJournal.recovery); return }
        previousUploads = previousUploads + "Storage: ${storageId ?: "không có ID"} · Upload: ${uploadId ?: "không có ID"} · ${if (acknowledged) "Đã xác nhận công bố; không gửi lại." else "Bản nháp đã bỏ ở ứng dụng; chưa xác nhận công bố, ứng dụng không xóa file/bản đăng ký trên máy chủ."}"
        generation++; acknowledged = false; canAbandonKnown = false; sent = false; uploadId = null; storageId = null
        mutable.value = mutable.value.copy(locked = false, preview = null, message = "Chọn file mới là một lần nhập riêng; không xóa file/bản đăng ký/dữ liệu trước. $lifecycle")
    }
    private fun args() = JSONObject().put("schoolYearId", yearId).put("attendanceDate", date)
    private suspend fun check(token: Int) { currentCoroutineContext().ensureActive(); if (token != generation || !isCurrent()) throw ConvexException("IMPORT_CONTEXT_CHANGED") }
    private suspend fun authorize(token: Int) {
        check(token)
        val raw = query("users:sessionContext", JSONObject()); check(token)
        val user = raw.optJSONObject("user")
        val session = decodeUserSession(raw)
        if (user?.opt("status") != "active" || (user.has("mustChangePassword") && user.opt("mustChangePassword") != false) || session == null || session.userId.isBlank() || (!session.isOperationalManager && !session.isHomeroomSupervisor) || (owner != null && owner != session.userId)) throw ConvexException("IMPORT_FORBIDDEN")
        owner = session.userId
        try {
            journal?.restore(session.userId)?.let { record ->
                mutable.value = mutable.value.copy(locked = true, preview = null, status = null, message = HomeroomPendingJournal.recovery)
                canAbandonKnown = false
                if (record.optString("year") == yearId && record.optString("date") == date) {
                    uploadId = record.optString("uploadId").takeIf(String::isNotBlank); storageId = record.optString("storageId").takeIf(String::isNotBlank)
                }
            }
        } catch (error: Exception) { mutable.value = mutable.value.copy(locked = true, preview = null, status = null, message = HomeroomPendingJournal.recovery); throw error }
        val years = decodeSchoolYears(query("schoolYears:list", JSONObject()).getJSONArray("items")); check(token)
        val year = years.firstOrNull { it.id == yearId }
        if (year == null || !isVietnamDate(date) || !isVietnamDate(year.startDate) || !isVietnamDate(year.endDate) || date < year.startDate || date > year.endDate || date > vietnamToday()) throw ConvexException("INVALID_IMPORT_CONTEXT")
    }
    fun invalidate() {
        generation++
        val uncertain = mutable.value.busy && sent && !acknowledged && !mutable.value.locked
        mutable.value = mutable.value.copy(preview = null, status = null, locked = sent || uploadId != null || mutable.value.locked, message = mutable.value.message + if (uncertain) " Ngữ cảnh đã đổi trong khi gửi; kết quả chưa xác nhận, không gửi lại." else " Ngữ cảnh đã đổi; không tiếp tục bản này, chỉ tải lại.")
    }
    private suspend fun perform(operation: suspend (Int) -> Unit) {
        if (mutable.value.busy || mutable.value.locked) return
        mutable.value = mutable.value.copy(busy = true); sent = false; canAbandonKnown = false
        val token = generation
        try { operation(token) } catch (error: Exception) {
            if (acknowledged) { mutable.value = mutable.value.copy(message = mutable.value.message + " Không tải được dữ liệu sau xác nhận; không gửi lại."); return }
            val code = (error as? ConvexException)?.code ?: "IMPORT_UNCERTAIN"
            val denied = code.contains("FORBIDDEN") || code.contains("SUPERVISOR") || code.contains("AUTHENTICATED") || code.contains("HIDDEN") || code == "Unauthenticated" || code in listOf("USER_NOT_ACTIVE", "PASSWORD_CHANGE_REQUIRED", "IMPORT_CONTEXT_CHANGED")
            val explicit = denied || code in listOf("INVALID_IMPORT_FILE", "INVALID_IMPORT_CONTEXT", "IMPORT_UPLOAD_EXPIRED", "IMPORT_UPLOAD_NOT_FOUND", "IMPORT_ROWS_UNRESOLVED", "INVALID_REPLACE_MODE", "ATTENDANCE_REPLACE_MODE_REQUIRED", "ATTENDANCE_DATE_IN_FUTURE", "ATTENDANCE_DATE_OUTSIDE_YEAR", "IMPORT_TOO_MANY_ROWS", "IMPORT_FILE_EMPTY", "IMPORT_FILE_TOO_LARGE", "ATTENDANCE_TEMPLATE_HEADER_NOT_FOUND", "ATTENDANCE_TEMPLATE_COLUMNS_MISSING", "SCHOOL_YEAR_NOT_FOUND", "INVALID_DATE")
            canAbandonKnown = !denied && (explicit || !sent) && (storageId != null || uploadId != null)
            val locked = mutable.value.locked || denied || (!explicit && sent) || code in listOf("IMPORT_UPLOAD_EXPIRED", "IMPORT_UPLOAD_NOT_FOUND")
            mutable.value = mutable.value.copy(locked = locked, preview = if (locked || code in listOf("ATTENDANCE_REPLACE_MODE_REQUIRED", "IMPORT_ROWS_UNRESOLVED")) null else mutable.value.preview, status = if (denied) null else mutable.value.status, message = "$code: ${error.message}. ${if (locked) "Không gửi lại; chỉ kiểm tra danh sách đã công bố." else "Không tự động thử lại; kiểm tra bản xem trước bằng thao tác riêng."} $lifecycle")
        } finally { mutable.value = mutable.value.copy(busy = false) }
    }
    suspend fun select(name: String, bytes: ByteArray) {
        if (uploadId != null || storageId != null) return
        perform { token ->
            CameraImportFile.validate(name, bytes); authorize(token); sent = true
            val generated = send("mutation", "attendanceImport:generateUploadUrl", args()); check(token)
            require(generated.get("value") is String)
            val url = generated.getString("value")
            require(URI(url).scheme == "https" && !URI(url).host.isNullOrBlank())
            authorize(token); storageId = upload(url, bytes); check(token); require(!storageId.isNullOrBlank())
            authorize(token)
            val registered = send("mutation", "attendanceImport:registerUpload", args().put("storageId", storageId).put("fileName", name).put("fileSize", bytes.size))
            require(registered.get("uploadId") is String)
            uploadId = registered.getString("uploadId"); check(token); require(!uploadId.isNullOrBlank())
            validate(token)
        }
    }
    suspend fun picked(name: String?, bytes: ByteArray?) {
        if (name == null || bytes == null) return
        select(name, bytes)
    }
    private suspend fun validate(token: Int) {
        val id = uploadId ?: return
        mutable.value = mutable.value.copy(preview = null)
        authorize(token); sent = true
        val value = send("action", "attendanceImport:validate", JSONObject().put("uploadId", id)); check(token)
        authorize(token)
        mutable.value = mutable.value.copy(preview = CameraPreview.decode(value, id, date), message = "Đã kiểm tra; chưa công bố. $lifecycle")
        canAbandonKnown = true
    }
    suspend fun refreshPreview() = perform { validate(it) }
    suspend fun publish(mode: String?, confirmed: Boolean) {
        val preview = mutable.value.preview ?: return
        if (!confirmed || preview.classes.none { it.getBoolean("publishable") } || (mode != null && mode !in modes) || (preview.conflicts && mode == null)) return
        perform { token ->
            authorize(token)
            val args = JSONObject().put("uploadId", preview.id); if (mode != null) args.put("replaceMode", mode)
            sent = true
            val receipt = receipt(send("mutation", "attendanceImport:publish", args), preview.id)
            journal?.clear(); acknowledged = true; mutable.value = mutable.value.copy(locked = true, preview = null, message = receipt); check(token)
        }
        if (mutable.value.locked) refreshStatus()
    }
    suspend fun refreshStatus() {
        if (mutable.value.busy) return
        mutable.value = mutable.value.copy(busy = true); val token = generation
        try {
            authorize(token)
            val value = query("attendanceImport:uploadsForDate", args()); check(token)
            mutable.value = mutable.value.copy(status = decodeImportStatus(value))
        } catch (error: Exception) {
            val code = (error as? ConvexException)?.code.orEmpty()
            val denied = code.contains("FORBIDDEN") || code.contains("SUPERVISOR") || code.contains("HIDDEN") || code.contains("AUTHENTICATED") || code in listOf("Unauthenticated", "USER_NOT_ACTIVE", "PASSWORD_CHANGE_REQUIRED", "IMPORT_CONTEXT_CHANGED")
            if (denied) canAbandonKnown = false
            mutable.value = mutable.value.copy(status = null, preview = if (denied) null else mutable.value.preview, locked = denied || mutable.value.locked, message = mutable.value.message + " Không tải được danh sách công bố: ${error.message}. Không gửi lại.")
        }
        finally { mutable.value = mutable.value.copy(busy = false) }
    }
    companion object {
        val modes = listOf("supplement", "replace_camera_observations", "cancel")
        const val lifecycle = "Bản đăng ký dùng được 2 giờ. Rời màn hình không xóa file/bản đăng ký; không có API hủy/xóa/xem trạng thái bản nháp. Danh sách chỉ chứa file đã công bố; không suy ra kết quả từ việc vắng mặt. Nhật ký tối thiểu lưu bền vững, không chứa nội dung file; sau khi tắt ứng dụng/đăng xuất, không gửi lại nếu kết quả trước chưa rõ."
        fun receipt(value: JSONObject, id: String): String {
            require(value.get("importId") == id && value.get("published") == true)
            require(!value.has("idempotent") || value.get("idempotent") is Boolean)
            listOf("count", "classCount").forEach { require(value.get(it) is Number && value.getDouble(it) >= 0 && value.getDouble(it) == value.getInt(it).toDouble()) }
            val skipped = if (value.opt("idempotent") == true) { require(value.getInt("count") == 0 && value.getInt("classCount") == 0); emptyList() } else value.getJSONArray("skippedClassCodes").let { array -> (0 until array.length()).map { require(array.get(it) is String); array.getString(it) } }
            return "Đã xác nhận công bố: ${value.getInt("classCount")} lớp, ${value.getInt("count")} thay đổi. Bỏ qua: ${skipped.joinToString()}. Không gửi lại."
        }
        fun live(convex: ConvexHttpClient, year: String, date: String, isCurrent: () -> Boolean, journal: HomeroomPendingJournal? = null): CameraImportStore {
            val http = OkHttpClient.Builder().retryOnConnectionFailure(false).followRedirects(false).followSslRedirects(false).callTimeout(60, TimeUnit.SECONDS).build()
            return CameraImportStore(year, date, { path, args -> convex.query(path, args) }, { kind, path, args -> convex.importCall(kind, path, args) }, { url, bytes ->
                withContext(Dispatchers.IO) {
                    http.newCall(Request.Builder().url(url).post(bytes.toRequestBody("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet".toMediaType())).build()).execute().use { response ->
                        require(response.isSuccessful)
                        val value = JSONObject(response.body?.string().orEmpty())
                        require(value.get("storageId") is String)
                        value.getString("storageId").also { require(it.isNotBlank()) }
                    }
                }
            }, isCurrent, journal)
        }
    }
}
