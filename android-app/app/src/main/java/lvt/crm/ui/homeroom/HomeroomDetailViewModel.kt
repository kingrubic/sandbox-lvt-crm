package lvt.crm.ui.homeroom

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import lvt.crm.data.homeroom.*

data class HomeroomDetailState(
    val context: DetailContext,
    val studentId: String? = null,
    val classData: ClassDetail? = null,
    val studentData: StudentDetail? = null,
    val loading: Boolean = false,
    val error: String? = null,
)

class HomeroomDetailViewModel(private val repository: HomeroomDetailOperations, context: DetailContext, val writeOperations: HomeroomWriteRepository? = null) : ViewModel() {
    private val state = MutableStateFlow(HomeroomDetailState(context))
    val uiState = state.asStateFlow()
    private var generation = 0
    private var job: Job? = null

    init { refresh() }

    fun refresh() {
        job?.cancel()
        val version = ++generation
        state.update { it.copy(classData = null, studentData = null, error = null, loading = true) }
        val request = state.value
        job = viewModelScope.launch {
            try {
                request.context.validate()
                val studentId = request.studentId
                val classData = if (studentId == null) repository.loadClass(request.context) else null
                val studentData = if (studentId != null) repository.loadStudent(request.context, studentId) else null
                if (version != generation) return@launch
                state.update { it.copy(classData = classData, studentData = studentData, loading = false) }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                if (version != generation) return@launch
                state.update { it.copy(classData = null, studentData = null, loading = false, error = error.message ?: "Không tải được dữ liệu.") }
            }
        }
    }

    fun selectDate(date: String) {
        if (!isVietnamDate(date) || date == state.value.context.date) return
        state.update { it.copy(context = it.context.copy(date = date), studentId = null) }
        refresh()
    }

    fun openStudent(id: String) {
        val data = state.value.classData ?: return
        if (data.roster.rows.none { it.student.id == id } && data.daily.rows.none { it.student.id == id }) return
        state.update { it.copy(studentId = id) }
        refresh()
    }

    fun backToClass() {
        state.update { it.copy(studentId = null) }
        refresh()
    }

    fun selectHistoryRange(from: String, to: String) {
        if (!isVietnamDate(from) || !isVietnamDate(to) || from > to) return
        state.update { it.copy(context = it.context.copy(from = from, to = to)) }
        refresh()
    }

    fun close() {
        generation++
        job?.cancel()
        state.update { it.copy(classData = null, studentData = null, loading = false, error = null) }
    }
    fun clearWriteData() { state.update { it.copy(classData = null, studentData = null) } }
}
