package lvt.crm.ui.homeroom

import android.app.DatePickerDialog
import android.provider.OpenableColumns
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import lvt.crm.data.homeroom.HomeroomManagementStore
import org.json.JSONObject

private data class ManagementForm(val operation: String, val title: String, val classId: String?, val studentId: String? = null, val fixed: Map<String, String> = emptyMap(), val fields: List<Triple<String, String, String>>)

@Composable
fun HomeroomManagementScreen(store: HomeroomManagementStore, onClose: () -> Unit) {
    val state by store.state.collectAsState()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var form by remember(store) { mutableStateOf<ManagementForm?>(null) }
    var confirmation by remember(store) { mutableStateOf<Pair<String, () -> Unit>?>(null) }
    var reading by remember(store) { mutableStateOf(false) }
    var picking by remember(store) { mutableStateOf(false) }
    var mode by remember(store) { mutableStateOf("create") }
    var pickerError by remember(store) { mutableStateOf<String?>(null) }
    var chosenStudent by remember(store) { mutableStateOf<JSONObject?>(null) }
    var assigning by remember(store) { mutableStateOf<String?>(null) }
    val enabled = !state.busy && !state.locked && !reading && !picking
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        picking = false
        if (uri != null && state.canPick) {
            reading = true
            scope.launch {
                try {
                    val selected = withContext(Dispatchers.IO) {
                        val name = context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { if (it.moveToFirst()) it.getString(0) else null } ?: ""
                        val bytes = context.contentResolver.openInputStream(uri)?.use { stream ->
                            lvt.crm.data.homeroom.RosterImportFile.read(stream)
                        } ?: error("unreadable")
                        name to bytes
                    }
                    store.importFile(selected.first, selected.second, mode)
                } catch (_: Exception) { pickerError = "Không đọc được file; không gửi tải lên. Chọn .xlsx có thể đọc." }
                finally { reading = false }
            }
        }
    }
    fun close() { if (!state.busy && !reading && !picking) confirmation = HomeroomManagementStore.lifecycle to onClose }
    BackHandler { if (form != null && !state.busy) form = null else close() }
    LaunchedEffect(store) { store.refresh(state.classId) }
    LaunchedEffect(state.denied) { if (state.denied) { form = null; chosenStudent = null; assigning = null; confirmation = null; pickerError = null } }
    Column(Modifier.padding(16.dp)) {
        Text("Danh mục / Học sinh · ${store.date} (Việt Nam)")
        Text("Năm học: ${state.yearName}")
        OutlinedButton(enabled = !state.busy && !reading && !picking, onClick = { close() }) { Text("Đóng") }
        OutlinedButton(enabled = !state.busy && !reading, onClick = { scope.launch { store.refresh(state.classId) } }) { Text("Tải lại từ máy chủ (không gửi lại)") }
        Text(state.message)
        if (state.busy || reading || picking) CircularProgressIndicator()
        if (state.denied) return@Column
        val activeForm = form
        if (activeForm != null) {
            ManagementFields(activeForm, enabled, state.message, onBack = { form = null }) { values ->
                confirmation = "Xác nhận ${activeForm.title}? Hiệu lực theo giờ Việt Nam; quá trình cũ kết thúc ngày trước. Không gửi lại nếu kết quả chưa rõ." to {
                    scope.launch {
                        val count = store.state.value.acknowledgmentCount
                        store.mutate(activeForm.operation, activeForm.classId, values, activeForm.studentId)
                        if (store.state.value.acknowledgmentCount > count) form = null
                    }
                }
            }
        } else LazyColumn {
            item {
                if (state.classes.isEmpty() && !state.busy) Text("Chưa có lớp trong danh mục. Tạo lớp hoặc tải lại từ máy chủ.")
                Button(enabled = enabled, onClick = { form = ManagementForm("createClass", "Tạo lớp", null, fields = classFields(null)) }) { Text("Tạo lớp") }
            }
            state.classes.forEach { klass -> item {
                val id = klass.getString("_id"); val active = klass.getString("status") == "active"
                val teacher = klass.optJSONObject("currentHomeroomTeacher")
                val upcoming = klass.optJSONObject("upcomingHomeroomTeacher")
                Text("${klass.getString("code")} · ${klass.getString("name")} · ${klass.getString("status")} · ${klass.getInt("rosterCount")} HS")
                Text(teacher?.let { "${it.getJSONObject("user").getString("name")} từ ${it.getString("effectiveFrom")} đến ${it.optString("effectiveTo", "không thời hạn")}" } ?: "Chưa phân công")
                if (upcoming != null) Text("Sắp tới: ${upcoming.getJSONObject("user").getString("name")} từ ${upcoming.getString("effectiveFrom")}")
                OutlinedButton(enabled = enabled && state.uploadId == null && state.storageId == null, onClick = { scope.launch { store.select(id) } }) { Text("Danh sách ${klass.getString("code")}") }
                if (active) {
                    OutlinedButton(enabled = enabled, onClick = { form = ManagementForm("updateClass", "Sửa lớp", id, fields = classFields(klass)) }) { Text("Sửa lớp") }
                    OutlinedButton(enabled = enabled, onClick = { assigning = id }) { Text("Phân công GVCN") }
                }
                OutlinedButton(enabled = enabled, onClick = { confirmation = "${if (active) "Lưu trữ" else "Khôi phục"} lớp? Lưu trữ đóng phân công hiện tại/sắp tới ngày Việt Nam máy chủ; khôi phục không khôi phục phân công cũ." to { scope.launch { store.mutate(if (active) "archive" else "restore", id, JSONObject()) } } }) { Text(if (active) "Lưu trữ" else "Khôi phục") }
            } }
            if (assigning != null) state.candidates.forEach { candidate -> item {
                OutlinedButton(enabled = enabled, onClick = { form = ManagementForm("assign", "Phân công ${candidate.getString("name")}", assigning, fixed = mapOf("userId" to candidate.getString("_id")), fields = listOf(Triple("effectiveFrom", "Hiệu lực từ", store.date))); assigning = null }) { Text("GVCN: ${candidate.getString("name")}") }
            } }
            val klass = state.classes.firstOrNull { it.getString("_id") == state.classId }
            if (klass != null) {
                item { Text("Danh sách ${klass.getString("code")} ngày ${store.date} · chỉ thao tác quá trình học đang mở") }
                if (klass.getString("status") == "active") item {
                    Button(enabled = enabled, onClick = { form = ManagementForm("createStudent", "Thêm học sinh", state.classId, fields = listOf(Triple("studentCode", "Mã học sinh", ""), Triple("fullName", "Họ tên", ""), Triple("startDate", "Ngày nhập học", store.date), Triple("dateOfBirth", "Ngày sinh YYYY-MM-DD (tùy chọn)", ""), Triple("gender", "Giới tính (tùy chọn)", ""), Triple("studentPhone", "Điện thoại (tùy chọn)", ""), Triple("rosterNumber", "STT (tùy chọn)", ""))) }) { Text("Thêm học sinh") }
                    listOf("create", "merge").forEach { selectedMode ->
                        OutlinedButton(enabled = enabled && state.canPick, onClick = { mode = selectedMode; picking = true; picker.launch(arrayOf("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")) }) { Text(if (selectedMode == "create") "Excel: tạo mới" else "Excel: hợp nhất (cập nhật hồ sơ)") }
                    }
                }
                state.roster.forEach { row -> item {
                    val student = row.getJSONObject("student")
                    Text("${student.getString("studentCode")} · ${student.getString("fullName")} · từ ${row.getJSONObject("enrollment").getString("startDate")}")
                    OutlinedButton(enabled = enabled, onClick = { scope.launch { store.showHistory(student.getString("_id")) } }) { Text("Lịch sử quá trình học") }
                    if (klass.getString("status") == "active") {
                        OutlinedButton(enabled = enabled, onClick = { chosenStudent = row }) { Text("Chuyển lớp") }
                        OutlinedButton(enabled = enabled, onClick = { form = enrollmentForm(store, row, null); chosenStudent = null }) { Text("Nghỉ học") }
                    }
                } }
            }
            val selectedStudent = chosenStudent
            if (selectedStudent != null) state.classes.filter { it.getString("status") == "active" && it.getString("_id") != state.classId }.forEach { target -> item {
                OutlinedButton(enabled = enabled, onClick = { form = enrollmentForm(store, selectedStudent, target.getString("_id")); chosenStudent = null }) { Text("Chuyển sang ${target.getString("code")}") }
            } }
            item { Text(HomeroomManagementStore.lifecycle); Text("Đủ 16 cột: ${HomeroomManagementStore.columns}\nNgày sinh DD/MM/YYYY hoặc YYYY-MM-DD; mã/điện thoại dạng văn bản."); pickerError?.let { Text(it) } }
            state.history.forEach { row -> item { Text("Lịch sử quá trình học (máy chủ): $row") } }
            if (state.uploadId != null) item { Text("ID ${state.uploadId} · ${state.uploadStatus} · hết hạn ${java.time.Instant.ofEpochMilli(state.expiresAt).atZone(java.time.ZoneId.of("Asia/Ho_Chi_Minh"))}") }
            state.validation?.let { preview ->
                item { Text("Hợp lệ: ${preview.getBoolean("ok")} · ${preview.getJSONArray("preview").length()} dòng · ${preview.getJSONArray("blockers").length()} lỗi chặn") }
                HomeroomManagementStore.objects(preview.getJSONArray("issues")).forEach { issue -> item { Text("Dòng ${issue.getInt("rowNumber")} · ${issue.getString("column")} · ${issue.getString("severity")} · ${issue.getString("code")} · ${issue.getString("message")}") } }
                HomeroomManagementStore.objects(preview.getJSONArray("preview")).forEach { row -> item {
                    Text("Dòng ${row.getInt("rowNumber")} · ${row.getString("studentCode")} · ${row.getString("fullName")}")
                    Text(listOf("dateOfBirth", "gender", "rosterNumber", "studentPhone", "priorityCategory", "ethnicity", "hardshipNote", "notes").filter { row.has(it) && !row.isNull(it) }.joinToString(" · ") { "$it: ${row.get(it)}" })
                    row.optJSONArray("guardians")?.let { guardians -> HomeroomManagementStore.objects(guardians).forEach { guardian -> Text("${guardian.getString("relationship")} · ${guardian.getString("fullName")} · ${guardian.optString("phone")} · liên hệ chính: ${guardian.getBoolean("isPrimaryContact")}") } }
                } }
            }
            item {
                if (state.canCommit) Button(onClick = { confirmation = "Cam kết danh sách? Hợp nhất cập nhật hồ sơ/thêm người giám hộ. Không chuyển lớp. Ngày nhập học là ngày cam kết Việt Nam. Không phát lại." to { scope.launch { store.commit(true) } } }) { Text("Xác nhận cam kết") }
                if (state.canDiscard) OutlinedButton(onClick = { confirmation = "Chọn bản mới / bỏ bản đã biết tại máy? Không xóa máy chủ; giữ ID trong phiên." to { store.discardKnown() } }) { Text("Bỏ bản tại máy / chọn bản mới") }
            }
        }
    }
    confirmation?.let { pending -> AlertDialog(onDismissRequest = { confirmation = null }, text = { Text(pending.first) }, confirmButton = { Button(onClick = { confirmation = null; pending.second() }) { Text("Xác nhận") } }, dismissButton = { OutlinedButton(onClick = { confirmation = null }) { Text("Hủy") } }) }
}

