package lvt.crm.data.homeroom

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import lvt.crm.data.convex.ConvexException
import lvt.crm.data.convex.ConvexHttpClient
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.IOException

class HomeroomCameraImportTest {
    @Test fun `actual HTTP envelope requires successful status exact result type`() {
        ConvexHttpClient.validateImportEnvelope("attendanceImport:generateUploadUrl", JSONObject().put("status", "success").put("value", "https://offline.invalid"), true)
        ConvexHttpClient.validateImportEnvelope("attendanceImport:publish", JSONObject().put("status", "success").put("value", JSONObject()), true)
        for (value in listOf(JSONObject.NULL, false, 1, "wrong", JSONArray())) assertTrue(runCatching { ConvexHttpClient.validateImportEnvelope("attendanceImport:publish", JSONObject().put("status", "success").put("value", value), true) }.isFailure)
        assertTrue(runCatching { ConvexHttpClient.validateImportEnvelope("attendanceImport:publish", JSONObject().put("status", "success").put("value", JSONObject()), false) }.isFailure)
    }
    @Test fun `real wrapped backend errors decoded without guessing endpoints`() {
        for (code in listOf("ATTENDANCE_REPLACE_MODE_REQUIRED", "ATTENDANCE_TEMPLATE_COLUMNS_MISSING", "IMPORT_UPLOAD_EXPIRED", "IMPORT_ROWS_UNRESOLVED", "SUPERVISOR_REQUIRED", "SCHOOL_YEAR_NOT_FOUND")) assertEquals(code, ConvexHttpClient.extractImportCode("Uncaught Error: $code:classCode at handler"))
    }
    private val bytes = byteArrayOf(80, 75, 3, 4)
    private fun preview(conflict: Boolean = false): JSONObject = JSONObject("""{
      "uploadId":"upload","attendanceDate":"2026-10-06","fileName":"camera.xlsx","sheetName":"Sheet1","ok":false,
      "totalRows":2,"matchedCount":1,"errorCount":1,"warningCount":1,"issuesTruncated":true,
      "issues":[{"rowNumber":3,"field":"name","column":"Họ tên","rejectedValue":null,"code":"UNMATCHED","message":"Không khớp","severity":"error"}],
      "classes":[{"classId":"class","code":"10A","name":"Lớp 10A","rowCount":1,"matchedCount":1,"present":1,"late":0,"absent":0,"rosterCount":2,"missingCount":1,"errorCount":0,"warningCount":1,"publishable":true,"alreadyPublished":$conflict}],
      "classesWithoutRows":[{"classId":"empty","code":"10B","name":"Lớp 10B","alreadyPublished":false}],
      "schoolDay":{"isSchoolDay":true,"kind":"school_day","note":"","outsideYear":false}}
    """)
    private inner class Fixture(journal: HomeroomPendingJournal? = null) {
        var access = "supervisor"
        var role = "user"
        var actor = "actor"
        var active = true
        var password = false
        var current = true
        var conflict = false
        var fail: String? = null
        var error: Exception = IOException("offline connection lost")
        var malformed: String? = null
        var block: String? = null
        val entered = CompletableDeferred<Unit>()
        val gate = CompletableDeferred<Unit>()
        val calls = mutableListOf<Pair<String, JSONObject>>()
        val writes = mutableListOf<Pair<String, JSONObject>>()
        var statusFails = false
        var ack = JSONObject("""{"importId":"upload","published":true,"count":0,"classCount":0,"skippedClassCodes":[]} """)
        private suspend fun record(path: String, args: JSONObject) {
            calls += path to JSONObject(args.toString())
            if (block == path) { entered.complete(Unit); gate.await() }
            if (fail == path) throw error
        }
        val store = CameraImportStore("year", "2026-10-06", { path, args ->
            record(path, args)
            when (path) {
                "users:sessionContext" -> JSONObject().put("user", JSONObject().put("_id", actor).put("role", role).put("status", if (active) "active" else "disabled").put("mustChangePassword", password)).put("menuAccess", JSONObject().put("homeroom", access))
                "schoolYears:list" -> JSONObject().put("items", JSONArray("""[{"_id":"year","name":"2026","startDate":"2026-08-01","endDate":"2027-06-01","active":true}]"""))
                "attendanceImport:uploadsForDate" -> { if (statusFails) throw IOException("offline status failed"); JSONObject("""{"publishedClassCount":0,"uploads":[]}""") }
                else -> error("Unexpected query $path")
            }
        }, { kind, path, args ->
            assertEquals(if (path.endsWith("validate")) "action" else "mutation", kind)
            writes += path to JSONObject(args.toString()); record(path, args)
            if (malformed == path) JSONObject() else when (path) {
                "attendanceImport:generateUploadUrl" -> JSONObject().put("value", "https://offline.invalid/upload")
                "attendanceImport:registerUpload" -> JSONObject().put("uploadId", "upload")
                "attendanceImport:validate" -> preview(conflict)
                "attendanceImport:publish" -> ack
                else -> error("Unexpected write $path")
            }
        }, { url, payload ->
            assertEquals("https://offline.invalid/upload", url); assertArrayEquals(bytes, payload)
            record("binary", JSONObject()); if (malformed == "binary") "" else "storage"
        }, { current }, journal)
        suspend fun select() = store.select("camera.xlsx", bytes)
    }

