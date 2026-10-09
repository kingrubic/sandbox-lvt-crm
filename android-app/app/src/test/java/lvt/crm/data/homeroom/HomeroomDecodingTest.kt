package lvt.crm.data.homeroom

import java.time.Instant
import lvt.crm.data.auth.MenuAccess
import lvt.crm.data.auth.decodeUserSession
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class HomeroomDecodingTest {
    private fun session(access: Any? = null, role: String = "user", status: String = "active", password: Boolean = false) =
        decodeUserSession(JSONObject().put("user", JSONObject().put("_id", "test-user").put("role", role)
            .put("status", status).put("mustChangePassword", password))
            .put("menuAccess", JSONObject().put("homeroom", access)))!!

    @Test fun `menu decoding fails closed and gates inactive password sessions`() {
        for (access in listOf(null, "unknown", true, 1, JSONObject())) assertFalse(session(access).canSeeHomeroom)
        assertEquals(MenuAccess.View, session("edit").homeroomAccess)
        assertTrue(session("view_all").canSeeHomeroom)
        assertFalse(session("view_all").isHomeroomSupervisor)
        assertTrue(session("supervisor").isHomeroomSupervisor)
        assertTrue(session(role = "admin").canSeeHomeroom)
        assertTrue(session(role = "moderator").canSeeHomeroom)
        assertFalse(session(role = "admin", status = "inactive").canSeeHomeroom)
        val missingMenu = JSONObject().put("user", JSONObject().put("_id", "test-user").put("status", "active"))
        assertFalse(decodeUserSession(missingMenu)!!.canSeeHomeroom)
        assertFalse(decodeUserSession(missingMenu.put("menuAccess", JSONArray()))!!.canSeeHomeroom)
        assertFalse(session("view", status = "inactive").canSeeHomeroom)
        assertFalse(session(role = "admin", password = true).canSeeHomeroom)
    }

    @Test fun `Vietnam date midnight and invalid calendar dates`() {
        assertEquals("2026-10-08", vietnamToday(Instant.parse("2026-10-07T17:00:00Z")))
        assertEquals("2026-10-07", vietnamToday(Instant.parse("2026-10-07T16:59:59Z")))
        assertTrue(isVietnamDate("2024-02-29"))
        for (date in listOf("2026-02-29", "2026-02-30", "2026-13-01", "2026-1-01", "bad")) assertFalse(isVietnamDate(date))
    }

    @Test fun `no data remains separate from absence and empty classes are real empty`() {
        val result = decodeOverview(JSONObject("""{"date":"2026-10-07","today":"2026-10-07","mode":"teacher",
            "schoolYear":{"_id":"test-year","name":"2026–2027"},"classes":[],"schoolDay":{},"missingUpload":{},
            "summary":{"counts":{"present":0,"late":0,"absent_excused":0,"absent_unexcused":0,"no_data":3,"absent_pending":2,"exempt":0},"ratedRows":2,"totalRows":5,"attendanceRate":0}}"""))
        assertEquals(3, result.counts.noData)
        assertEquals(2, result.counts.absent)
        assertTrue(result.classes.isEmpty())
        assertEquals(0, decodeSchoolYears(JSONArray()).size)
    }

    @Test fun `pending total and truncation are not replaced by loaded row count`() {
        val rows = JSONArray()
        repeat(500) { index -> rows.put(JSONObject().put("_id", "test-row-$index").put("canCorrect", false)) }
        val result = decodePending(JSONObject().put("total", 501).put("truncated", true).put("rows", rows))
        assertEquals(501, result.total)
        assertTrue(result.truncated)
        assertEquals(500, result.rows.size)
        assertTrue(result.rows.none { it.canCorrect })
        assertEquals(0, decodePending(JSONObject("""{"total":0,"truncated":false,"rows":[]}""")).total)
    }

    @Test fun `malformed responses do not masquerade as empty successful data`() {
        assertTrue(runCatching { decodeOverview(JSONObject()) }.isFailure)
        assertTrue(runCatching { decodePending(JSONObject()) }.isFailure)
        assertTrue(runCatching { decodeImportStatus(JSONObject()) }.isFailure)
        assertTrue(runCatching { decodeSchoolYears(null) }.isFailure)
        assertEquals(0, decodeImportStatus(JSONObject("""{"publishedClassCount":0,"uploads":[]}""")).uploads.size)
    }
}
