package lvt.crm.data.homeroom

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import lvt.crm.data.convex.ConvexHttpClient
import lvt.crm.data.convex.ConvexException
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class HomeroomWritesTest {
    private val context = DetailContext("year", "class", "2026-10-07", "2026-08-01", "2027-06-01")
    private val target = AbsenceTarget("day", "student", context)
    private fun absence(batch: Boolean = false) = HomeroomWritePayload.disposition(listOf(target), "excused", "", "Owner-approved offline fixture", batch)

    @Test fun `offline payload validation and deduplication limits`() {
        val hundred = (1..100).map { target.copy(id = "day$it") }
        assertEquals(100, HomeroomWritePayload.disposition(hundred + hundred, "pending", "", "", true).targets.size)
        assertTrue(runCatching { HomeroomWritePayload.disposition(hundred + target, "pending", "", "", true) }.isFailure)
        for (next in listOf("none", "exempt", "present")) assertTrue(runCatching { HomeroomWritePayload.disposition(listOf(target), next, "reason", "", false) }.isFailure)
        assertTrue(runCatching { HomeroomWritePayload.disposition(listOf(target), "excused", "", "", false) }.isFailure)
        assertTrue(runCatching { HomeroomWritePayload.disposition(listOf(target), "pending", "", "x".repeat(501), false) }.isFailure)
        assertTrue(runCatching { HomeroomWritePayload.disposition(listOf(target, target.copy(studentId = "other")), "pending", "", "", true) }.isFailure)
        for (phone in listOf("12345", "123456789012345678901", "abcd12")) assertTrue(runCatching { HomeroomWritePayload.studentPhone(context, "student", phone) }.isFailure)
        assertEquals("", HomeroomWritePayload.studentPhone(context, "student", " ").args.getString("studentPhone"))
        val guardian = HomeroomWritePayload.guardian(context, "student", "guardian", "mother", "  Nguyễn  Thị  A ", "+84 (123)", true, " ghi chú ")
        assertEquals("Nguyễn Thị A", guardian.args.getString("fullName"))
        assertEquals("Name A", HomeroomWritePayload.guardian(context, "student", null, "other", "\uFEFFName\u00A0\u2003A\uFEFF", "", false, "").args.getString("fullName"))
        assertEquals("123\u00A0456", HomeroomWritePayload.phone("\uFEFF123\u00A0456\uFEFF"))
        assertEquals("guardian", guardian.args.getString("guardianId"))
        assertEquals("students:updateContacts", HomeroomWritePayload.studentPhone(context, "student", "0123456").path)
        assertEquals(setOf("studentId", "guardianId"), HomeroomWritePayload.remove(context, "student", "guardian").args.keys().asSequence().toSet())
        for ((name, notes, relationship) in listOf(Triple("", "", "mother"), Triple("x".repeat(121), "", "mother"), Triple("Name", "x".repeat(301), "mother"), Triple("Name", "", "invalid"))) assertTrue(runCatching { HomeroomWritePayload.guardian(context, "student", null, relationship, name, "", false, notes) }.isFailure)
    }

    @Test fun `offline fresh supervisor view_all and revoked permissions deny no write`() = runTest {
        for (role in listOf("supervisor", "view_all", "revoked")) {
            val fake = OfflineWriteFixture(context).apply { denied = true }
            val repository = fake.repository()
            assertTrue("$role attendance", runCatching { repository.submit(absence(), { true }) }.isFailure)
            assertTrue("$role contacts", runCatching { repository.submit(HomeroomWritePayload.studentPhone(context, "student", "0123456"), { true }) }.isFailure)
            assertEquals(0, fake.writes.size)
        }
        val revoked = OfflineWriteFixture(context)
        assertTrue(decodeStudentProfile(revoked.profile()).canEditContacts)
        assertTrue(decodeClassDaily(revoked.query("studentAttendance:listDailyClass", JSONObject())).canCorrect)
        revoked.denied = true
        assertTrue(runCatching { revoked.repository().submit(absence(), { true }) }.isFailure)
        assertTrue(runCatching { revoked.repository().submit(HomeroomWritePayload.studentPhone(context, "student", "0123456"), { true }) }.isFailure)
        assertTrue(revoked.writes.isEmpty())
    }

    @Test fun `offline raw wrong context archived and missing targets deny`() = runTest {
        for (mode in listOf("present", "late", "unknown", "archived", "date", "class", "year", "student", "missing")) {
            val fake = OfflineWriteFixture(context).apply { fault = mode }
            assertTrue(mode, runCatching { fake.repository().submit(absence(), { true }) }.isFailure)
            assertEquals(mode, 0, fake.writes.size)
        }
        val fake = OfflineWriteFixture(context)
        assertTrue(runCatching { fake.repository().submit(absence(), { false }) }.isFailure)
        assertTrue(fake.writes.isEmpty())
    }

    @Test fun `offline authoritative contacts decode only showContacts true`() {
        val fake = OfflineWriteFixture(context)
        val visible = decodeStudentProfile(fake.profile())
        assertEquals("0123456", visible.student.studentPhone)
        val redacted = fake.profile().put("showContacts", false)
        redacted.getJSONObject("student").put("studentPhone", JSONObject())
        redacted.put("guardians", JSONArray().put(JSONObject().put("phone", JSONObject())))
        val result = decodeStudentProfile(redacted)
        assertNull(result.student.studentPhone); assertTrue(result.guardians.isEmpty())
        assertTrue(runCatching { decodeStudentProfile(redacted.put("showContacts", true)) }.isFailure)
    }

    @Test fun `offline six guardian edit allowed seventh add denied fresh`() = runTest {
        val fake = OfflineWriteFixture(context).apply { guardianCount = 6 }
        val repo = fake.repository()
        val add = HomeroomWritePayload.guardian(context, "student", null, "guardian", "Name", "", false, "")
        assertTrue(runCatching { repo.submit(add, { true }) }.isFailure)
        assertTrue(fake.writes.isEmpty())
        val edit = HomeroomWritePayload.guardian(context, "student", "g0", "guardian", "Name", "", true, "")
        assertFalse(repo.submit(edit, { true }).refreshFailed)
        assertEquals(1, fake.writes.size)
        fake.guardianCount = 7
        assertTrue(runCatching { repo.submit(edit, { true }) }.isFailure)
        assertEquals(1, fake.writes.size)
    }

    @Test fun `offline exact single batch phone guardian remove acknowledgments and refresh`() = runTest {
        for (write in listOf(absence(), absence(true), HomeroomWritePayload.studentPhone(context, "student", "0123456"), HomeroomWritePayload.guardian(context, "student", null, "mother", "Name", "", false, ""), HomeroomWritePayload.remove(context, "student", "g0"))) {
            val fake = OfflineWriteFixture(context).apply { guardianCount = 1 }
            var cleared = false
            val receipt = fake.repository().submit(write, { true }) { cleared = true }
            assertFalse(receipt.refreshFailed); assertTrue(cleared); assertEquals(1, fake.writes.size)
            assertEquals(write.path, fake.writes.single().first)
            assertEquals(write.args.toString(), fake.writes.single().second.toString())
            assertTrue(fake.reads.contains("homeroomReports:overview")); assertTrue(fake.reads.contains("homeroomReports:pendingAbsences")); assertTrue(fake.reads.contains("studentAttendance:getStudentHistory"))
            if (write.path.endsWith("Many")) assertTrue(receipt.status.contains("1/1"))
        }
    }

    @Test fun `offline postwrite read failure is acknowledged not write failure`() = runTest {
        val fake = OfflineWriteFixture(context).apply { postReadFailure = true }
        val receipt = fake.repository().submit(absence(), { true })
        assertTrue(receipt.refreshFailed); assertTrue(receipt.status.contains("xác nhận")); assertTrue(receipt.status.contains("không gửi lại")); assertEquals(1, fake.writes.size)
    }

    @Test fun `offline malformed acknowledgments never fake success preserve request`() = runTest {
        for (write in listOf(absence(), absence(true), HomeroomWritePayload.studentPhone(context, "student", "0123456"), HomeroomWritePayload.guardian(context, "student", null, "mother", "Name", "", false, ""))) {
            val fake = OfflineWriteFixture(context).apply { malformedAck = true }
            val before = write.args.toString()
            assertTrue(runCatching { fake.repository().submit(write, { true }) }.exceptionOrNull() is WriteUncertain)
            assertEquals(before, write.args.toString()); assertEquals(1, fake.writes.size)
        }
        for (path in listOf("students:updateContacts", "students:removeGuardian")) {
            ConvexHttpClient.validateHomeroomAcknowledgment(path, JSONObject().put("status", "success").put("value", JSONObject.NULL), true)
            for (bad in listOf(JSONObject().put("status", "success"), JSONObject().put("status", "success").put("value", JSONObject()), JSONObject().put("status", "success").put("value", false))) assertTrue(runCatching { ConvexHttpClient.validateHomeroomAcknowledgment(path, bad, true) }.isFailure)
        }
    }

    @Test fun `offline duplicate submission cancellation and late context guard`() = runTest {
        val fake = OfflineWriteFixture(context)
        val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        val repo = HomeroomWriteRepository({ path, args -> fake.query(path, args) }, { path, args -> entered.complete(Unit); release.await(); fake.mutation(path, args) })
        val first = launch { repo.submit(absence(), { true }) }
        entered.await()
        assertTrue(runCatching { repo.submit(absence(), { true }) }.isFailure)
        release.complete(Unit); first.join(); assertEquals(1, fake.writes.size)
        var current = true
        val contextRepo = HomeroomWriteRepository({ path, args -> fake.query(path, args).also { if (path == "studentAttendance:listDailyClass") current = false } }, { path, args -> fake.mutation(path, args) })
        assertTrue(runCatching { contextRepo.submit(absence(), { current }) }.isFailure)
        assertEquals(1, fake.writes.size)
        val started = CompletableDeferred<Unit>()
        val cancelRepo = HomeroomWriteRepository({ path, args -> started.complete(Unit); CompletableDeferred<Unit>().await(); fake.query(path, args) }, { path, args -> fake.mutation(path, args) })
        val cancelled = launch { cancelRepo.submit(absence(), { true }) }; started.await(); cancelled.cancel(); cancelled.join(); assertEquals(1, fake.writes.size)
    }

    @Test fun `offline confirmed validation failure preserves edits but denied clears eligibility`() = runTest {
        val fake = OfflineWriteFixture(context)
        val write = absence()
        val before = write.args.toString()
        val repo = HomeroomWriteRepository(fake::query) { _, _ -> throw ConvexException("INVALID_DISPOSITION_NOTE") }
        assertEquals("INVALID_DISPOSITION_NOTE", (runCatching { repo.submit(write, { true }) }.exceptionOrNull() as ConvexException).code)
        assertEquals(before, write.args.toString())
        assertEquals("INVALID_DISPOSITION_NOTE", ConvexHttpClient.extractCode("Uncaught Error: INVALID_DISPOSITION_NOTE at offline fixture"))
        assertFalse(ConvexHttpClient.humanize("INVALID_PHONE").contains("mật khẩu"))
        val denied = HomeroomWriteRepository(fake::query) { _, _ -> throw ConvexException("CONTACT_EDIT_FORBIDDEN") }
        assertTrue(runCatching { denied.submit(write, { true }) }.exceptionOrNull() is WriteDenied)
        assertTrue(isHomeroomWriteDenied(ConvexException("USER_NOT_ACTIVE")))
        assertFalse(isHomeroomWriteDenied(IllegalStateException("OFFLINE_NETWORK_ERROR")))
    }

    @Test fun `offline hundred unique targets use one atomic batch rpc no per-row writes`() = runTest {
        val fake = OfflineWriteFixture(context).apply { expandedDays = 100 }
        val targets = (1..100).map { target.copy(id = "day$it") }
        val write = HomeroomWritePayload.disposition(targets + targets, "excused", "reason", "", true)
        val receipt = fake.repository().submit(write, { true })
        assertFalse(receipt.refreshFailed)
        assertEquals(1, fake.writes.size)
        assertEquals("studentAttendance:setDispositionMany", fake.writes.single().first)
        assertEquals(100, fake.writes.single().second.getJSONArray("attendanceDayIds").length())
        assertTrue(receipt.status.contains("100/100"))
        write.args.put("attendanceDayIds", JSONArray().put("outside-context"))
        assertTrue(runCatching { fake.repository().submit(write, { true }) }.isFailure)
        assertEquals(1, fake.writes.size)
    }

    @Test fun `offline strict typed acknowledgments reject coercion and wrong counts`() {
        val repo = OfflineWriteFixture(context).repository()
        for (bad in listOf(JSONObject(), JSONObject().put("updated", true), JSONObject().put("updated", "1"), JSONObject().put("updated", 1.5), JSONObject().put("updated", -1), JSONObject().put("updated", 2))) assertTrue(runCatching { repo.validateAck(absence(true), bad) }.isFailure)
        for (bad in listOf(JSONObject().put("attendanceDayId", "other").put("effectiveStatus", "absent_excused").put("unchanged", false), JSONObject().put("attendanceDayId", "day").put("effectiveStatus", "absent_excused").put("unchanged", "false"))) assertTrue(runCatching { repo.validateAck(absence(), bad) }.isFailure)
    }
}

