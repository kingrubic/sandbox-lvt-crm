package lvt.crm.data.homeroom

import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import lvt.crm.data.convex.ConvexHttpClient
import lvt.crm.data.convex.ConvexException
import org.json.JSONObject

val contactRelationships = listOf("father", "mother", "guardian", "grandparent", "sibling", "other")
data class AbsenceTarget(val id: String, val studentId: String, val context: DetailContext, val label: String = "")
data class HomeroomWrite(val path: String, val args: JSONObject, val context: DetailContext, val studentId: String? = null, val targets: List<AbsenceTarget> = emptyList())
class WriteDenied : IllegalStateException("Quyền hoặc dữ liệu đã thay đổi. Đã xóa nội dung gửi; tải lại trước khi sửa.")
class WriteUncertain(cause: Throwable) : IllegalStateException("Chưa xác nhận được kết quả ghi. Không gửi lại; tải lại để kiểm tra.", cause)
fun isHomeroomWriteDenied(error: Throwable): Boolean = error is WriteDenied || (error as? ConvexException)?.code?.let { it.contains("FORBIDDEN") || it.contains("HIDDEN") || it in setOf("USER_NOT_ACTIVE", "PASSWORD_CHANGE_REQUIRED", "Unauthenticated", "UNAUTHENTICATED", "ATTENDANCE_DAY_NOT_FOUND", "CLASS_NOT_FOUND", "STUDENT_NOT_FOUND", "GUARDIAN_NOT_FOUND", "CLASS_ARCHIVED", "DISPOSITION_NOT_ABSENT") } == true
data class WriteReceipt(val status: String, val refreshFailed: Boolean)

object HomeroomWritePayload {
    private const val whitespace = "\\u0009-\\u000D\\u0020\\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF"
    private fun trimmed(value: String) = value.replace(Regex("^[$whitespace]+|[$whitespace]+$"), "")
    fun validate(write: HomeroomWrite) {
        val args = write.args
        fun string(key: String, optional: Boolean = false): String {
            if (optional && !args.has(key)) return ""
            require(args.get(key) is String) { "INVALID_WRITE" }
            return args.getString(key)
        }
        val expected = when (write.path) {
            "studentAttendance:setDisposition", "studentAttendance:setDispositionMany" -> {
                require(write.targets.all { it.context.yearId == write.context.yearId }) { "INVALID_CONTEXT" }
                disposition(write.targets, string("nextDisposition"), string("reasonCode", true), string("note", true), write.path.endsWith("Many"))
            }
            "students:updateContacts" -> studentPhone(write.context, write.studentId ?: error("INVALID_WRITE"), string("studentPhone"))
            "students:upsertGuardian" -> {
                require(args.get("isPrimaryContact") is Boolean) { "INVALID_WRITE" }
                guardian(write.context, write.studentId ?: error("INVALID_WRITE"), if (args.has("guardianId")) string("guardianId") else null, string("relationship"), string("fullName"), string("phone"), args.getBoolean("isPrimaryContact"), string("notes"))
            }
            "students:removeGuardian" -> remove(write.context, write.studentId ?: error("INVALID_WRITE"), string("guardianId"))
            else -> error("INVALID_WRITE")
        }
        require(args.keys().asSequence().toSet() == expected.args.keys().asSequence().toSet() && expected.args.keys().asSequence().all { key -> args.get(key).toString() == expected.args.get(key).toString() }) { "INVALID_WRITE_CONTEXT" }
    }
    fun phone(value: String): String = trimmed(value).also { require(it.isEmpty() || Regex("[0-9+().\\-$whitespace]{6,20}").matches(it)) { "Số điện thoại: 6–20 ký tự số, + ( ) . - hoặc khoảng trắng." } }
    fun disposition(targets: List<AbsenceTarget>, next: String, reason: String, note: String, batch: Boolean): HomeroomWrite {
        val unique = targets.distinctBy { it.id }
        require(unique.isNotEmpty() && unique.size <= 100 && (batch || unique.size == 1)) { "Chọn từ 1 đến 100 buổi duy nhất." }
        require(targets.groupBy { it.id }.all { (_, rows) -> rows.distinct().size == 1 }) { "INVALID_CONTEXT" }
        unique.forEach { it.context.validate(); require(it.id.isNotBlank() && it.studentId.isNotBlank()) }
        require(next in listOf("pending", "excused", "unexcused"))
        require(trimmed(note).length <= 500) { "Ghi chú tối đa 500 ký tự." }
        require(next == "pending" || trimmed(reason).isNotEmpty() || trimmed(note).isNotEmpty()) { "Cần lý do hoặc ghi chú." }
        val args = JSONObject().put("nextDisposition", next)
        if (batch) args.put("attendanceDayIds", org.json.JSONArray(unique.map { it.id })) else args.put("attendanceDayId", unique.single().id)
        if (trimmed(reason).isNotEmpty()) args.put("reasonCode", trimmed(reason))
        if (trimmed(note).isNotEmpty()) args.put("note", trimmed(note))
        return HomeroomWrite(if (batch) "studentAttendance:setDispositionMany" else "studentAttendance:setDisposition", args, unique.first().context, targets = unique)
    }
    fun studentPhone(context: DetailContext, studentId: String, phone: String) = HomeroomWrite("students:updateContacts", JSONObject().put("studentId", studentId).put("studentPhone", phone(phone)), context, studentId)
    fun guardian(context: DetailContext, studentId: String, id: String?, relationship: String, name: String, phone: String, primary: Boolean, notes: String): HomeroomWrite {
        val normalized = name.replace(Regex("[$whitespace]+"), " ").trim()
        require(normalized.length in 1..120 && trimmed(notes).length <= 300 && relationship in contactRelationships) { "Tên 1–120 ký tự; ghi chú tối đa 300; chọn quan hệ hợp lệ." }
        val args = JSONObject().put("studentId", studentId).put("relationship", relationship).put("fullName", normalized).put("phone", phone(phone)).put("isPrimaryContact", primary).put("notes", trimmed(notes))
        if (id != null) args.put("guardianId", id)
        return HomeroomWrite("students:upsertGuardian", args, context, studentId)
    }
    fun remove(context: DetailContext, studentId: String, id: String) = HomeroomWrite("students:removeGuardian", JSONObject().put("studentId", studentId).put("guardianId", id), context, studentId)
}

