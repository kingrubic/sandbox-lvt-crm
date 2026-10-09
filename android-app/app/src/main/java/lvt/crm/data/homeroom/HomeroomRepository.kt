package lvt.crm.data.homeroom

import java.time.LocalDate
import java.time.ZoneId
import java.time.Instant
import lvt.crm.data.convex.ConvexHttpClient
import org.json.JSONArray
import org.json.JSONObject

data class SchoolYear(
    val id: String,
    val name: String,
    val startDate: String,
    val endDate: String,
    val active: Boolean,
)

data class AttendanceCounts(
    val present: Int,
    val late: Int,
    val absentExcused: Int,
    val absentUnexcused: Int,
    val absentPending: Int,
    val noData: Int,
    val exempt: Int,
) {
    val absent: Int get() = absentExcused + absentUnexcused + absentPending
}

data class HomeroomClassSummary(
    val id: String,
    val code: String,
    val name: String,
    val gradeLevel: Int?,
    val rosterCount: Int,
    val teacherName: String,
    val published: Boolean,
    val counts: AttendanceCounts,
    val pendingTotal: Int,
    val canCorrect: Boolean,
)

data class SchoolDay(
    val isSchoolDay: Boolean,
    val kind: String,
    val note: String,
    val outsideYear: Boolean,
)

data class MissingUpload(
    val shouldAlert: Boolean,
    val cutoffTime: String,
    val missingClassCodes: List<String>,
)

data class HomeroomOverview(
    val date: String,
    val today: String,
    val mode: String,
    val schoolYear: SchoolYear,
    val schoolDay: SchoolDay,
    val classes: List<HomeroomClassSummary>,
    val studentCount: Int,
    val counts: AttendanceCounts,
    val attendanceRate: Double,
    val ratedRows: Int,
    val totalRows: Int,
    val missingUpload: MissingUpload,
    val pendingTotal: Int,
)

data class PendingAbsence(
    val id: String,
    val attendanceDate: String,
    val classCode: String,
    val studentCode: String,
    val fullName: String,
    val note: String,
    val canCorrect: Boolean,
    val classId: String = "",
    val studentId: String = "",
)

data class PendingAbsences(
    val total: Int,
    val truncated: Boolean,
    val rows: List<PendingAbsence>,
)

data class ImportUpload(
    val id: String,
    val fileName: String,
    val publishedAt: Long,
    val uploadedByName: String,
    val rowCount: Int,
    val matchedCount: Int,
)

data class ImportStatus(val publishedClassCount: Int, val uploads: List<ImportUpload>)

interface HomeroomOperations {
    suspend fun listSchoolYears(): List<SchoolYear>
    suspend fun overview(schoolYearId: String, date: String): HomeroomOverview
    suspend fun pendingAbsences(schoolYearId: String): PendingAbsences
    suspend fun importStatus(schoolYearId: String, date: String): ImportStatus
}

class HomeroomRepository(private val convex: ConvexHttpClient, private val journalDirectory: java.io.File) : HomeroomOperations {
    fun management(year: String, date: String, isCurrent: () -> Boolean) = HomeroomManagementStore.live(convex, year, date, isCurrent, HomeroomPendingJournal(journalDirectory, "management", year, date))
    fun cameraImport(year: String, date: String, isCurrent: () -> Boolean) = CameraImportStore.live(convex, year, date, isCurrent, HomeroomPendingJournal(journalDirectory, "camera", year, date))
    val writeOperations = HomeroomWriteRepository(convex)
    val detailOperations: HomeroomDetailOperations = HomeroomDetailRepository(convex)

    override suspend fun listSchoolYears(): List<SchoolYear> =
        decodeSchoolYears(convex.query("schoolYears:list").optJSONArray("items"))

    override suspend fun overview(schoolYearId: String, date: String): HomeroomOverview =
        decodeOverview(
            convex.query(
                "homeroomReports:overview",
                JSONObject().put("schoolYearId", schoolYearId).put("date", date),
            ),
        )

    override suspend fun pendingAbsences(schoolYearId: String): PendingAbsences =
        decodePending(
            convex.query(
                "homeroomReports:pendingAbsences",
                JSONObject().put("schoolYearId", schoolYearId),
            ),
        )

    override suspend fun importStatus(schoolYearId: String, date: String): ImportStatus =
        decodeImportStatus(
            convex.query(
                "attendanceImport:uploadsForDate",
                JSONObject().put("schoolYearId", schoolYearId).put("attendanceDate", date),
            ),
        )
}

fun vietnamToday(now: Instant = Instant.now()): String = now.atZone(ZoneId.of("Asia/Ho_Chi_Minh")).toLocalDate().toString()

internal fun isVietnamDate(value: String): Boolean =
    value.matches(Regex("\\d{4}-\\d{2}-\\d{2}")) && runCatching { LocalDate.parse(value).toString() == value }.getOrDefault(false)

