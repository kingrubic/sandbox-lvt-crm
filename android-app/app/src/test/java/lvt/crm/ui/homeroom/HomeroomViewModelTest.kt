package lvt.crm.ui.homeroom

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withContext
import lvt.crm.data.homeroom.*
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class HomeroomViewModelTest {
    private val dispatcher = StandardTestDispatcher()
    @Before fun setup() { Dispatchers.setMain(dispatcher) }
    @After fun teardown() { Dispatchers.resetMain() }

    @Test fun `supervisor queries only published status never overview or pending`() = runTest(dispatcher) {
        val repository = RecordingHomeroomOperations()
        val viewModel = HomeroomViewModel(repository, supervisor = true)
        advanceUntilIdle()
        assertEquals(1, repository.statusCalls)
        assertEquals(0, repository.rosterReadCalls)
        assertNotNull(viewModel.uiState.value.importStatus)
        viewModel.selectPane(HomeroomPane.Pending)
        viewModel.selectDate("2026-02-30")
        viewModel.selectYear("not-returned-by-server")
        assertEquals(HomeroomPane.Overview, viewModel.uiState.value.pane)
        assertEquals(1, repository.statusCalls)
    }

    @Test fun `empty years do not request attendance and errors remain errors`() = runTest(dispatcher) {
        val empty = RecordingHomeroomOperations(emptyYears = true)
        val emptyModel = HomeroomViewModel(empty, supervisor = false)
        advanceUntilIdle()
        assertFalse(emptyModel.uiState.value.loading)
        assertTrue(emptyModel.uiState.value.years.isEmpty())
        assertEquals(0, empty.rosterReadCalls)
        val forbidden = RecordingHomeroomOperations(deny = true)
        val forbiddenModel = HomeroomViewModel(forbidden, supervisor = false)
        advanceUntilIdle()
        assertNotNull(forbiddenModel.uiState.value.error)
        assertNull(forbiddenModel.uiState.value.overview)
        assertNull(forbiddenModel.uiState.value.pending)
    }

    @Test fun `cancelled older request cannot overwrite newer date`() = runTest(dispatcher) {
        val repository = RecordingHomeroomOperations(blockFirst = true)
        val viewModel = HomeroomViewModel(repository, supervisor = true)
        runCurrent()
        viewModel.selectDate("2026-10-06")
        runCurrent()
        assertEquals("2026-10-06", viewModel.uiState.value.date)
        assertEquals(2, viewModel.uiState.value.importStatus?.publishedClassCount)
        repository.release.complete(Unit)
        advanceUntilIdle()
        assertEquals(2, viewModel.uiState.value.importStatus?.publishedClassCount)
        assertNull(viewModel.uiState.value.error)
    }
}

private class RecordingHomeroomOperations(
    private val emptyYears: Boolean = false,
    private val deny: Boolean = false,
    private val blockFirst: Boolean = false,
) : HomeroomOperations {
    var statusCalls = 0
    var rosterReadCalls = 0
    val release = CompletableDeferred<Unit>()
    override suspend fun listSchoolYears(): List<SchoolYear> = if (emptyYears) emptyList() else
        listOf(SchoolYear("test-year", "Test year", "2026-08-01", "2027-06-01", true))
    override suspend fun overview(schoolYearId: String, date: String): HomeroomOverview {
        rosterReadCalls++
        if (deny) error("HOMEROOM_SCOPE_FORBIDDEN")
        error("Unexpected overview query")
    }
    override suspend fun pendingAbsences(schoolYearId: String): PendingAbsences {
        rosterReadCalls++
        error("Unexpected pending query")
    }
    override suspend fun importStatus(schoolYearId: String, date: String): ImportStatus {
        val call = ++statusCalls
        if (blockFirst && call == 1) withContext(NonCancellable) { release.await() }
        return ImportStatus(if (blockFirst) call else 0, emptyList())
    }
}
