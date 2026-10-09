package lvt.crm.ui.homeroom

import android.app.DatePickerDialog
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CalendarMonth
import androidx.compose.material.icons.outlined.Groups
import androidx.compose.material.icons.outlined.WarningAmber
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import java.time.LocalDate
import lvt.crm.data.homeroom.HomeroomClassSummary
import lvt.crm.data.homeroom.HomeroomOverview
import lvt.crm.data.homeroom.ImportStatus
import lvt.crm.data.homeroom.PendingAbsence
import lvt.crm.ui.components.LvtScreen
import lvt.crm.ui.components.StatePanel

@Composable
fun HomeroomScreen(viewModel: HomeroomViewModel, canImport: Boolean = false, canManage: Boolean = false) {
    val state by viewModel.uiState.collectAsState()
    var camera by remember(viewModel) { mutableStateOf<lvt.crm.data.homeroom.CameraImportStore?>(null) }
    var management by remember(viewModel) { mutableStateOf<lvt.crm.data.homeroom.HomeroomManagementStore?>(null) }
    if (management != null) {
        HomeroomManagementScreen(management!!) { management = null; viewModel.refresh() }
        return
    }
    if (camera != null) {
        HomeroomCameraImportScreen(camera!!) { camera = null; viewModel.refresh() }
        return
    }
    val currentDetail by viewModel.detailState.collectAsState()
    if (currentDetail != null) {
        val selectedDetail = currentDetail!!
        androidx.compose.runtime.DisposableEffect(selectedDetail) {
            if (!selectedDetail.uiState.value.loading) selectedDetail.refresh()
            onDispose { selectedDetail.close() }
        }
        HomeroomDetailScreen(selectedDetail, viewModel::closeDetail)
        return
    }
    LvtScreen(
        title = "Lớp chủ nhiệm",
        refreshing = state.refreshing,
        onRefresh = viewModel::refresh,
        showAccountHeader = true,
    ) {
        Column(Modifier.fillMaxSize()) {
            if (state.years.isNotEmpty()) {
                Column(Modifier.padding(16.dp)) {
                    ContextControls(
                        years = state.years.map { it.id to it.name },
                        selectedYearId = state.selectedYearId,
                        date = state.date,
                        onYear = viewModel::selectYear,
                        onDate = viewModel::selectDate,
                    )
                    Text("Ngày tổng quan · Múi giờ Việt Nam", style = MaterialTheme.typography.bodySmall)
                    if (canImport) OutlinedButton(enabled = !state.loading && !state.refreshing && state.selectedYearId != null, onClick = { camera = viewModel.cameraImport() }) { Text("Nhập camera toàn trường") }
                    if (canManage) OutlinedButton(enabled = !state.loading && !state.refreshing && state.selectedYearId != null, onClick = { management = viewModel.management() }) { Text("Danh mục / Học sinh / Nhập danh sách") }
                }
            }
            val year = state.years.firstOrNull { it.id == state.selectedYearId }
            val targets = if (!state.supervisor && state.pane == HomeroomPane.Pending && year != null) state.pending?.rows.orEmpty().filter { it.canCorrect && it.classId.isNotBlank() && it.studentId.isNotBlank() }.map { row -> lvt.crm.data.homeroom.AbsenceTarget(row.id, row.studentId, lvt.crm.data.homeroom.DetailContext(year.id, row.classId, row.attendanceDate, year.startDate, year.endDate), "${row.fullName} · ${row.classCode}") } else emptyList()
            val requestYear = state.selectedYearId
            val requestDate = state.date
            Box(Modifier.heightIn(max = 240.dp)) {
                androidx.compose.foundation.lazy.LazyColumn {
                    item { AbsenceActions(targets, viewModel.writeOperations, { viewModel.uiState.value.selectedYearId == requestYear && viewModel.uiState.value.date == requestDate && viewModel.uiState.value.pane == HomeroomPane.Pending && viewModel.uiState.value.error == null }, viewModel::clearWriteData, viewModel::refresh) }
                }
            }
            Box(Modifier.weight(1f)) {
                when {
                    state.loading -> CenteredLoading()
                    state.error != null -> StatePanel(
                        icon = Icons.Outlined.WarningAmber,
                        title = "Chưa tải được dữ liệu",
                        message = "${state.error.orEmpty()}\nNgày Việt Nam: ${formatDate(state.date)}",
                        action = { Button(onClick = viewModel::refresh) { Text("Thử lại") } },
                    )
                    state.years.isEmpty() -> StatePanel(
                        icon = Icons.Outlined.CalendarMonth,
                        title = "Chưa có năm học",
                        message = "Quản trị viên cần tạo năm học trước khi xem điểm danh.",
                    )
                    else -> LazyColumn(
                        modifier = Modifier.fillMaxSize(),
                        contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
                        verticalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        if (state.supervisor) {
                            item { SupervisorNotice() }
                            item { ImportStatusCard(state.importStatus) }
                        } else {
                            item {
                                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                    FilterChip(
                                        selected = state.pane == HomeroomPane.Overview,
                                        onClick = { viewModel.selectPane(HomeroomPane.Overview) },
                                        label = { Text("Tổng quan") },
                                        modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
                                    )
                                    FilterChip(
                                        selected = state.pane == HomeroomPane.Pending,
                                        onClick = { viewModel.selectPane(HomeroomPane.Pending) },
                                        label = { Text("Vắng chờ xử lý (${state.pending?.total ?: 0})") },
                                        modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
                                    )
                                }
                            }
                            if (state.pane == HomeroomPane.Overview) {
                                overviewItems(state.overview) { klass ->
                                    viewModel.openClass(klass.id)
                                }
                            } else {
                                pendingItems(state.pending)
                            }
                        }
                    }
                }
            }
        }
    }
}

