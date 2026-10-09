package lvt.crm.data.homeroom

import lvt.crm.data.convex.ConvexHttpClient
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import org.json.JSONObject

data class DetailContext(val yearId: String, val classId: String, val date: String, val from: String, val to: String) {
    fun validate() {
        require(yearId.isNotBlank() && classId.isNotBlank() && isVietnamDate(date) && isVietnamDate(from) && isVietnamDate(to) && from <= to) { "INVALID_CONTEXT" }
    }
}

data class StudentIdentity(val id: String, val studentCode: String, val fullName: String, val dateOfBirth: String?, val gender: String?, val studentPhone: String?)
data class RosterEnrollment(val id: String, val rosterNumber: Int?, val startDate: String)
data class RosterRow(val enrollment: RosterEnrollment, val student: StudentIdentity)
data class ClassRoster(val rows: List<RosterRow>, val showContacts: Boolean)
data class ScopedClass(val id: String, val yearId: String, val code: String, val name: String, val status: String, val teacherName: String, val rosterCount: Int, val canCorrect: Boolean)
data class AttendanceRecord(val id: String, val rawObservation: String, val rawObservedAt: Double?, val disposition: String, val effectiveStatus: String, val reasonCode: String?, val note: String?)
data class DailyRow(val enrollmentId: String, val rosterNumber: Int?, val student: StudentIdentity, val day: AttendanceRecord?)
data class ClassDaily(val date: String, val rows: List<DailyRow>, val published: Boolean, val archived: Boolean, val canCorrect: Boolean, val schoolDay: SchoolDay)
data class StudentEnrollment(val id: String, val classId: String, val classCode: String, val className: String, val startDate: String, val endDate: String?, val status: String, val rosterNumber: Int?, val transferReason: String?, val current: Boolean)
data class Guardian(val id: String, val relationship: String, val fullName: String, val phone: String?, val isPrimaryContact: Boolean, val notes: String?)
data class StudentProfile(val student: StudentIdentity, val status: String, val enrollments: List<StudentEnrollment>, val guardians: List<Guardian>, val showContacts: Boolean, val canManage: Boolean, val canEditContacts: Boolean)
data class HistoryDay(val id: String, val studentId: String, val classId: String, val date: String, val record: AttendanceRecord)
data class HistoryCorrection(val id: String, val attendanceDayId: String, val studentId: String, val date: String, val previousDisposition: String, val nextDisposition: String, val previousStatus: String, val nextStatus: String, val reasonCode: String?, val note: String?, val actorUserId: String, val at: Double)
data class StudentHistory(val days: List<HistoryDay>, val corrections: List<HistoryCorrection>)
data class ClassDetail(val scoped: ScopedClass, val roster: ClassRoster, val daily: ClassDaily)
data class StudentDetail(val profile: StudentProfile, val history: StudentHistory)

interface HomeroomDetailOperations {
    suspend fun loadClass(context: DetailContext): ClassDetail
    suspend fun loadStudent(context: DetailContext, studentId: String): StudentDetail
}

class HomeroomDetailRepository(private val query: suspend (String, JSONObject) -> JSONObject) : HomeroomDetailOperations {
    constructor(convex: ConvexHttpClient) : this({ path, args -> convex.query(path, args) })

    override suspend fun loadClass(context: DetailContext): ClassDetail {
        context.validate()
        val scoped = decodeScopedClass(query("homeroomClasses:getScoped", JSONObject().put("classId", context.classId).put("date", context.date)))
        require(scoped.id == context.classId && scoped.yearId == context.yearId) { "INVALID_RESPONSE_CONTEXT" }
        currentCoroutineContext().ensureActive()
        val roster = decodeClassRoster(query("students:listByClass", JSONObject().put("classId", context.classId).put("date", context.date).put("includeSensitiveContacts", false)))
        currentCoroutineContext().ensureActive()
        val daily = decodeClassDaily(query("studentAttendance:listDailyClass", JSONObject().put("classId", context.classId).put("attendanceDate", context.date)))
        require(daily.date == context.date) { "INVALID_RESPONSE_CONTEXT" }
        return ClassDetail(scoped, roster, daily)
    }