internal fun decodeSchoolYears(array: JSONArray?): List<SchoolYear> {
    requireNotNull(array) { "Phản hồi năm học không hợp lệ." }
    return array.objects().map { row ->
        val id = row.getString("_id")
        require(id.isNotBlank())
        SchoolYear(
            id = id,
            name = row.optString("name"),
            startDate = row.optString("startDate"),
            endDate = row.optString("endDate"),
            active = row.optBoolean("active", false),
        )
    }
}

internal fun decodeOverview(value: JSONObject): HomeroomOverview {
    require(isVietnamDate(value.getString("date")) && isVietnamDate(value.getString("today")))
    val year = value.getJSONObject("schoolYear")
    require(year.getString("_id").isNotBlank())
    value.getJSONArray("classes")
    value.getJSONObject("schoolDay")
    value.getJSONObject("missingUpload")
    val summary = value.getJSONObject("summary")
    summary.getJSONObject("counts")
    return HomeroomOverview(
        date = value.optString("date"),
        today = value.optString("today"),
        mode = value.optString("mode"),
        schoolYear = SchoolYear(
            id = year.optString("_id"),
            name = year.optString("name"),
            startDate = year.optString("startDate"),
            endDate = year.optString("endDate"),
            active = false,
        ),
        schoolDay = value.optJSONObject("schoolDay").toSchoolDay(),
        classes = value.optJSONArray("classes").objects().map { row ->
            HomeroomClassSummary(
                id = row.optString("_id"),
                code = row.optString("code"),
                name = row.optString("name"),
                gradeLevel = row.optNullableInt("gradeLevel"),
                rosterCount = row.optInt("rosterCount"),
                teacherName = row.optString("teacherName"),
                published = row.optBoolean("published"),
                counts = row.optJSONObject("counts").toCounts(),
                pendingTotal = row.optInt("pendingTotal"),
                canCorrect = row.optBoolean("canCorrect"),
            )
        },
        studentCount = value.optInt("studentCount"),
        counts = summary.optJSONObject("counts").toCounts(),
        attendanceRate = summary.optDouble("attendanceRate", 0.0),
        ratedRows = summary.optInt("ratedRows"),
        totalRows = summary.optInt("totalRows"),
        missingUpload = value.optJSONObject("missingUpload").toMissingUpload(),
        pendingTotal = value.optInt("pendingTotal"),
    )
}

internal fun decodePending(value: JSONObject): PendingAbsences = PendingAbsences(
    total = value.getInt("total"),
    truncated = value.getBoolean("truncated"),
    rows = value.getJSONArray("rows").objects().map { row ->
        PendingAbsence(
            id = row.optString("_id"),
            attendanceDate = row.optString("attendanceDate"),
            classCode = row.optString("classCode"),
            studentCode = row.optString("studentCode"),
            fullName = row.optString("fullName"),
            note = row.optString("note"),
            canCorrect = row.optBoolean("canCorrect"),
            classId = row.optString("classId"),
            studentId = row.optString("studentId"),
        )
    },
)

internal fun decodeImportStatus(value: JSONObject): ImportStatus = ImportStatus(
    publishedClassCount = value.getInt("publishedClassCount"),
    uploads = value.getJSONArray("uploads").objects().map { row ->
        ImportUpload(
            id = row.optString("_id"),
            fileName = row.optString("fileName"),
            publishedAt = row.optLong("publishedAt"),
            uploadedByName = row.optString("uploadedByName"),
            rowCount = row.optInt("rowCount"),
            matchedCount = row.optInt("matchedCount"),
        )
    },
)

private fun JSONObject?.toCounts(): AttendanceCounts {
    val value = requireNotNull(this) { "Thiếu số liệu điểm danh." }
    for (key in listOf("present", "late", "absent_excused", "absent_unexcused", "absent_pending", "no_data", "exempt")) {
        require(value.getInt(key) >= 0) { "Số liệu điểm danh không hợp lệ." }
    }
    return AttendanceCounts(
        present = value.optInt("present"),
        late = value.optInt("late"),
        absentExcused = value.optInt("absent_excused"),
        absentUnexcused = value.optInt("absent_unexcused"),
        absentPending = value.optInt("absent_pending"),
        noData = value.optInt("no_data"),
        exempt = value.optInt("exempt"),
    )
}

private fun JSONObject?.toSchoolDay(): SchoolDay {
    val value = this ?: JSONObject()
    return SchoolDay(
        isSchoolDay = value.optBoolean("isSchoolDay"),
        kind = value.optString("kind"),
        note = value.optString("note"),
        outsideYear = value.optBoolean("outsideYear"),
    )
}

private fun JSONObject?.toMissingUpload(): MissingUpload {
    val value = this ?: JSONObject()
    return MissingUpload(
        shouldAlert = value.optBoolean("shouldAlert"),
        cutoffTime = value.optString("cutoffTime"),
        missingClassCodes = value.optJSONArray("missingClasses").objects().map { it.optString("code") },
    )
}

private fun JSONObject.optNullableInt(name: String): Int? =
    if (!has(name) || isNull(name)) null else optInt(name)

private fun JSONArray?.objects(): List<JSONObject> = buildList {
    val array = this@objects ?: return@buildList
    for (index in 0 until array.length()) add(array.getJSONObject(index))
}
