package lvt.crm.ui.homeroom

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import lvt.crm.data.convex.ConvexException
import lvt.crm.data.convex.ConvexHttpClient
import lvt.crm.data.homeroom.HomeroomOperations
import lvt.crm.data.homeroom.HomeroomOverview
import lvt.crm.data.homeroom.ImportStatus
import lvt.crm.data.homeroom.PendingAbsences
import lvt.crm.data.homeroom.SchoolYear
import lvt.crm.data.homeroom.vietnamToday
import lvt.crm.data.homeroom.isVietnamDate

enum class HomeroomPane { Overview, Pending }

data class HomeroomUiState(
    val loading: Boolean = true,
    val refreshing: Boolean = false,
    val error: String? = null,
    val years: List<SchoolYear> = emptyList(),
    val selectedYearId: String? = null,
    val date: String = vietnamToday(),
    val pane: HomeroomPane = HomeroomPane.Overview,
    val overview: HomeroomOverview? = null,
    val pending: PendingAbsences? = null,
    val importStatus: ImportStatus? = null,
    val supervisor: Boolean = false,
)

class HomeroomViewModel(
    private val repository: HomeroomOperations,
    supervisor: Boolean,
    private val detailOperations: lvt.crm.data.homeroom.HomeroomDetailOperations? =
        (repository as? lvt.crm.data.homeroom.HomeroomRepository)?.detailOperations,
) : ViewModel() {
    val writeOperations = (repository as? lvt.crm.data.homeroom.HomeroomRepository)?.writeOperations
    private val cameraStores = mutableMapOf<String, lvt.crm.data.homeroom.CameraImportStore>()
    private val managementStores = mutableMapOf<String, lvt.crm.data.homeroom.HomeroomManagementStore>()
    fun management(): lvt.crm.data.homeroom.HomeroomManagementStore? {
        val year = uiState.value.selectedYearId ?: return null
        val date = uiState.value.date
        val key = "$year/$date"
        return managementStores[key] ?: (repository as? lvt.crm.data.homeroom.HomeroomRepository)?.management(year, date) { uiState.value.selectedYearId == year && uiState.value.date == date }?.also { managementStores[key] = it }
    }
    fun cameraImport(): lvt.crm.data.homeroom.CameraImportStore? {
        val year = uiState.value.selectedYearId ?: return null
        val date = uiState.value.date
        val key = "$year/$date"
        return cameraStores[key] ?: (repository as? lvt.crm.data.homeroom.HomeroomRepository)?.cameraImport(year, date) { uiState.value.selectedYearId == year && uiState.value.date == date }?.also { cameraStores[key] = it }
    }
    private val detail = MutableStateFlow<HomeroomDetailViewModel?>(null)
    val detailState = detail.asStateFlow()
    private val _uiState = MutableStateFlow(HomeroomUiState(supervisor = supervisor))
    val uiState: StateFlow<HomeroomUiState> = _uiState.asStateFlow()
    private var loadJob: Job? = null
    private var generation = 0

    init { load(initial = true, reloadYears = true) }

    fun refresh() = load(initial = false, reloadYears = false)

    fun openClass(id: String) {
        val current = _uiState.value
        val operations = detailOperations ?: return
        val year = current.years.firstOrNull { it.id == current.selectedYearId } ?: return
        if (current.supervisor || current.overview?.classes?.none { it.id == id } != false) return
        detail.value?.close()
        detail.value = HomeroomDetailViewModel(operations, lvt.crm.data.homeroom.DetailContext(year.id, id, current.date, year.startDate, year.endDate), writeOperations)
        loadJob?.cancel()
        generation++
        _uiState.update { it.copy(overview = null, pending = null, importStatus = null) }
    }

    fun closeDetail() {
        val date = detail.value?.uiState?.value?.context?.date
        detail.value?.close()
        detail.value = null
        if (date != null) _uiState.update { it.copy(date = date) }
        refresh()
    }
    fun clearWriteData() { _uiState.update { it.copy(overview = null, pending = null) } }

    override fun onCleared() {
        managementStores.values.forEach { it.invalidate() }
        detail.value?.close()
        super.onCleared()
    }

    fun selectYear(id: String) {
        if (_uiState.value.years.none { it.id == id }) return
        if (_uiState.value.selectedYearId == id) return
        managementStores.values.forEach { it.invalidate() }
        _uiState.update { it.copy(selectedYearId = id, overview = null, pending = null, importStatus = null) }
        load(initial = true, reloadYears = false)
    }

    fun selectDate(date: String) {
        if (!isVietnamDate(date)) return
        if (_uiState.value.date == date) return
        managementStores.values.forEach { it.invalidate() }
        _uiState.update { it.copy(date = date, overview = null, importStatus = null) }
        load(initial = true, reloadYears = false)
    }

    fun selectPane(pane: HomeroomPane) {
        if (_uiState.value.supervisor || _uiState.value.pane == pane) return
        _uiState.update { it.copy(pane = pane) }
    }

    private fun load(initial: Boolean, reloadYears: Boolean) {
        loadJob?.cancel()
        val version = ++generation
        val request = _uiState.value
        _uiState.update { it.copy(loading = initial, refreshing = !initial, error = null, overview = null, pending = null, importStatus = null) }
        loadJob = viewModelScope.launch {
            try {
                val years = if (reloadYears || request.years.isEmpty()) repository.listSchoolYears() else request.years
                val yearId = request.selectedYearId?.takeIf { id -> years.any { it.id == id } }
                    ?: years.firstOrNull { it.active }?.id
                    ?: years.firstOrNull()?.id
                if (version != generation) return@launch
                _uiState.update { it.copy(years = years, selectedYearId = yearId) }
                if (yearId == null) {
                    _uiState.update {
                        it.copy(loading = false, refreshing = false, years = years, selectedYearId = null)
                    }
                    return@launch
                }
                if (request.supervisor) {
                    val status = repository.importStatus(yearId, request.date)
                    if (version != generation) return@launch
                    _uiState.update {
                        it.copy(
                            loading = false,
                            refreshing = false,
                            years = years,
                            selectedYearId = yearId,
                            importStatus = status,
                        )
                    }
                } else {
                    val overview = repository.overview(yearId, request.date)
                    require(overview.date == request.date && overview.schoolYear.id == yearId) {
                        "Phản hồi không khớp năm học/ngày đã chọn."
                    }
                    val pending = repository.pendingAbsences(yearId)
                    if (version != generation) return@launch
                    _uiState.update {
                        it.copy(
                            loading = false,
                            refreshing = false,
                            years = years,
                            selectedYearId = yearId,
                            overview = overview,
                            pending = pending,
                        )
                    }
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                if (version != generation) return@launch
                _uiState.update {
                    it.copy(
                        loading = false,
                        refreshing = false,
                        error = (error as? ConvexException)?.message
                            ?: ConvexHttpClient.humanize(error.message ?: "LOAD_FAILED"),
                    )
                }
            }
        }
    }

    companion object {
        fun factory(repository: HomeroomOperations, supervisor: Boolean): ViewModelProvider.Factory =
            object : ViewModelProvider.Factory {
                @Suppress("UNCHECKED_CAST")
                override fun <T : ViewModel> create(modelClass: Class<T>): T =
                    HomeroomViewModel(repository, supervisor) as T
            }
    }
}