    override suspend fun loadStudent(context: DetailContext, studentId: String): StudentDetail {
        context.validate()
        require(studentId.isNotBlank())
        val profile = decodeStudentProfile(query("students:getScoped", JSONObject().put("studentId", studentId).put("includeSensitiveContacts", false)))
        require(profile.student.id == studentId) { "INVALID_RESPONSE_CONTEXT" }
        currentCoroutineContext().ensureActive()
        val history = decodeStudentHistory(query("studentAttendance:getStudentHistory", JSONObject().put("studentId", studentId).put("from", context.from).put("to", context.to)))
        require(profile.student.id == studentId && history.days.all { it.studentId == studentId && it.date >= context.from && it.date <= context.to } && history.corrections.all { it.studentId == studentId && it.date >= context.from && it.date <= context.to }) { "INVALID_RESPONSE_CONTEXT" }
        return StudentDetail(profile, history)
    }
}

internal val attendanceStatuses = setOf("present", "late", "absent_pending", "absent_excused", "absent_unexcused", "no_data", "exempt")
private val dispositions = setOf("none", "pending", "excused", "unexcused", "exempt")
fun attendanceStatusText(status: String): String = when (status) {
    "present" -> "Có mặt"
    "late" -> "Trễ"
    "absent_pending" -> "Vắng chờ xử lý"
    "absent_excused" -> "Vắng có phép"
    "absent_unexcused" -> "Vắng không phép"
    "no_data" -> "Chưa có dữ liệu"
    "exempt" -> "Miễn"
    else -> "Trạng thái không hợp lệ"
}

private fun JSONObject.text(key: String, nonempty: Boolean = false): String {
    val value = get(key)
    require(value is String && (!nonempty || value.isNotBlank())) { "INVALID_RESPONSE: $key" }
    return value
}
private fun JSONObject.flag(key: String): Boolean {
    val value = get(key)
    require(value is Boolean) { "INVALID_RESPONSE: $key" }
    return value
}
private fun JSONObject.optionalText(key: String): String? = if (!has(key) || isNull(key)) null else text(key)
private fun JSONObject.number(key: String): Double {
    val value = get(key)
    require(value is Number && value.toDouble().isFinite() && value.toDouble() >= 0) { "INVALID_RESPONSE: $key" }
    return value.toDouble()
}
private fun JSONObject.integer(key: String): Int {
    val value = number(key)
    require(value <= Int.MAX_VALUE && value % 1.0 == 0.0)
    return value.toInt()
}
private fun JSONObject.optionalInteger(key: String): Int? = if (!has(key) || isNull(key)) null else integer(key)
private fun JSONObject.date(key: String): String = text(key).also { require(isVietnamDate(it)) { "INVALID_RESPONSE: $key" } }
private fun JSONObject.optionalDate(key: String): String? = optionalText(key)?.also { require(isVietnamDate(it)) }
private fun JSONObject.objects(key: String): List<JSONObject> = getJSONArray(key).let { array -> List(array.length()) { array.getJSONObject(it) } }
private fun JSONObject.identity(): StudentIdentity = StudentIdentity(text("_id", true), text("studentCode", true), text("fullName", true), optionalDate("dateOfBirth"), optionalText("gender"), null)
private fun JSONObject.record(): AttendanceRecord {
    val raw = text("rawObservation")
    val disposition = text("disposition")
    val status = text("effectiveStatus")
    require(raw in setOf("present", "late", "absent", "unknown") && disposition in dispositions && status in attendanceStatuses)
    return AttendanceRecord(text("_id", true), raw, if (!has("rawObservedAt") || isNull("rawObservedAt")) null else number("rawObservedAt"), disposition, status, optionalText("reasonCode"), optionalText("note"))
}

internal fun decodeScopedClass(value: JSONObject): ScopedClass {
    val klass = value.getJSONObject("class")
    val permissions = value.getJSONObject("permissions")
    for (key in listOf("canManage", "canImportAttendance", "canCorrect", "canEditContacts")) permissions.flag(key)
    value.objects("assignments")
    if (!value.isNull("schoolYear")) {
        val year = value.getJSONObject("schoolYear")
        year.text("_id", true)
        year.text("name")
    }
    val status = klass.text("status")
    require(status in setOf("active", "archived"))
    return ScopedClass(klass.text("_id", true), klass.text("schoolYearId", true), klass.text("code", true), klass.text("name", true), status, value.text("currentTeacherName"), value.integer("rosterCount"), permissions.flag("canCorrect"))
}