private fun classFields(klass: JSONObject?) = listOf(Triple("code", "Mã lớp", klass?.optString("code").orEmpty()), Triple("name", "Tên lớp", klass?.optString("name").orEmpty()), Triple("gradeLevel", "Khối 6–9", klass?.optString("gradeLevel") ?: "6"), Triple("notes", "Ghi chú", klass?.optString("notes").orEmpty()))
private fun enrollmentForm(store: HomeroomManagementStore, row: JSONObject, target: String?): ManagementForm = ManagementForm(if (target == null) "withdraw" else "transfer", if (target == null) "Nghỉ học" else "Chuyển lớp", store.state.value.classId, row.getJSONObject("student").getString("_id"), mapOf("enrollmentId" to row.getJSONObject("enrollment").getString("_id")) + if (target != null) mapOf("toClassId" to target) else emptyMap(), listOf(Triple("date", "Hiệu lực từ (cũ kết thúc ngày trước)", store.date), Triple("reason", "Lý do ≤300 ký tự", "")))

@Composable
private fun ManagementFields(form: ManagementForm, enabled: Boolean, message: String, onBack: () -> Unit, onSubmit: (JSONObject) -> Unit) {
    var values by remember(form) { mutableStateOf(form.fields.associate { it.first to it.third }) }
    var error by remember(form) { mutableStateOf<String?>(null) }
    val context = LocalContext.current
    LazyColumn {
        item { Text(form.title); Text(message) }
        form.fields.forEach { field -> item {
            if (field.first in listOf("date", "startDate", "effectiveFrom")) {
                OutlinedButton(enabled = enabled, onClick = {
                    val current = java.time.LocalDate.parse(values[field.first])
                    DatePickerDialog(context, { _, year, month, day -> values = values + (field.first to java.time.LocalDate.of(year, month + 1, day).toString()) }, current.year, current.monthValue - 1, current.dayOfMonth).show()
                }) { Text("${field.second}: ${values[field.first]}") }
            } else OutlinedTextField(value = values[field.first].orEmpty(), onValueChange = { values = values + (field.first to it) }, enabled = enabled, label = { Text(field.second) }, modifier = Modifier.fillMaxWidth())
        } }
        item {
            error?.let { Text(it) }
            Button(enabled = enabled, onClick = {
                val args = JSONObject(); form.fixed.forEach { args.put(it.key, it.value) }
                for ((key, value) in values) {
                    if (value.isEmpty() && key in listOf("dateOfBirth", "gender", "studentPhone", "rosterNumber")) continue
                    if (key in listOf("gradeLevel", "rosterNumber")) {
                        val number = value.toIntOrNull()
                        if (number == null || key == "rosterNumber" && number < 1) { error = "Khối / STT cần số nguyên hợp lệ."; return@Button }
                        args.put(key, number)
                    } else args.put(key, value)
                }
                error = null; onSubmit(args)
            }) { Text("Kiểm tra và xác nhận") }
            OutlinedButton(enabled = enabled, onClick = onBack) { Text("Quay lại") }
        }
    }
}