private class OfflineWriteFixture(private val context: DetailContext) {
    var denied = false; var fault = ""; var guardianCount = 0; var malformedAck = false; var postReadFailure = false
    var expandedDays = 0
    val writes = mutableListOf<Pair<String, JSONObject>>()
    val reads = mutableListOf<String>()
    fun repository() = HomeroomWriteRepository(::query, ::mutation)
    fun profile() = JSONObject("""{"student":{"_id":"student","studentCode":"S01","fullName":"Offline fixture student","status":"active","studentPhone":"0123456"},"enrollments":[{"_id":"e","classId":"class","classCode":"6A","className":"Class","startDate":"2026-08-01","status":"active","current":false}],"guardians":[],"showContacts":true,"permissions":{"canManage":false,"canEditContacts":${!denied}}}""").also { result -> result.put("guardians", JSONArray((0 until guardianCount).map { JSONObject().put("_id", "g$it").put("relationship", "mother").put("fullName", "Guardian fixture").put("isPrimaryContact", it == 0) })) }
    suspend fun query(path: String, args: JSONObject): JSONObject {
        reads += path
        if (postReadFailure && writes.isNotEmpty()) error("OFFLINE_READBACK_ERROR")
        return when (path) {
            "homeroomClasses:getScoped" -> JSONObject("""{"class":{"_id":"${if (fault == "class") "wrong" else "class"}","schoolYearId":"${if (fault == "year") "wrong" else "year"}","code":"6A","name":"Offline fixture class","status":"${if (fault == "archived") "archived" else "active"}"},"schoolYear":null,"assignments":[],"currentTeacherName":"","rosterCount":1,"permissions":{"canManage":false,"canImportAttendance":false,"canCorrect":${!denied},"canEditContacts":${!denied}}}""")
            "students:listByClass" -> JSONObject("""{"rows":[],"showContacts":false}""")
            "studentAttendance:listDailyClass" -> JSONObject("""{"date":"${if (fault == "date") "2026-10-06" else context.date}","rows":[{"enrollment":{"_id":"e"},"student":{"_id":"${if (fault == "student") "other" else "student"}","studentCode":"S01","fullName":"Offline fixture"},"day":{"_id":"${if (fault == "missing") "wrong" else "day"}","rawObservation":"${if (fault in listOf("present","late","unknown")) fault else "absent"}","disposition":"pending","effectiveStatus":"absent_pending"}}],"published":true,"archived":false,"canCorrect":${!denied},"schoolDay":{"isSchoolDay":true,"kind":"school_day","outsideYear":false}}""").also { result -> if (expandedDays > 0) { val row = result.getJSONArray("rows").getJSONObject(0); result.put("rows", JSONArray((1..expandedDays).map { number -> JSONObject(row.toString()).also { it.getJSONObject("day").put("_id", "day$number") } })) } }
            "students:getScoped" -> profile()
            "studentAttendance:getStudentHistory" -> JSONObject("""{"days":[],"corrections":[]}""")
            "homeroomReports:pendingAbsences" -> JSONObject("""{"total":0,"truncated":false,"rows":[]}""")
            "homeroomReports:overview" -> JSONObject("""{"date":"${context.date}","today":"${context.date}","mode":"teacher","schoolYear":{"_id":"year","name":"Offline fixture year","startDate":"2026-08-01","endDate":"2027-06-01","active":true},"schoolDay":{"isSchoolDay":true,"kind":"school_day","outsideYear":false},"classes":[],"studentCount":0,"summary":{"counts":{"present":0,"late":0,"absent_excused":0,"absent_unexcused":0,"absent_pending":0,"no_data":0,"exempt":0},"attendanceRate":0,"ratedRows":0,"totalRows":0},"missingUpload":{"shouldAlert":false,"cutoffTime":"08:00","missingClassCodes":[]},"pendingTotal":0}""")
            else -> error("Unexpected offline query $path $args")
        }
    }
    suspend fun mutation(path: String, args: JSONObject): JSONObject {
        writes += path to JSONObject(args.toString())
        if (malformedAck) return JSONObject().put("unexpected", true)
        return when (path) {
            "studentAttendance:setDisposition" -> JSONObject().put("attendanceDayId", args.getString("attendanceDayId")).put("effectiveStatus", "absent_excused").put("unchanged", false)
            "studentAttendance:setDispositionMany" -> JSONObject().put("updated", args.getJSONArray("attendanceDayIds").length())
            "students:upsertGuardian" -> JSONObject().put("value", args.optString("guardianId", "guardian-fixture-id"))
            else -> JSONObject()
        }
    }
}