internal fun decodeClassRoster(value: JSONObject): ClassRoster = ClassRoster(value.objects("rows").map { row ->
    val enrollment = row.getJSONObject("enrollment")
    row.objects("guardians")
    RosterRow(RosterEnrollment(enrollment.text("_id", true), enrollment.optionalInteger("rosterNumber"), enrollment.date("startDate")), row.getJSONObject("student").identity())
}, value.flag("showContacts"))

internal fun decodeClassDaily(value: JSONObject): ClassDaily {
    val schoolDay = value.getJSONObject("schoolDay")
    return ClassDaily(value.date("date"), value.objects("rows").map { row ->
        val enrollment = row.getJSONObject("enrollment")
        require(row.has("day"))
        DailyRow(enrollment.text("_id", true), enrollment.optionalInteger("rosterNumber"), row.getJSONObject("student").identity(), if (row.isNull("day")) null else row.getJSONObject("day").record())
    }, value.flag("published"), value.flag("archived"), value.flag("canCorrect"), SchoolDay(schoolDay.flag("isSchoolDay"), schoolDay.text("kind"), schoolDay.optionalText("note") ?: "", schoolDay.flag("outsideYear")))
}

internal fun decodeStudentProfile(value: JSONObject): StudentProfile {
    val student = value.getJSONObject("student")
    val permissions = value.getJSONObject("permissions")
    val show = value.flag("showContacts")
    val guardians = value.objects("guardians")
    val contacts = if (show) guardians.map { row -> Guardian(row.text("_id", true), row.text("relationship", true).also { require(it in contactRelationships) }, row.text("fullName", true), row.optionalText("phone"), row.flag("isPrimaryContact"), row.optionalText("notes")) } else emptyList()
    require(contacts.size <= 6 && contacts.map { it.id }.distinct().size == contacts.size)
    contacts.forEach { guardian ->
        require(guardian.fullName.trim().length in 1..120 && (guardian.notes?.length ?: 0) <= 300)
        HomeroomWritePayload.phone(guardian.phone ?: "")
    }
    if (show) HomeroomWritePayload.phone(student.optionalText("studentPhone") ?: "")
    return StudentProfile(student.identity().copy(studentPhone = if (show) student.optionalText("studentPhone") else null), student.text("status", true), value.objects("enrollments").map { enrollment ->
        val start = enrollment.date("startDate")
        val end = enrollment.optionalDate("endDate")
        require(end == null || end >= start)
        StudentEnrollment(enrollment.text("_id", true), enrollment.text("classId", true), enrollment.text("classCode"), enrollment.text("className"), start, end, enrollment.text("status", true), enrollment.optionalInteger("rosterNumber"), enrollment.optionalText("transferReason"), enrollment.flag("current"))
    }, contacts, show, permissions.flag("canManage"), permissions.flag("canEditContacts"))
}

internal fun decodeStudentHistory(value: JSONObject): StudentHistory = StudentHistory(value.objects("days").map { day ->
    HistoryDay(day.text("_id", true), day.text("studentId", true), day.text("classId", true), day.date("attendanceDate"), day.record())
}, value.objects("corrections").map { row ->
    val previous = row.text("previousEffectiveStatus")
    val next = row.text("nextEffectiveStatus")
    val previousDisposition = row.text("previousDisposition")
    val nextDisposition = row.text("nextDisposition")
    require(previous in attendanceStatuses && next in attendanceStatuses && previousDisposition in dispositions && nextDisposition in dispositions)
    HistoryCorrection(row.text("_id", true), row.text("attendanceDayId", true), row.text("studentId", true), row.date("attendanceDate"), previousDisposition, nextDisposition, previous, next, row.optionalText("reasonCode"), row.optionalText("note"), row.text("actorUserId", true), row.number("at"))
})
