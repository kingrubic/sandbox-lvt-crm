package lvt.crm.data.homeroom

import java.nio.file.Files
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class HomeroomPendingJournalTest {
    @Test fun `process death retains identifiers and recovery cannot be cleared or overwritten`() {
        val directory = Files.createTempDirectory("pending-journal").toFile()
        try {
            fun journal(lane: String = "camera", year: String = "year") = HomeroomPendingJournal(directory, lane, year, "2026-10-07")
            val original = journal()
            assertThrows(IllegalStateException::class.java) { original.before("publish", JSONObject()) }
            assertNull(original.restore("owner"))
            original.before("registerUpload", JSONObject())
            original.received(JSONObject().put("uploadId", "upload").put("storageId", "storage"))
            val recovered = journal(year = "other-year")
            val marker = recovered.restore("owner")!!
            assertEquals("year", marker.getString("year"))
            assertEquals("upload", marker.getString("uploadId"))
            assertEquals("storage", marker.getString("storageId"))
            assertNotNull(recovered.restore("owner"))
            assertThrows(IllegalStateException::class.java) { recovered.before("publish", JSONObject()) }
            assertThrows(IllegalStateException::class.java) { recovered.clear() }
            assertThrows(IllegalStateException::class.java) { recovered.received(JSONObject().put("uploadId", "replacement")) }
            assertThrows(IllegalArgumentException::class.java) { recovered.restore("different-owner") }
            assertNull(journal().restore("different-owner"))
            assertNull(journal("management").restore("owner"))
            original.clear()
            assertNull(journal().restore("owner"))
        } finally { directory.deleteRecursively() }
    }

    @Test fun `corrupt marker remains fail closed on repeated restore`() {
        val directory = Files.createTempDirectory("pending-journal").toFile()
        try {
            val original = HomeroomPendingJournal(directory, "camera", "year", "2026-10-07")
            original.restore("owner")
            original.before("publish", JSONObject())
            directory.listFiles()!!.single().writeText("broken-json")
            val recovered = HomeroomPendingJournal(directory, "camera", "year", "2026-10-07")
            assertThrows(Exception::class.java) { recovered.restore("owner") }
            assertThrows(IllegalStateException::class.java) { recovered.restore("owner") }
            assertThrows(IllegalStateException::class.java) { recovered.before("publish", JSONObject()) }
            assertThrows(IllegalStateException::class.java) { recovered.clear() }
        } finally { directory.deleteRecursively() }
    }
}