    @Test fun `recovered camera stays locked through repeated status refresh and cannot publish or restart`() = runTest {
        val directory = java.nio.file.Files.createTempDirectory("camera-recovery").toFile()
        try {
            val original = HomeroomPendingJournal(directory, "camera", "year", "2026-10-06")
            original.restore("actor"); original.before("publish", JSONObject().put("uploadId", "upload").put("storageId", "storage"))
            val fixture = Fixture(HomeroomPendingJournal(directory, "camera", "year", "2026-10-06"))
            fixture.store.refreshStatus(); fixture.store.refreshStatus()
            fixture.select(); fixture.store.publish(null, true); fixture.store.newFile()
            assertTrue(fixture.store.state.value.locked); assertFalse(fixture.store.canStartNew)
            assertEquals("upload", fixture.store.uploadId); assertEquals("storage", fixture.store.storageId)
            assertTrue(fixture.writes.isEmpty()); assertFalse(fixture.calls.any { it.first == "binary" })
        } finally { directory.deleteRecursively() }
    }

    @Test fun `actual camera writes persist returned identifiers before recreation and clear only after publish receipt`() = runTest {
        val directory = java.nio.file.Files.createTempDirectory("camera-receipts").toFile()
        try {
            val fixture = Fixture(HomeroomPendingJournal(directory, "camera", "year", "2026-10-06"))
            fixture.select()
            val recovered = Fixture(HomeroomPendingJournal(directory, "camera", "year", "2026-10-06"))
            recovered.store.refreshStatus()
            assertTrue(recovered.store.state.value.locked)
            assertEquals("upload", recovered.store.uploadId); assertEquals("storage", recovered.store.storageId)
            assertTrue(recovered.writes.isEmpty())
            fixture.store.publish(null, true)
            assertTrue(directory.listFiles()!!.isEmpty())
            assertNull(HomeroomPendingJournal(directory, "camera", "year", "2026-10-06").restore("actor"))
        } finally { directory.deleteRecursively() }
    }

