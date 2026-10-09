package lvt.crm.ui.homeroom

import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
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
import android.provider.OpenableColumns
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import lvt.crm.data.homeroom.CameraImportFile
import lvt.crm.data.homeroom.CameraImportStore

@Composable
fun HomeroomCameraImportScreen(store: CameraImportStore, onClose: () -> Unit) {
    val state by store.state.collectAsState()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var mode by remember(store) { mutableStateOf<String?>(null) }
    var confirm by remember(store) { mutableStateOf(false) }
    var picking by remember(store) { mutableStateOf(false) }
    var reading by remember(store) { mutableStateOf(false) }
    var readError by remember(store) { mutableStateOf<String?>(null) }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        picking = false
        if (uri != null) { reading = true; scope.launch {
            try {
                val (name, bytes) = withContext(Dispatchers.IO) {
                    val resolver = context.contentResolver
                    val name = resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                        if (cursor.moveToFirst()) cursor.getString(cursor.getColumnIndexOrThrow(OpenableColumns.DISPLAY_NAME)) else null
                    } ?: throw IllegalArgumentException("Không đọc được tên file.")
                    val bytes = resolver.openInputStream(uri)?.use(CameraImportFile::read) ?: throw IllegalArgumentException("Không đọc được file.")
                    name to bytes
                }
                readError = null; store.picked(name, bytes)
            } catch (error: Exception) { readError = "Không đọc được file: ${error.message}" }
            finally { reading = false }
        } } else scope.launch { store.picked(null, null) }
    }
    DisposableEffect(store) { onDispose { store.invalidate() } }
    LaunchedEffect(store) { store.refreshStatus() }
    BackHandler { store.invalidate(); onClose() }
    Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Nhập camera toàn trường · ${store.yearId} · Ngày Việt Nam: ${store.date}")
        Text("File camera toàn trường: Lớp học, Tên học sinh, Ngày sinh, Trạng thái điểm danh; Thời gian điểm danh nếu có. Nhận diện bằng lớp + họ tên + ngày sinh. Tối đa 3.000 dòng; máy chủ kiểm tra mẫu.")
        OutlinedButton(onClick = { store.invalidate(); onClose() }) { Text("Đóng") }
        Text(state.message)
        readError?.let { Text(it) }
        if (state.busy || reading) CircularProgressIndicator()
        Button(enabled = !state.busy && !state.locked && store.storageId == null && store.uploadId == null && !picking && !reading, onClick = { picking = true; picker.launch(arrayOf("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")) }) { Text("Chọn Excel .xlsx · tối đa 4 MiB") }
        if (store.canStartNew) OutlinedButton(onClick = { mode = null; store.newFile() }) { Text("Bỏ bản hiện tại ở ứng dụng và chọn file khác (không xóa trên máy chủ)") }
        store.previousUploads.forEach { Text("Lịch sử cục bộ: $it") }
        store.storageId?.let { Text("Storage: $it") }; store.uploadId?.let { Text("Bản đăng ký: $it") }
        OutlinedButton(enabled = !state.busy, onClick = { scope.launch { store.refreshStatus() } }) { Text("Tải lại danh sách đã công bố (không gửi lại)") }
        if (store.uploadId != null) OutlinedButton(enabled = !state.busy && !state.locked, onClick = { mode = null; confirm = false; scope.launch { store.refreshPreview() } }) { Text("Kiểm tra lại bản xem trước; chọn lại chế độ") }
        state.status?.let { status ->
            Text("Đã có dữ liệu: ${status.publishedClassCount} lớp. Danh sách chỉ chứa file đã công bố.")
            val formatter = java.time.format.DateTimeFormatter.ofPattern("dd/MM/yyyy HH:mm").withZone(java.time.ZoneId.of("Asia/Ho_Chi_Minh"))
            status.uploads.forEach {
                val publishedTime = if (it.publishedAt > 0) formatter.format(java.time.Instant.ofEpochMilli(it.publishedAt)) else "Chưa có thời điểm công bố"
                Text("${it.fileName} · ${it.uploadedByName} · $publishedTime · ${it.rowCount} dòng / ${it.matchedCount} khớp · ID ${it.id}")
            }
        }
        state.preview?.let { preview ->
            val value = preview.value
            Text("${value.getString("fileName")} · Sheet ${value.getString("sheetName")} · ${value.getInt("totalRows")} dòng / ${value.getInt("matchedCount")} khớp · ${value.getInt("errorCount")} lỗi / ${value.getInt("warningCount")} cảnh báo · ok=${value.getBoolean("ok")}")
            val day = value.getJSONObject("schoolDay")
            Text("Lịch: ${day.getString("kind")} · ${day.getString("note")} · ngày học ${day.getBoolean("isSchoolDay")} · ngoài năm ${day.getBoolean("outsideYear")}")
            Text("Lớp lỗi/không có dòng bị bỏ qua. Học sinh trong sĩ số lớp có thể công bố nhưng thiếu trong file thành vắng chờ xử lý. Không sửa phân loại GVCN ở màn hình này.")
            preview.classes.forEach { row ->
                Text("${row.getString("code")} · ${row.getString("name")} · ${if (row.getBoolean("publishable")) "Có thể công bố" else "Bỏ qua"} · đã có dữ liệu: ${row.getBoolean("alreadyPublished")}\nDòng ${row.getInt("rowCount")} / khớp ${row.getInt("matchedCount")}, sĩ số ${row.getInt("rosterCount")}, thiếu ${row.getInt("missingCount")}; có mặt ${row.getInt("present")}, muộn ${row.getInt("late")}, vắng ${row.getInt("absent")}; lỗi ${row.getInt("errorCount")}, cảnh báo ${row.getInt("warningCount")}")
            }
            val empty = value.getJSONArray("classesWithoutRows")
            for (index in 0 until empty.length()) empty.getJSONObject(index).let { Text("Bỏ qua — không có dòng: ${it.getString("code")} · ${it.getString("name")} · đã công bố: ${it.getBoolean("alreadyPublished")}") }
            if (value.getBoolean("issuesTruncated")) Text("Máy chủ đã cắt danh sách lỗi (tối đa 400); tổng lỗi/cảnh báo vẫn hiển thị.")
            val issues = value.getJSONArray("issues")
            for (index in 0 until issues.length()) issues.getJSONObject(index).let { Text("${it.getString("severity")} · Dòng ${it.getInt("rowNumber")} · ${it.getString("field")} / ${it.getString("column")} · ${if (it.isNull("rejectedValue")) "—" else it.getString("rejectedValue")} · ${it.getString("code")}\n${it.getString("message")}") }
            if (preview.conflicts) listOf("Bổ sung — giữ quan sát và phân loại đã có", "Thay quan sát camera — giữ phân loại GVCN khi còn hợp lệ", "Bỏ qua lớp đã có dữ liệu — vẫn công bố lớp mới").forEachIndexed { index, label ->
                OutlinedButton(enabled = !state.busy, onClick = { mode = CameraImportStore.modes[index] }) { Text("${if (mode == CameraImportStore.modes[index]) "✓ " else ""}$label") }
            }
            val rows = preview.classes.filter { it.getBoolean("publishable") && (mode != "cancel" || !it.getBoolean("alreadyPublished")) }
            Button(enabled = !state.busy && !state.locked && rows.isNotEmpty() && (!preview.conflicts || mode != null), onClick = { confirm = true }) { Text("Công bố ${rows.size} lớp · thiếu ${rows.sumOf { it.getInt("missingCount") }} học sinh") }
        }
    }
    if (confirm) AlertDialog(onDismissRequest = { confirm = false }, title = { Text("Xác nhận công bố") }, text = { Text("Ngày Việt Nam ${store.date} · ${mode ?: "Công bố mới"}. Lớp lỗi/không có dòng bị bỏ qua. Học sinh thiếu thành vắng chờ xử lý. Ghi điểm danh, không tự động gửi lại.") }, confirmButton = { Button(onClick = { confirm = false; scope.launch { store.publish(mode, true) } }) { Text("Công bố") } }, dismissButton = { OutlinedButton(onClick = { confirm = false }) { Text("Quay lại") } })
}