private fun androidx.compose.foundation.lazy.LazyListScope.overviewItems(overview: HomeroomOverview?, onClass: (HomeroomClassSummary) -> Unit) {
    if (overview == null) return
    item {
        val message = when {
            overview.schoolDay.outsideYear -> "Ngày đã chọn nằm ngoài năm học ${overview.schoolYear.name}."
            !overview.schoolDay.isSchoolDay -> overview.schoolDay.note.ifBlank { "Không phải ngày học; không cần điểm danh." }
                        overview.missingUpload.shouldAlert -> "Đã quá ${overview.missingUpload.cutoffTime}; ${overview.missingUpload.missingClassCodes.size} lớp chưa có dữ liệu: ${overview.missingUpload.missingClassCodes.joinToString()}"
            else -> null
        }
        if (message != null) NoticeCard(message, overview.missingUpload.shouldAlert)
    }
    item {
        val counts = overview.counts
        Card(modifier = Modifier.fillMaxWidth()) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("Tổng quan ngày ${formatDate(overview.date)}", fontWeight = FontWeight.SemiBold)
                Text("${overview.studentCount} học sinh · ${overview.classes.size} lớp · ${overview.pendingTotal} buổi vắng chờ xử lý")
                Text("Có mặt ${counts.present} · Trễ ${counts.late} · Vắng ${counts.absent} · Chưa có dữ liệu ${counts.noData}")
                Text(
                    if (overview.ratedRows > 0) "Chuyên cần ${"%.1f".format(overview.attendanceRate * 100)}%" else "Chuyên cần — (chưa có dữ liệu đánh giá)",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
    if (overview.classes.isEmpty()) {
        item { NoticeCard("Bạn chưa có lớp chủ nhiệm trong ngày này hoặc năm học chưa có lớp đang hoạt động.", false) }
    } else {
        items(overview.classes, key = { it.id }) { ClassCard(it, onClass) }
    }
}

private fun androidx.compose.foundation.lazy.LazyListScope.pendingItems(pending: lvt.crm.data.homeroom.PendingAbsences?) {
    if (pending == null) return
    item {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            NoticeCard("Vắng chờ xử lý toàn năm học, không lọc theo ngày tổng quan. Chọn rõ từng buổi được phép ở danh sách phân loại phía trên; tối đa 100 buổi duy nhất, không tự chọn phần bị giới hạn.", false)
            if (pending.truncated) NoticeCard("Đang hiển thị ${pending.rows.size}/${pending.total} buổi mới nhất. Danh sách đã bị giới hạn bởi máy chủ.", true)
        }
    }
    if (pending.rows.isEmpty()) {
        item { NoticeCard("Không còn buổi vắng nào chờ xử lý.", false) }
    } else {
        items(pending.rows, key = { it.id }) { PendingCard(it) }
    }
}

@Composable
private fun ContextControls(
    years: List<Pair<String, String>>,
    selectedYearId: String?,
    date: String,
    onYear: (String) -> Unit,
    onDate: (String) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    val context = LocalContext.current
    val selected = years.firstOrNull { it.first == selectedYearId }
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Column(modifier = Modifier.weight(1f)) {
            OutlinedButton(onClick = { expanded = true }, modifier = Modifier.fillMaxWidth()) {
                Text(selected?.second ?: "Chọn năm học")
            }
            DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                years.forEach { (id, name) ->
                    DropdownMenuItem(text = { Text(name) }, onClick = { expanded = false; onYear(id) })
                }
            }
        }
        OutlinedButton(
            modifier = Modifier.weight(1f),
            onClick = {
                val current = runCatching { LocalDate.parse(date) }.getOrDefault(LocalDate.now())
                DatePickerDialog(
                    context,
                    { _, year, month, day -> onDate(LocalDate.of(year, month + 1, day).toString()) },
                    current.year,
                    current.monthValue - 1,
                    current.dayOfMonth,
                ).show()
            },
        ) { Text(formatDate(date)) }
    }
}