    @Test fun `file guards bounded read and provider failure`() {
        CameraImportFile.validate("CAMERA.XLSX", bytes)
        for ((name, payload) in listOf("a.xls" to bytes, "a.xlsx" to byteArrayOf(), "a.xlsx" to byteArrayOf(1, 2, 3, 4), "a.xlsx" to ByteArray(CameraImportFile.maxBytes + 1))) assertTrue(runCatching { CameraImportFile.validate(name, payload) }.isFailure)
        assertEquals(CameraImportFile.maxBytes + 1, CameraImportFile.read(ByteArrayInputStream(ByteArray(CameraImportFile.maxBytes + 10))).size)
        assertTrue(runCatching { CameraImportFile.read(object : java.io.InputStream() { override fun read(): Int = throw IOException("provider failure") }) }.isFailure)
    }
    @Test fun `picker cancellation makes no write and malformed file rejected before query`() = runTest {
        val fixture = Fixture()
        fixture.store.picked(null, null)
        assertTrue(fixture.calls.isEmpty())
        fixture.store.select("a.xls", bytes)
        assertTrue(fixture.calls.isEmpty()); assertFalse(fixture.store.state.value.locked)
    }
    @Test fun `exact endpoints args supervisor isolation partial preview and no implicit publish`() = runTest {
        val fixture = Fixture(); fixture.select()
        assertEquals(listOf("attendanceImport:generateUploadUrl", "attendanceImport:registerUpload", "attendanceImport:validate"), fixture.writes.map { it.first })
        val register = fixture.writes[1].second
        assertEquals(setOf("storageId", "fileName", "fileSize", "schoolYearId", "attendanceDate"), register.keys().asSequence().toSet())
        assertEquals("storage", register.getString("storageId")); assertEquals(4, register.getInt("fileSize")); assertEquals("2026-10-06", register.getString("attendanceDate"))
        assertEquals(setOf("uploadId"), fixture.writes[2].second.keys().asSequence().toSet())
        assertEquals(5, fixture.calls.count { it.first == "users:sessionContext" })
        assertNotNull(fixture.store.state.value.preview); assertFalse(fixture.store.state.value.preview!!.value.getBoolean("ok"))
        assertTrue(fixture.calls.none { it.first.startsWith("students:") || it.first.startsWith("homeroomReports:") || it.first.startsWith("studentAttendance:") })
    }
    @Test fun `view all view hidden edit inactive password and actor change deny writes`() = runTest {
        for (access in listOf("view_all", "view", "hidden", "edit", "unknown")) {
            val fixture = Fixture(); fixture.access = access; fixture.select(); assertTrue(fixture.writes.isEmpty()); assertTrue(fixture.store.state.value.locked)
        }
        for (case in 0..1) { val fixture = Fixture(); if (case == 0) fixture.active = false else fixture.password = true; fixture.select(); assertTrue(fixture.writes.isEmpty()) }
        val fixture = Fixture(); fixture.select(); fixture.actor = "different"; fixture.store.publish(null, true); assertNull(fixture.store.state.value.preview); assertEquals(3, fixture.writes.size)
        for (role in listOf("admin", "moderator")) { val manager = Fixture(); manager.role = role; manager.access = "hidden"; manager.select(); assertNotNull(manager.store.state.value.preview) }
    }
    @Test fun `transport failures every stage lock no retry or cleanup`() = runTest {
        for (stage in listOf("attendanceImport:generateUploadUrl", "binary", "attendanceImport:registerUpload", "attendanceImport:validate", "attendanceImport:publish")) {
            val fixture = Fixture()
            if (stage.endsWith("publish")) fixture.select()
            fixture.fail = stage
            if (stage.endsWith("publish")) fixture.store.publish(null, true) else fixture.select()
            assertTrue("$stage lock", fixture.store.state.value.locked)
            val count = fixture.calls.count { it.first == stage }
            fixture.select(); fixture.store.refreshPreview(); fixture.store.publish(null, true)
            assertEquals(1, count); assertEquals(count, fixture.calls.count { it.first == stage })
            assertTrue(fixture.calls.none { it.first.contains("delete", true) || it.first.contains("cleanup", true) })
        }
    }
    @Test fun `malformed successful responses every stage uncertain`() = runTest {
        for (stage in listOf("attendanceImport:generateUploadUrl", "binary", "attendanceImport:registerUpload", "attendanceImport:validate", "attendanceImport:publish")) {
            val fixture = Fixture(); if (stage.endsWith("publish")) fixture.select(); fixture.malformed = stage
            if (stage.endsWith("publish")) fixture.store.publish(null, true) else fixture.select()
            assertTrue(stage, fixture.store.state.value.locked); assertNull(fixture.store.state.value.preview)
        }
    }
    @Test fun `explicit parse expiry and register rejection do not pretend unknown`() = runTest {
        for ((stage, code) in listOf("attendanceImport:registerUpload" to "INVALID_IMPORT_FILE", "attendanceImport:validate" to "ATTENDANCE_TEMPLATE_HEADER_NOT_FOUND", "attendanceImport:validate" to "IMPORT_UPLOAD_EXPIRED", "attendanceImport:validate" to "IMPORT_TOO_MANY_ROWS")) {
            val fixture = Fixture(); fixture.fail = stage; fixture.error = ConvexException(code); fixture.select()
            assertTrue(fixture.store.state.value.message.contains(code)); assertEquals(code == "IMPORT_UPLOAD_EXPIRED", fixture.store.state.value.locked)
        }
    }
    @Test fun `revocation after binary prevents register and clears preview`() = runTest {
        val fixture = Fixture(); fixture.block = "binary"
        val job = launch { fixture.select() }; fixture.entered.await(); fixture.access = "view_all"; fixture.gate.complete(Unit); job.join()
        assertTrue(fixture.store.state.value.locked); assertEquals(1, fixture.writes.size); assertNull(fixture.store.state.value.preview)
    }
    @Test fun `stale validation and duplicate taps cannot submit later stages`() = runTest {
        val fixture = Fixture(); fixture.block = "attendanceImport:validate"
        val job = launch { fixture.select() }; fixture.entered.await(); fixture.select(); fixture.store.invalidate(); fixture.gate.complete(Unit); job.join()
        assertNull(fixture.store.state.value.preview); assertTrue(fixture.store.state.value.locked); assertEquals(3, fixture.writes.size)
    }
    @Test fun `cancel in flight preserves uncertainty and stops followup`() = runTest {
        val fixture = Fixture(); fixture.block = "binary"
        val job = launch { fixture.select() }; fixture.entered.await(); job.cancel(); job.join()
        assertTrue(fixture.store.state.value.locked); assertEquals(1, fixture.writes.size)
    }
    @Test fun `conflicts require explicit valid modes confirmation and correction preserving wire modes`() = runTest {
        for (mode in CameraImportStore.modes) {
            val fixture = Fixture(); fixture.conflict = true; fixture.select()
            fixture.store.publish(null, true); fixture.store.publish("replace", true); fixture.store.publish(mode, false)
            assertEquals(3, fixture.writes.size)
            fixture.store.publish(mode, true)
            assertEquals(mode, fixture.writes.last().second.getString("replaceMode")); assertEquals(setOf("uploadId", "replaceMode"), fixture.writes.last().second.keys().asSequence().toSet())
            assertTrue(fixture.store.state.value.locked)
        }
    }
    @Test fun `concurrent conflict requires explicit preview refresh no auto republish`() = runTest {
        val fixture = Fixture(); fixture.select(); fixture.fail = "attendanceImport:publish"; fixture.error = ConvexException("ATTENDANCE_REPLACE_MODE_REQUIRED")
        fixture.store.publish(null, true); assertNull(fixture.store.state.value.preview); assertFalse(fixture.store.state.value.locked)
        fixture.fail = null; fixture.conflict = true; fixture.store.refreshPreview()
        assertTrue(fixture.store.state.value.preview!!.conflicts); assertEquals(1, fixture.writes.count { it.first.endsWith("publish") })
    }
    @Test fun `zero and idempotent receipts accepted and wrong booleans numbers identity rejected`() {
        assertTrue(CameraImportStore.receipt(JSONObject("""{"importId":"u","published":true,"count":0,"classCount":0,"idempotent":true}"""), "u").contains("0 thay đổi"))
        assertTrue(CameraImportStore.receipt(JSONObject("""{"importId":"u","published":true,"count":0,"classCount":0,"skippedClassCodes":["10A"]}"""), "u").contains("10A"))
        for (field in listOf("importId", "published", "count", "classCount", "skippedClassCodes")) {
            val value = JSONObject("""{"importId":"u","published":true,"count":0,"classCount":0,"skippedClassCodes":[]}""")
            value.put(field, if (field == "count") 0.5 else false)
            assertTrue(field, runCatching { CameraImportStore.receipt(value, "u") }.isFailure)
        }
    }
    @Test fun `publish ack survives failed status refresh and revoked status cannot republish`() = runTest {
        val fixture = Fixture(); fixture.select(); fixture.statusFails = true; fixture.store.publish(null, true)
        assertTrue(fixture.store.state.value.message.startsWith("Đã xác nhận")); assertTrue(fixture.store.state.value.message.contains("Không tải")); assertTrue(fixture.store.state.value.locked)
        fixture.store.publish(null, true); fixture.store.refreshStatus(); assertEquals(1, fixture.writes.count { it.first.endsWith("publish") })
    }
    @Test fun `new file only after known acknowledged publish never after unknown`() = runTest {
        val fixture = Fixture(); fixture.select(); fixture.store.publish(null, true)
        assertTrue(fixture.store.canStartNew); fixture.store.newFile(); assertNull(fixture.store.uploadId); assertNull(fixture.store.storageId); assertFalse(fixture.store.state.value.locked)
        fixture.fail = "binary"; fixture.select(); assertFalse(fixture.store.canStartNew); fixture.store.newFile(); assertTrue(fixture.store.state.value.locked)
    }
    @Test fun `revocation on validate and readonly refresh clears sensitive preview`() = runTest {
        val fixture = Fixture(); fixture.block = "attendanceImport:validate"
        val job = launch { fixture.select() }; fixture.entered.await(); fixture.access = "view_all"; fixture.gate.complete(Unit); job.join()
        assertNull(fixture.store.state.value.preview); assertTrue(fixture.store.state.value.locked)
        val status = Fixture(); status.select(); status.access = "view_all"; status.store.refreshStatus()
        assertNull(status.store.state.value.preview); assertTrue(status.store.state.value.locked)
    }
    @Test fun `known validated rejected or expired draft can be locally abandoned without server cleanup`() = runTest {
        for (code in listOf<String?>(null, "ATTENDANCE_TEMPLATE_COLUMNS_MISSING", "IMPORT_UPLOAD_EXPIRED")) {
            val fixture = Fixture(); if (code != null) { fixture.fail = "attendanceImport:validate"; fixture.error = ConvexException(code) }; fixture.select()
            assertTrue(fixture.store.canStartNew); val before = fixture.calls.size; fixture.store.newFile()
            assertEquals(before, fixture.calls.size); assertFalse(fixture.store.state.value.locked); assertNull(fixture.store.uploadId)
            assertTrue(fixture.store.previousUploads.single().contains("upload")); assertTrue(fixture.store.previousUploads.single().contains("chưa xác nhận công bố"))
        }
    }
    @Test fun `fresh year date checked before any writes`() = runTest {
        for (date in listOf("2026-02-30", "2026-07-31", "2027-10-01", "2027-06-01")) {
            val store = CameraImportStore("year", date, { path, _ -> if (path.startsWith("users")) JSONObject("""{"user":{"_id":"a","role":"admin","status":"active"}}""") else JSONObject("""{"items":[{"_id":"year","startDate":"2026-08-01","endDate":"2027-06-01"}]}""") }, { _, _, _ -> fail("write should be denied"); JSONObject() }, { _, _ -> fail("binary denied"); "" })
            store.select("camera.xlsx", bytes); assertTrue(store.state.value.message.contains("INVALID_IMPORT_CONTEXT"))
        }
    }
    @Test fun `preview malformed collections counts issues severity identity fail closed`() {
        for (field in listOf("classes", "issues", "schoolDay", "classesWithoutRows", "totalRows", "ok", "issuesTruncated")) {
            val value = preview(); value.put(field, "bad")
            assertTrue(field, runCatching { CameraPreview.decode(value, "upload", "2026-10-06") }.isFailure)
        }
        assertTrue(runCatching { CameraPreview.decode(preview(), "other", "2026-10-06") }.isFailure)
        assertTrue(runCatching { CameraPreview.decode(preview(), "upload", "2026-10-05") }.isFailure)
    }
}
