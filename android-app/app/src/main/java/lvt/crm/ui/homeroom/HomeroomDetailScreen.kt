package lvt.crm.ui.homeroom

import android.app.DatePickerDialog
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import lvt.crm.data.homeroom.*
import lvt.crm.ui.components.LvtScreen

@Composable
fun HomeroomDetailScreen(viewModel: HomeroomDetailViewModel, onClose: () -> Unit) {
    val state by viewModel.uiState.collectAsState()
    var daily by remember { mutableStateOf(false) }
    var search by remember { mutableStateOf("") }
    val context = LocalContext.current
    var contactForm by remember(state.context, state.studentId) { mutableStateOf<HomeroomForm?>(null) }
    contactForm?.let { draft -> viewModel.writeOperations?.let { writes -> HomeroomWriteForm(draft, writes, { viewModel.uiState.value.context == draft.context && viewModel.uiState.value.studentId == draft.studentId && viewModel.uiState.value.error == null }, viewModel::clearWriteData, viewModel::refresh) { contactForm = null } } }
    val back = { if (state.studentId != null) viewModel.backToClass() else onClose() }
    BackHandler(onBack = back)
    LvtScreen(title = if (state.studentId != null) "Học sinh" else "Lớp", refreshing = state.loading, onRefresh = viewModel::refresh, showAccountHeader = true) {
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            item {
                OutlinedButton(onClick = back, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text(if (state.studentId != null) "Trở lại lớp" else "Trở lại tổng quan") }
                Text("Ngày Việt Nam ${formatDate(state.context.date)}", style = MaterialTheme.typography.bodyMedium)
            }
            item(key = "absence-actions") {
                val data = state.classData
                val targets = if (daily && data?.daily?.canCorrect == true && !data.daily.archived) data.daily.rows.mapNotNull { row -> row.day?.takeIf { it.rawObservation == "absent" }?.let { AbsenceTarget(it.id, row.student.id, state.context, row.student.fullName) } } else emptyList()
                val requestContext = state.context
                AbsenceActions(targets, viewModel.writeOperations, { viewModel.uiState.value.context == requestContext && viewModel.uiState.value.studentId == null && viewModel.uiState.value.error == null }, viewModel::clearWriteData, viewModel::refresh)
            }
            if (state.studentId == null) {
                item {
                    OutlinedButton(onClick = {
                        val selected = LocalDate.parse(state.context.date)
                        DatePickerDialog(context, { _, year, month, day -> viewModel.selectDate(LocalDate.of(year, month + 1, day).toString()) }, selected.year, selected.monthValue - 1, selected.dayOfMonth).show()
                    }, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text("Chọn ngày điểm danh: ${formatDate(state.context.date)}") }
                    OutlinedButton(onClick = { daily = !daily }, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text(if (daily) "Xem danh sách lớp" else "Xem điểm danh ngày") }
                    OutlinedTextField(value = search, onValueChange = { search = it }, label = { Text("Tìm tên hoặc mã học sinh") }, modifier = Modifier.fillMaxWidth(), singleLine = false)
                }
            } else {
                item {
                    HistoryDateButton("Lịch sử từ", state.context.from) { viewModel.selectHistoryRange(it, state.context.to) }
                    HistoryDateButton("Lịch sử đến", state.context.to) { viewModel.selectHistoryRange(state.context.from, it) }
                    Text("Chọn khoảng có ngày bắt đầu không sau ngày kết thúc. Phạm vi xem do máy chủ quyết định.")
                }
            }
            when {
                state.loading -> item { CircularProgressIndicator(); Text("Đang tải…") }
                state.error != null -> item {
                    DetailCard("Chưa tải được dữ liệu", "${state.error}\nDữ liệu cũ đã được xóa; không suy diễn thành danh sách rỗng.")
                    Button(onClick = viewModel::refresh, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text("Thử lại") }
                }
                state.classData != null -> {
                    val data = state.classData!!
                    item { DetailCard("${data.scoped.code} · ${data.scoped.name}", "Sĩ số ${data.scoped.rosterCount} · GVCN ${data.scoped.teacherName}\n${if (data.scoped.status == "archived") "Lớp đã lưu trữ" else "Lớp đang hoạt động"}\nTheo ghi danh tại ngày đã chọn; chỉ trong phạm vi máy chủ cho phép.") }
                    if (daily) {
                        val rows = data.daily.rows.filter { matchesStudent(it.student, search) }
                        item {
                            DetailCard("Điểm danh ${formatDate(data.daily.date)} · ${rows.size}/${data.daily.rows.size} học sinh", "${if (data.daily.published) "Đã có dữ liệu công bố" else "Chưa có dữ liệu công bố"}\nQuyền phân loại từ máy chủ: ${if (data.daily.canCorrect) "Có" else "Không"}")
                            if (data.daily.schoolDay.outsideYear) Text("Ngoài năm học · Không suy diễn thành vắng.")
                            else if (!data.daily.schoolDay.isSchoolDay) Text("Không phải ngày học · ${data.daily.schoolDay.note}")
                            if (rows.isEmpty()) Text("Không có học sinh trong danh sách. Thử ngày khác hoặc thay đổi tìm kiếm.")
                        }
                        items(rows) { row ->
                            DetailCard(row.student.fullName, "${row.student.studentCode} · ${attendanceStatusText(row.day?.effectiveStatus ?: "no_data")}\n${row.day?.rawObservedAt?.let(::attendanceTimestamp) ?: ""}\n${row.day?.note ?: ""}")
                            StudentButton(row.student, viewModel::openStudent)
                        }
                    } else {
                        val rows = data.roster.rows.filter { matchesStudent(it.student, search) }
                        item {
                            Text("Danh sách lớp · ${rows.size}/${data.roster.rows.size}")
                            Text("Liên hệ chỉ hiển thị trong hồ sơ khi máy chủ cho phép.")
                            if (rows.isEmpty()) Text(if (data.roster.rows.isEmpty()) "Chưa có học sinh" else "Không có kết quả tìm kiếm")
                        }
                        items(rows) { row ->
                            DetailCard("${row.enrollment.rosterNumber ?: "—"}. ${row.student.fullName}", "${row.student.studentCode} · Ghi danh từ ${formatDate(row.enrollment.startDate)}")
                            StudentButton(row.student, viewModel::openStudent)
                        }
                    }
                }
                state.studentData != null -> {
                    val data = state.studentData!!
                    val student = data.profile.student
                    item { DetailCard(student.fullName, "${student.studentCode} · ${data.profile.status}\nNgày sinh: ${student.dateOfBirth?.let(::formatDate) ?: "—"} · Giới tính: ${student.gender ?: "—"}") }
                    item {
                        if (data.profile.showContacts) {
                            Text("Điện thoại học sinh: ${student.studentPhone ?: "—"}")
                            data.profile.guardians.forEach { guardian ->
                                Text("${guardian.fullName} · ${relationshipText(guardian.relationship)} · ${guardian.phone ?: "—"}${if (guardian.isPrimaryContact) " · Liên hệ chính" else ""}\n${guardian.notes ?: ""}")
                                if (data.profile.canEditContacts) OutlinedButton(onClick = { contactForm = HomeroomForm(state.context, student.id, guardian = guardian, contactMode = "guardian") }, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text("Sửa hoặc xóa · ${guardian.fullName}") }
                            }
                            if (data.profile.canEditContacts) {
                                OutlinedButton(onClick = { contactForm = HomeroomForm(state.context, student.id, initialPhone = student.studentPhone ?: "") }, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text("Sửa điện thoại học sinh") }
                                OutlinedButton(enabled = data.profile.guardians.size < 6, onClick = { contactForm = HomeroomForm(state.context, student.id, contactMode = "guardian") }, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text("Thêm người giám hộ · ${data.profile.guardians.size}/6") }
                            }
                        } else Text("Liên hệ được máy chủ ẩn; không có quyền sửa.")
                    }
                    item { Text("Ghi danh được phép xem · ${data.profile.enrollments.size}", fontWeight = FontWeight.SemiBold) }
                    items(data.profile.enrollments) { row -> DetailCard("${row.classCode} · ${row.className}", "${formatDate(row.startDate)} → ${row.endDate?.let(::formatDate) ?: "Đang tiếp tục"}\n${if (row.current) "Hiện tại" else "Lịch sử"} · ${row.status}\n${row.transferReason ?: ""}") }
                    item {
                        DetailCard("Lịch sử · ${data.history.days.size} buổi · ${data.history.corrections.size} điều chỉnh", "${formatDate(state.context.from)} → ${formatDate(state.context.to)}\nHiển thị toàn bộ các buổi được máy chủ trả về trong khoảng và phạm vi được phép.")
                        if (data.history.days.isEmpty()) Text("Chưa có lịch sử trong khoảng này; không suy diễn thành có mặt hoặc vắng.")
                    }
                    items(data.history.days.asReversed()) { row -> DetailCard("${formatDate(row.date)} · ${attendanceStatusText(row.record.effectiveStatus)}", "Lớp ID ${row.classId}\n${row.record.rawObservedAt?.let(::attendanceTimestamp) ?: ""}\n${row.record.reasonCode ?: ""} ${row.record.note ?: ""}") }
                    items(data.history.corrections.sortedByDescending { it.at }) { row -> DetailCard("Điều chỉnh ${formatDate(row.date)}", "${attendanceStatusText(row.previousStatus)} → ${attendanceStatusText(row.nextStatus)}\n${attendanceTimestamp(row.at)} · Người sửa ID ${row.actorUserId}\n${row.reasonCode ?: ""} ${row.note ?: ""}") }
                }
            }
        }
    }
}