@Composable
private fun ClassCard(row: HomeroomClassSummary, onClass: (HomeroomClassSummary) -> Unit) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(5.dp)) {
            Text("${row.code} · ${row.name}", fontWeight = FontWeight.SemiBold)
            Text("Khối ${row.gradeLevel ?: "—"} · Sĩ số ${row.rosterCount}${row.teacherName.takeIf { it.isNotBlank() }?.let { " · GVCN $it" } ?: ""}")
            if (row.published) {
                Text("Có mặt ${row.counts.present} · Trễ ${row.counts.late} · Vắng ${row.counts.absent} · Chưa có dữ liệu ${row.counts.noData}")
            } else {
                Text("Chưa có dữ liệu điểm danh", color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Text("Chờ xử lý ${row.pendingTotal} · Quyền phân loại: ${if (row.canCorrect) "Có" else "Không"} · Chỉ xem.")
            OutlinedButton(onClick = { onClass(row) }, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text("Xem danh sách lớp và điểm danh · ${row.code}") }
        }
    }
}

@Composable
private fun PendingCard(row: PendingAbsence) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(row.fullName, fontWeight = FontWeight.SemiBold)
            Text("${row.studentCode} · Lớp ${row.classCode} · ${formatDate(row.attendanceDate)}")
            if (row.note.isNotBlank()) Text(row.note)
            Text("Quyền phân loại từ máy chủ: ${if (row.canCorrect) "Có" else "Không"}", color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun SupervisorNotice() = NoticeCard(
    "Giám thị: trạng thái nhập điểm danh toàn trường, chỉ xem. Chọn tệp, kiểm tra và công bố sẽ được triển khai ở L4; màn hình này không cấp quyền xem danh sách lớp/học sinh.",
    false,
)

@Composable
private fun ImportStatusCard(status: ImportStatus?) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(7.dp)) {
            Text("Tình trạng nhập điểm danh", fontWeight = FontWeight.SemiBold)
            Text("Đã có dữ liệu cho ${status?.publishedClassCount ?: 0} lớp.")
            val uploads = status?.uploads.orEmpty()
            if (uploads.isEmpty()) Text("Chưa công bố file nào cho ngày này.")
            uploads.forEach { upload ->
                Text("${upload.fileName} · ${upload.matchedCount}/${upload.rowCount} dòng khớp · ${upload.uploadedByName.ifBlank { "Không rõ người nhập" }}")
            }
        }
    }
}

@Composable
private fun NoticeCard(message: String, warning: Boolean) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = if (warning) MaterialTheme.colorScheme.errorContainer else MaterialTheme.colorScheme.secondaryContainer,
        ),
    ) { Text(message, modifier = Modifier.padding(14.dp)) }
}

@Composable
private fun CenteredLoading() = Column(
    modifier = Modifier.fillMaxSize(),
    verticalArrangement = Arrangement.Center,
    horizontalAlignment = Alignment.CenterHorizontally,
) {
    CircularProgressIndicator()
    Text("Đang tải lớp chủ nhiệm…", modifier = Modifier.padding(top = 12.dp))
}

internal fun formatDate(value: String): String = runCatching {
    val date = LocalDate.parse(value)
    "%02d/%02d/%04d".format(date.dayOfMonth, date.monthValue, date.year)
}.getOrDefault(value)