class HomeroomWriteRepository(private val query: suspend (String, JSONObject) -> JSONObject, private val mutation: suspend (String, JSONObject) -> JSONObject) {
    constructor(client: ConvexHttpClient) : this({ path, args -> client.query(path, args) }, { path, args -> client.mutation(path, args) })
    private var submitting = false
    suspend fun submit(request: HomeroomWrite, isCurrent: () -> Boolean, onAcknowledged: () -> Unit = {}): WriteReceipt {
        check(!submitting) { "Đang gửi; không gửi trùng." }
        submitting = true
        try {
            val write = request.copy(args = JSONObject(request.args.toString()), targets = request.targets.toList())
            write.context.validate()
            HomeroomWritePayload.validate(write)
            if (!isCurrent()) throw WriteDenied()
            if (write.targets.isNotEmpty()) {
                require(write.path in listOf("studentAttendance:setDisposition", "studentAttendance:setDispositionMany") && write.targets.size in 1..100)
                for ((context, targets) in write.targets.groupBy { it.context }) {
                    val scoped = decodeScopedClass(query("homeroomClasses:getScoped", JSONObject().put("classId", context.classId).put("date", context.date)))
                    if (scoped.id != context.classId || scoped.yearId != context.yearId || scoped.status != "active") throw WriteDenied()
                    currentCoroutineContext().ensureActive()
                    val daily = decodeClassDaily(query("studentAttendance:listDailyClass", JSONObject().put("classId", context.classId).put("attendanceDate", context.date)))
                    if (daily.date != context.date || daily.archived || !daily.canCorrect || targets.any { target -> daily.rows.none { it.student.id == target.studentId && it.day?.id == target.id && it.day.rawObservation == "absent" } }) throw WriteDenied()
                }
            } else {
                require(write.path in listOf("students:updateContacts", "students:upsertGuardian", "students:removeGuardian") && !write.studentId.isNullOrBlank())
                val profile = decodeStudentProfile(query("students:getScoped", JSONObject().put("studentId", write.studentId).put("includeSensitiveContacts", false)))
                if (profile.student.id != write.studentId || !profile.showContacts || !profile.canEditContacts || profile.enrollments.none { it.classId == write.context.classId }) throw WriteDenied()
                val guardianId = write.args.optString("guardianId")
                if (guardianId.isNotEmpty() && profile.guardians.none { it.id == guardianId }) throw WriteDenied()
                if (write.path == "students:upsertGuardian" && guardianId.isEmpty()) require(profile.guardians.size < 6) { "Tối đa 6 người giám hộ." }
                val scoped = decodeScopedClass(query("homeroomClasses:getScoped", JSONObject().put("classId", write.context.classId).put("date", write.context.date)))
                if (scoped.id != write.context.classId || scoped.yearId != write.context.yearId || scoped.status != "active") throw WriteDenied()
            }
            currentCoroutineContext().ensureActive()
            if (!isCurrent()) throw WriteDenied()
            val ack = try { mutation(write.path, write.args).also { validateAck(write, it) } } catch (error: kotlinx.coroutines.CancellationException) { throw error } catch (error: Exception) {
                if (isHomeroomWriteDenied(error)) throw WriteDenied()
                if ((error as? ConvexException)?.code in setOf("INVALID_PHONE", "INVALID_NAME", "INVALID_TEXT", "INVALID_DISPOSITION", "INVALID_DISPOSITION_NOTE", "CORRECTION_REASON_REQUIRED", "GUARDIAN_LIMIT")) throw error
                throw WriteUncertain(error)
            }
            currentCoroutineContext().ensureActive()
            if (!isCurrent()) return WriteReceipt("Ghi đã được xác nhận; ngữ cảnh đã đổi. Tải lại dữ liệu.", true)
            onAcknowledged()
            val count = if (write.path.endsWith("Many")) ack.getInt("updated") else null
            val message = if (count != null) "Máy chủ xác nhận $count/${write.targets.size} buổi thay đổi (các buổi còn lại không đổi)." else if (ack.opt("unchanged") == true) "Máy chủ xác nhận buổi này không thay đổi." else "Máy chủ đã xác nhận ghi."
            return try {
                val details = HomeroomDetailRepository(query)
                for (context in (write.targets.map { it.context } + write.context).distinct()) {
                    currentCoroutineContext().ensureActive()
                    if (!isCurrent()) throw WriteDenied()
                    details.loadClass(context)
                    val ids = write.targets.filter { it.context == context }.map { it.studentId } + listOfNotNull(write.studentId)
                    for (id in ids.distinct()) details.loadStudent(context, id)
                }
                val overview = decodeOverview(query("homeroomReports:overview", JSONObject().put("schoolYearId", write.context.yearId).put("date", write.context.date)))
                require(overview.schoolYear.id == write.context.yearId && overview.date == write.context.date)
                decodePending(query("homeroomReports:pendingAbsences", JSONObject().put("schoolYearId", write.context.yearId)))
                WriteReceipt(message, false)
            } catch (error: kotlinx.coroutines.CancellationException) { throw error } catch (error: Exception) { WriteReceipt("$message Không tải được dữ liệu sau ghi; không gửi lại. Chỉ tải lại.", true) }
        } finally { submitting = false }
    }
    internal fun validateAck(write: HomeroomWrite, value: JSONObject) {
        when (write.path) {
            "students:updateContacts", "students:removeGuardian" -> require(value.length() == 0)
            "students:upsertGuardian" -> require(value.length() == 1 && value.get("value") is String && value.getString("value").isNotBlank() && (!write.args.has("guardianId") || value.getString("value") == write.args.getString("guardianId")))
            "studentAttendance:setDispositionMany" -> require(value.length() == 1 && value.get("updated") is Number && value.getDouble("updated") == value.getInt("updated").toDouble() && value.getInt("updated") in 0..write.targets.size)
            "studentAttendance:setDisposition" -> require(value.get("attendanceDayId") == write.targets.single().id && value.get("unchanged") is Boolean && value.get("effectiveStatus") == mapOf("pending" to "absent_pending", "excused" to "absent_excused", "unexcused" to "absent_unexcused")[write.args.getString("nextDisposition")])
            else -> error("INVALID_MUTATION_ACK")
        }
    }
}