@Composable private fun DetailCard(title: String, text: String) {
    Card(Modifier.fillMaxWidth().heightIn(min = 48.dp)) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(title, fontWeight = FontWeight.SemiBold)
            Text(text)
        }
    }
}

@Composable private fun StudentButton(student: StudentIdentity, open: (String) -> Unit) {
    OutlinedButton(onClick = { open(student.id) }, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text("Xem hồ sơ và lịch sử · ${student.fullName}") }
}

@Composable private fun HistoryDateButton(label: String, date: String, onDate: (String) -> Unit) {
    val context = LocalContext.current
    OutlinedButton(onClick = {
        val selected = LocalDate.parse(date)
        DatePickerDialog(context, { _, year, month, day -> onDate(LocalDate.of(year, month + 1, day).toString()) }, selected.year, selected.monthValue - 1, selected.dayOfMonth).show()
    }, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text("$label: ${formatDate(date)}") }
}

internal fun matchesStudent(student: StudentIdentity, search: String): Boolean {
    fun normalized(value: String): String = java.text.Normalizer.normalize(value.lowercase(Locale.ROOT).replace('đ', 'd'), java.text.Normalizer.Form.NFD).replace(Regex("\\p{M}+"), "")
    val term = normalized(search.trim())
    return normalized(student.fullName).contains(term) || normalized(student.studentCode).contains(term)
}

private fun attendanceTimestamp(milliseconds: Double): String = DateTimeFormatter.ofPattern("dd/MM/yyyy HH:mm", Locale.forLanguageTag("vi-VN")).withZone(ZoneId.of("Asia/Ho_Chi_Minh")).format(Instant.ofEpochMilli(milliseconds.toLong()))
