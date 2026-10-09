package lvt.crm.data.homeroom

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.*
import kotlinx.coroutines.withContext
import lvt.crm.ui.homeroom.HomeroomDetailViewModel
import lvt.crm.ui.homeroom.HomeroomViewModel
import lvt.crm.ui.homeroom.matchesStudent
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class HomeroomDetailTest {
    private val context = DetailContext("year", "class", "2026-10-07", "2026-08-01", "2027-06-01")

    @Test fun `strict decoding does not invent statuses or permissions`() {
        val daily = decodeClassDaily(JSONObject("""{"date":"2026-10-07","rows":[],"published":false,"archived":false,"canCorrect":false,"schoolDay":{"isSchoolDay":false,"kind":"weekend","outsideYear":false}}"""))
        assertTrue(daily.rows.isEmpty())
        assertFalse(daily.canCorrect)
        for (bad in listOf("{}", """{"date":"2026-02-30","rows":[],"published":false,"archived":false,"canCorrect":false,"schoolDay":{}}""")) {
            assertTrue(runCatching { decodeClassDaily(JSONObject(bad)) }.isFailure)
        }
        val roster = JSONObject("""{"rows":[],"showContacts":false}""")
        assertTrue(decodeClassRoster(roster).rows.isEmpty())
        roster.put("showContacts", "false")
        assertTrue(runCatching { decodeClassRoster(roster) }.isFailure)
        assertTrue(runCatching { decodeStudentHistory(JSONObject("""{"days":[],"corrections":"bad"}""")) }.isFailure)
    }

    @Test fun `denied refresh clears class profile history and retry can recover`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        Dispatchers.setMain(dispatcher)
        try {
            val fake = DetailFake()
            val model = HomeroomDetailViewModel(fake, context)
            advanceUntilIdle()
            assertNotNull(model.uiState.value.classData)
            model.openStudent("student")
            advanceUntilIdle()
            assertNotNull(model.uiState.value.studentData)
            fake.denied = true
            model.refresh()
            runCurrent()
            assertNull(model.uiState.value.classData)
            assertNull(model.uiState.value.studentData)
            advanceUntilIdle()
            assertNotNull(model.uiState.value.error)
            fake.denied = false
            model.refresh()
            advanceUntilIdle()
            assertNotNull(model.uiState.value.studentData)
        } finally { Dispatchers.resetMain() }
    }

    @Test fun `stale student completion cannot replace a newer date or class`() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        try {
            val fake = DetailFake()
            val model = HomeroomDetailViewModel(fake, context)
            advanceUntilIdle()
            fake.block = true
            model.openStudent("student")
            runCurrent()
            model.selectDate("2026-10-06")
            runCurrent()
            assertNull(model.uiState.value.studentId)
            fake.release.complete(Unit)
            advanceUntilIdle()
            assertEquals("2026-10-06", model.uiState.value.context.date)
            assertNull(model.uiState.value.studentData)
            assertEquals("2026-10-06", model.uiState.value.classData?.daily?.date)
        } finally { Dispatchers.resetMain() }
    }

    @Test fun `history retains all returned rows including beyond pending cap`() {
        val day = """{"_id":"day","studentId":"student","classId":"class","attendanceDate":"2026-10-07","rawObservation":"late","disposition":"none","effectiveStatus":"late"}"""
        val history = decodeStudentHistory(JSONObject("""{"days":[${List(501) { day.replace("\"day\"", "\"day$it\"") }.joinToString()}],"corrections":[]}"""))
        assertEquals(501, history.days.size)
        assertTrue(history.corrections.isEmpty())
        assertTrue(runCatching { decodeStudentHistory(JSONObject("""{"days":[${day.replace("\"late\"", "\"unknown\"")}],"corrections":[]}""")) }.isFailure)
    }

    @Test fun `daily missing observation is explicit null not missing malformed field`() {
        val student = """{"_id":"student","studentCode":"S01","fullName":"Học sinh"}"""
        val prefix = """{"date":"2026-10-07","published":false,"archived":false,"canCorrect":false,"schoolDay":{"isSchoolDay":true,"kind":"school_day","outsideYear":false},"rows":[{"enrollment":{"_id":"enrollment"},"student":$student"""
        val noData = decodeClassDaily(JSONObject("$prefix,\"day\":null}]}"))
        assertNull(noData.rows.single().day)
        assertEquals("Chưa có dữ liệu", attendanceStatusText("no_data"))
        assertTrue(runCatching { decodeClassDaily(JSONObject("$prefix}]}")) }.isFailure)
        val unknown = """{"_id":"day","rawObservation":"unknown","disposition":"pending","effectiveStatus":"no_data"}"""
        assertEquals("no_data", decodeClassDaily(JSONObject("$prefix,\"day\":$unknown}]}" )).rows.single().day?.effectiveStatus)
        assertTrue(matchesStudent(noData.rows.single().student, "hoc sinh"))
        assertTrue(matchesStudent(noData.rows.single().student, "s01"))
        assertFalse(matchesStudent(noData.rows.single().student, "no match"))
    }

    @Test fun `exact query args redaction historical range and identity are enforced`() = runTest {
        val calls = mutableListOf<Pair<String, JSONObject>>()
        val repo = HomeroomDetailRepository { path, args ->
            calls += path to args
            detailFixture(path, context.date)
        }
        val classData = repo.loadClass(context)
        assertFalse(classData.daily.canCorrect)
        assertEquals(listOf("homeroomClasses:getScoped", "students:listByClass", "studentAttendance:listDailyClass"), calls.map { it.first })
        assertEquals(setOf("classId", "date"), calls[0].second.keys().asSequence().toSet())
        assertEquals(setOf("classId", "date", "includeSensitiveContacts"), calls[1].second.keys().asSequence().toSet())
        assertEquals(false, calls[1].second.getBoolean("includeSensitiveContacts"))
        assertEquals(setOf("classId", "attendanceDate"), calls[2].second.keys().asSequence().toSet())
        assertEquals(context.date, calls[2].second.getString("attendanceDate"))
        calls.clear()
        val student = repo.loadStudent(context, "student")
        assertNull(student.profile.student.studentPhone)
        assertTrue(student.profile.guardians.isEmpty())
        assertFalse(student.profile.showContacts)
        assertFalse(student.profile.canEditContacts)
        assertEquals(listOf("students:getScoped", "studentAttendance:getStudentHistory"), calls.map { it.first })
        assertEquals(setOf("studentId", "includeSensitiveContacts"), calls[0].second.keys().asSequence().toSet())
        assertEquals(setOf("studentId", "from", "to"), calls[1].second.keys().asSequence().toSet())
        assertEquals(context.from, calls[1].second.getString("from"))
        assertEquals(context.to, calls[1].second.getString("to"))
        val wrong = HomeroomDetailRepository { path, _ -> detailFixture(path, "2026-10-06") }
        assertTrue(runCatching { wrong.loadClass(context) }.isFailure)
        assertTrue(runCatching { repo.loadStudent(context, "wrong-student") }.isFailure)
        assertTrue(runCatching { repo.loadClass(context.copy(date = "2026-02-30")) }.isFailure)
        assertTrue(runCatching { repo.loadStudent(context.copy(from = context.to, to = context.from), "student") }.isFailure)
    }

    @Test fun `negative class student and history access never expose successful partial reads`() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        try {
            for (deniedPath in listOf("homeroomClasses:getScoped", "students:listByClass", "studentAttendance:listDailyClass", "students:getScoped", "studentAttendance:getStudentHistory")) {
                val calls = mutableListOf<String>()
                var revoked = false
                val repo = HomeroomDetailRepository { path, _ ->
                    calls += path
                    if (revoked && path == deniedPath) error("HOMEROOM_SCOPE_FORBIDDEN")
                    detailFixture(path, context.date)
                }
                val model = HomeroomDetailViewModel(repo, context)
                advanceUntilIdle()
                if (deniedPath.startsWith("students:getScoped") || deniedPath.endsWith("getStudentHistory")) {
                    model.openStudent("student")
                    advanceUntilIdle()
                }
                assertTrue(model.uiState.value.classData != null || model.uiState.value.studentData != null)
                revoked = true
                model.refresh()
                assertNull(model.uiState.value.classData)
                assertNull(model.uiState.value.studentData)
                advanceUntilIdle()
                assertNotNull(deniedPath, model.uiState.value.error)
                assertNull(model.uiState.value.classData)
                assertNull(model.uiState.value.studentData)
                assertEquals(deniedPath, calls.last())
                model.close()
            }
        } finally { Dispatchers.resetMain() }
    }

    @Test fun `supervisor overview cannot open arbitrary class or send detail queries`() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        try {
            var detailCalls = 0
            val details = HomeroomDetailRepository { _, _ -> detailCalls++; error("Should not query") }
            val overview = object : HomeroomOperations {
                override suspend fun listSchoolYears() = listOf(SchoolYear("year", "Năm", context.from, context.to, true))
                override suspend fun importStatus(schoolYearId: String, date: String) = ImportStatus(0, emptyList())
                override suspend fun overview(schoolYearId: String, date: String): HomeroomOverview = error("Supervisor cannot read overview")
                override suspend fun pendingAbsences(schoolYearId: String): PendingAbsences = error("Supervisor cannot read pending")
            }
            val model = HomeroomViewModel(overview, true, details)
            advanceUntilIdle()
            model.openClass("class")
            assertNull(model.detailState.value)
            assertEquals(0, detailCalls)
        } finally { Dispatchers.resetMain() }
    }

    @Test fun `malformed refresh clears loaded class and history corrections remain exact`() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        try {
            var malformed = false
            val repo = HomeroomDetailRepository { path, _ -> if (malformed) JSONObject() else detailFixture(path, context.date) }
            val model = HomeroomDetailViewModel(repo, context)
            advanceUntilIdle()
            assertNotNull(model.uiState.value.classData)
            malformed = true
            model.refresh()
            assertNull(model.uiState.value.classData)
            advanceUntilIdle()
            assertNotNull(model.uiState.value.error)
            assertFalse(model.uiState.value.loading)
            val history = decodeStudentHistory(JSONObject("""{"days":[],"corrections":[{"_id":"correction","attendanceDayId":"day","studentId":"student","attendanceDate":"2026-10-07","previousDisposition":"pending","nextDisposition":"excused","previousEffectiveStatus":"absent_pending","nextEffectiveStatus":"absent_excused","reasonCode":"leave","note":"Có phép","actorUserId":"teacher","at":1791356400000}]}"""))
            assertEquals(1, history.corrections.size)
            assertEquals("absent_excused", history.corrections.single().nextStatus)
            assertEquals("Có phép", history.corrections.single().note)
            model.close()
        } finally { Dispatchers.resetMain() }
    }

    @Test fun `cancelled scoped query does not continue roster chain`() = runTest {
        val release = CompletableDeferred<Unit>()
        val calls = mutableListOf<String>()
        val repo = HomeroomDetailRepository { path, _ ->
            calls += path
            withContext(NonCancellable) { release.await() }
            detailFixture(path, context.date)
        }
        val job = launch { repo.loadClass(context) }
        runCurrent()
        job.cancel()
        release.complete(Unit)
        advanceUntilIdle()
        assertEquals(listOf("homeroomClasses:getScoped"), calls)
    }

    @Test fun `closed previous navigation cannot repopulate cached student`() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        try {
            val fake = DetailFake()
            val model = HomeroomDetailViewModel(fake, context)
            advanceUntilIdle()
            fake.block = true
            model.openStudent("student")
            runCurrent()
            model.close()
            fake.release.complete(Unit)
            advanceUntilIdle()
            assertNull(model.uiState.value.classData)
            assertNull(model.uiState.value.studentData)
            assertFalse(model.uiState.value.loading)
            assertNull(model.uiState.value.error)
        } finally { Dispatchers.resetMain() }
    }
}

private fun detailFixture(path: String, date: String): JSONObject = JSONObject(when (path) {
    "homeroomClasses:getScoped" -> """{"class":{"_id":"class","schoolYearId":"year","code":"10A","name":"Lớp 10A","status":"active"},"schoolYear":{"_id":"year","name":"Năm học"},"assignments":[],"currentTeacherName":"","rosterCount":1,"permissions":{"canManage":false,"canImportAttendance":false,"canCorrect":false,"canEditContacts":false}}"""
    "students:listByClass" -> """{"showContacts":false,"rows":[{"enrollment":{"_id":"enrollment","startDate":"2026-08-01","rosterNumber":1},"student":{"_id":"student","studentCode":"S01","fullName":"Học sinh","studentPhone":"must-not-cache"},"guardians":[]}]}"""
    "studentAttendance:listDailyClass" -> """{"date":"$date","rows":[],"published":false,"archived":false,"canCorrect":false,"schoolDay":{"isSchoolDay":true,"kind":"school_day","outsideYear":false}}"""
    "students:getScoped" -> """{"student":{"_id":"student","studentCode":"S01","fullName":"Học sinh","status":"active","studentPhone":"must-not-cache"},"enrollments":[],"guardians":[],"showContacts":false,"permissions":{"canManage":false,"canEditContacts":false}}"""
    "studentAttendance:getStudentHistory" -> """{"days":[],"corrections":[]}"""
    else -> error("Unexpected RPC: $path")
})

private class DetailFake : HomeroomDetailOperations {
    var denied = false
    var block = false
    val release = CompletableDeferred<Unit>()
    override suspend fun loadClass(context: DetailContext): ClassDetail {
        if (denied) error("HOMEROOM_SCOPE_FORBIDDEN")
        return ClassDetail(
            ScopedClass(context.classId, context.yearId, "10A", "Lớp 10A", "active", "", 0, false),
            ClassRoster(listOf(RosterRow(RosterEnrollment("enrollment", 1, "2026-08-01"), StudentIdentity("student", "S01", "Học sinh", null, null, null))), false),
            ClassDaily(context.date, emptyList(), false, false, false, SchoolDay(true, "school", "", false)),
        )
    }
    override suspend fun loadStudent(context: DetailContext, studentId: String): StudentDetail {
        if (block) withContext(NonCancellable) { release.await() }
        if (denied) error("HOMEROOM_SCOPE_FORBIDDEN")
        return StudentDetail(StudentProfile(StudentIdentity(studentId, "S01", "Học sinh", null, null, null), "active", emptyList(), emptyList(), false, false, false), StudentHistory(emptyList(), emptyList()))
    }
}
