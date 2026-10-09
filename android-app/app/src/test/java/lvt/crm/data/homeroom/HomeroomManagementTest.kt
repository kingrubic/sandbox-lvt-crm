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

class HomeroomManagementTest {
    private val bytes = byteArrayOf(80,75,3,4,1)
    private fun classInput() = JSONObject().put("code", "6a1").put("name", "Offline class").put("gradeLevel", 6).put("notes", "fixture")
    private fun studentInput() = JSONObject().put("studentCode", "HS01").put("fullName", "Offline student").put("startDate", "2026-10-07")

    @Test fun `supervisor view_all assigned teacher hidden cannot catalog roster contacts or disposition`() = runTest {
        for (access in listOf("supervisor", "view_all", "view", "hidden")) {
            val fixture = Fixture(); fixture.role = "user"; fixture.access = access
            val store = fixture.store()
            store.refresh(); store.mutate("createClass", null, classInput()); store.importFile("fixture.xlsx", bytes, "create")
            assertTrue(store.state.value.denied); assertTrue(store.state.value.classes.isEmpty()); assertTrue(store.state.value.roster.isEmpty()); assertNull(store.state.value.validation)
            assertTrue(fixture.writes.isEmpty()); assertEquals(0, fixture.binaries)
            assertFalse(fixture.queries.contains("homeroomClasses:listCatalog")); assertFalse(fixture.queries.contains("students:getScoped"))
        }
        for (operation in listOf("students:updateContacts", "studentAttendance:setDisposition", "editStudent", "unknown")) {
            val fixture = Fixture(); fixture.store().mutate(operation, "class", JSONObject()); assertTrue(fixture.writes.isEmpty())
        }
    }
    @Test fun `active manager password and owner checked fail closed`() = runTest {
        for (fault in listOf("inactive", "password", "missingStatus", "wrongPasswordType")) {
            val fixture = Fixture(); fixture.sessionFault = fault
            fixture.store().mutate("createClass", null, classInput()); assertTrue(fixture.writes.isEmpty())
        }
        val fixture = Fixture(); val store = fixture.store(); store.refresh(); fixture.owner = "other"
        store.mutate("createClass", null, classInput()); assertTrue(store.state.value.denied); assertTrue(fixture.writes.isEmpty())
    }
    @Test fun `all eight exact catalog enrollment endpoint payloads refreshed after ack`() = runTest {
        val paths = mapOf("createClass" to "homeroomClasses:create", "updateClass" to "homeroomClasses:update", "archive" to "homeroomClasses:archive", "restore" to "homeroomClasses:restore", "assign" to "homeroomClasses:assignUser", "createStudent" to "students:create", "transfer" to "homeroomClasses:transferStudent", "withdraw" to "homeroomClasses:withdrawStudent")
        for ((operation, path) in paths) {
            val fixture = Fixture(); fixture.archived = operation == "restore"; val store = fixture.store(); store.select("class")
            val values = when (operation) {
                "createClass", "updateClass" -> classInput()
                "assign" -> JSONObject().put("userId", "teacher").put("effectiveFrom", "2026-10-07")
                "createStudent" -> studentInput()
                "transfer" -> JSONObject().put("enrollmentId", "enrollment").put("toClassId", "target").put("date", "2026-10-07").put("reason", "fixture")
                "withdraw" -> JSONObject().put("enrollmentId", "enrollment").put("date", "2026-10-07").put("reason", "fixture")
                else -> JSONObject()
            }
            store.mutate(operation, if (operation == "createClass") null else "class", values, "student")
            assertEquals(operation, 1, fixture.writes.size); assertEquals(path, fixture.writes.single().second); assertEquals("mutation", fixture.writes.single().first); assertEquals(1, store.state.value.acknowledgmentCount)
            val keys = when (operation) {
                "createClass" -> setOf("schoolYearId", "code", "name", "gradeLevel", "notes")
                "updateClass" -> setOf("id", "code", "name", "gradeLevel", "notes")
                "assign" -> setOf("classId", "userId", "assignmentType", "scopeKind", "effectiveFrom")
                "createStudent" -> setOf("classId", "studentCode", "fullName", "startDate")
                "transfer" -> setOf("enrollmentId", "toClassId", "date", "reason")
                "withdraw" -> setOf("enrollmentId", "date", "reason")
                else -> setOf("id")
            }
            assertEquals(keys, fixture.writes.single().third.keys().asSequence().toSet())
            assertTrue(fixture.queries.count { it == "users:sessionContext" } >= 3)
            if (operation == "assign") { assertEquals("homeroom_teacher", fixture.writes.single().third.getString("assignmentType")); assertEquals("class", fixture.writes.single().third.getString("scopeKind")) }
            if (operation in listOf("transfer", "withdraw")) assertEquals(2, fixture.queries.count { it == "students:getScoped" })
        }
    }
    @Test fun `archived class misuse rejected and restore admitted`() = runTest {
        for (operation in listOf("updateClass", "archive", "assign", "createStudent", "transfer", "withdraw")) {
            val fixture = Fixture(); fixture.archived = true
            fixture.store().mutate(operation, "class", classInput()); assertTrue(fixture.writes.isEmpty())
        }
        val fixture = Fixture(); fixture.archived = true; fixture.store().mutate("restore", "class", JSONObject()); assertEquals("homeroomClasses:restore", fixture.writes.single().second)
    }
    @Test fun `invalid effective dates withdrawal boundary transfer before start and same class rejected`() = runTest {
        val invalid = listOf("assign" to JSONObject().put("userId", "teacher").put("effectiveFrom", "2026-02-30"), "createStudent" to studentInput().put("startDate", "2026-02-30"), "withdraw" to JSONObject().put("enrollmentId", "enrollment").put("date", "2026-08-01"), "transfer" to JSONObject().put("enrollmentId", "enrollment").put("date", "2026-07-31").put("toClassId", "target"), "transfer" to JSONObject().put("enrollmentId", "enrollment").put("date", "2026-10-07").put("toClassId", "class"), "createClass" to classInput().put("code", "invalid code"))
        for ((operation, args) in invalid) { val fixture = Fixture(); val store = fixture.store(); store.mutate(operation, "class", args, "student"); assertTrue(fixture.writes.isEmpty()); assertFalse(store.state.value.locked) }
        for (fault in listOf("ended", "wrongStudent", "wrongEnrollment")) { val fixture = Fixture(); fixture.enrollmentFault = fault; fixture.store().mutate("withdraw", "class", JSONObject().put("enrollmentId", "enrollment").put("date", "2026-10-07"), "student"); assertTrue(fixture.writes.isEmpty()) }
    }
    @Test fun `transfer overlap and assignment conflict propagated definite no auto retry`() = runTest {
        for (code in listOf("DUPLICATE_ACTIVE_ENROLLMENT", "HOMEROOM_TEACHER_OVERLAP", "CLASS_CODE_TAKEN", "STUDENT_CODE_EXISTS")) {
            val fixture = Fixture(); fixture.failStage = "homeroomClasses:transferStudent"; fixture.failCode = code; val store = fixture.store()
            store.mutate("transfer", "class", JSONObject().put("enrollmentId", "enrollment").put("date", "2026-10-07").put("toClassId", "target"), "student")
            assertEquals(1, fixture.writes.size); assertFalse(store.state.value.locked); assertTrue(store.state.value.message.contains(code))
        }
    }
    @Test fun `wrong catalog acknowledgment locks repeat writes`() = runTest {
        val fixture = Fixture(); fixture.badAck = true; val store = fixture.store()
        store.mutate("createClass", null, classInput()); store.mutate("createClass", null, classInput())
        assertTrue(store.state.value.locked); assertEquals(1, fixture.writes.size)
    }
    @Test fun `acknowledged write preserved across failed server refresh`() = runTest {
        val fixture = Fixture(); fixture.failReadAfterAck = true; val store = fixture.store()
        store.mutate("createClass", null, classInput()); assertEquals(1, store.state.value.acknowledgmentCount); assertTrue(store.state.value.message.contains("đã xác nhận")); assertEquals(1, fixture.writes.size)
    }
    @Test fun `roster create merge exact endpoints fresh admission for every stage authoritative commit`() = runTest {
        for (mode in listOf("create", "merge")) {
            val fixture = Fixture(); val store = fixture.store(); store.select("class"); store.importFile("fixture.xlsx", bytes, mode)
            assertTrue(store.state.value.canCommit); assertEquals("upload", store.state.value.uploadId); assertEquals("storage", store.state.value.storageId)
            assertEquals(listOf("studentRosterImport:generateUploadUrl", "studentRosterImport:registerUpload", "studentRosterImport:validateUpload"), fixture.writes.map { it.second })
            assertEquals(setOf("classId"), fixture.writes[0].third.keys().asSequence().toSet())
            assertEquals(setOf("storageId", "fileName", "fileSize", "schoolYearId", "classId", "mode"), fixture.writes[1].third.keys().asSequence().toSet()); assertEquals(mode, fixture.writes[1].third.getString("mode")); assertEquals("action", fixture.writes[2].first)
            assertEquals(6, fixture.queries.count { it == "users:sessionContext" })
            store.commit(false); assertEquals(3, fixture.writes.size)
            store.commit(true); store.commit(true); assertEquals(4, fixture.writes.size); assertTrue(store.state.value.committed); assertNull(store.state.value.validation); assertEquals("committed", store.state.value.uploadStatus)
            assertEquals(setOf("uploadId"), fixture.writes.last().third.keys().asSequence().toSet())
            store.discardKnown(); assertEquals(listOf("upload", "storage"), store.retiredIds); assertTrue(store.state.value.canPick)
        }
    }
    @Test fun `invalid empty oversize non ZIP unsupported files and mode produce no uploads`() = runTest {
        val invalid = listOf("fixture.xlsx" to byteArrayOf(), "fixture.xlsx" to byteArrayOf(1,2,3,4), "fixture.xlsx" to ByteArray(2 * 1024 * 1024 + 1), "fixture.xls" to bytes)
        for ((name, file) in invalid) { val fixture = Fixture(); val store = fixture.store(); store.select("class"); store.importFile(name, file, "create"); assertTrue(fixture.writes.isEmpty()); assertEquals(0, fixture.binaries) }
        val fixture = Fixture(); val store = fixture.store(); store.select("class"); store.importFile("fixture.xlsx", bytes, "supplement"); assertTrue(fixture.writes.isEmpty())
    }
    @Test fun `unknown result at all five stages locks no reset retry or write on refresh`() = runTest {
        for (stage in listOf("studentRosterImport:generateUploadUrl", "binary", "studentRosterImport:registerUpload", "studentRosterImport:validateUpload", "studentRosterImport:commit")) {
            val fixture = Fixture(); fixture.failStage = stage; val store = fixture.store(); store.select("class"); store.importFile("fixture.xlsx", bytes, "create"); store.commit(true)
            val count = fixture.writes.size
            store.importFile("fixture.xlsx", bytes, "create"); store.commit(true); store.discardKnown(); assertTrue(stage, store.state.value.locked); assertEquals(count, fixture.writes.size)
            store.refresh("class"); assertTrue(store.state.value.locked); assertEquals(count, fixture.writes.size)
        }
    }
    @Test fun `genuine parse and row errors shown without treating known rejection as uncertain`() = runTest {
        for (fault in listOf("parse", "rows")) {
            val fixture = Fixture(); fixture.importFault = fault; val store = fixture.store(); store.select("class"); store.importFile("fixture.xlsx", bytes, "create")
            assertFalse(store.state.value.canCommit); assertFalse(store.state.value.locked); assertEquals(1, store.state.value.validation?.getJSONArray("issues")?.length()); store.commit(true); assertEquals(3, fixture.writes.size)
        }
    }
    @Test fun `wrong result envelope owner class year expired status cannot commit`() = runTest {
        for (fault in listOf("wrongEnvelope", "wrongOwner", "wrongClass", "wrongYear", "expired", "committing")) {
            val fixture = Fixture(); fixture.importFault = fault; val store = fixture.store(); store.select("class"); store.importFile("fixture.xlsx", bytes, "create"); store.commit(true)
            assertFalse(store.state.value.canCommit); assertFalse(fixture.writes.any { it.second == "studentRosterImport:commit" })
        }
    }
    @Test fun `permission revoked after URL generation prevents binary upload`() = runTest {
        val fixture = Fixture(); fixture.revokeAfterWrite = true; val store = fixture.store(); store.select("class"); store.importFile("fixture.xlsx", bytes, "create")
        assertTrue(store.state.value.denied); assertEquals(1, fixture.writes.size); assertEquals(0, fixture.binaries)
    }
    @Test fun `duplicate taps suppressed and stale completion discarded`() = runTest {
        val fixture = Fixture(); fixture.suspended = true; val store = fixture.store()
        val task = launch { store.mutate("createClass", null, classInput()) }
        fixture.entered.await(); store.mutate("createClass", null, classInput()); assertEquals(1, fixture.writes.size); assertTrue(store.state.value.busy)
        fixture.current = false; fixture.release.complete(JSONObject().put("value", "id")); task.join()
        assertTrue(store.state.value.locked); assertTrue(store.state.value.classes.isEmpty()); assertEquals(0, store.state.value.acknowledgmentCount)
    }
    @Test fun `cancelled sent write remains uncertain`() = runTest {
        val fixture = Fixture(); fixture.suspended = true; val store = fixture.store()
        val task = launch { store.mutate("createClass", null, classInput()) }
        fixture.entered.await(); task.cancel(); task.join()
        assertTrue(store.state.value.locked); assertEquals(0, store.state.value.acknowledgmentCount); store.mutate("createClass", null, classInput()); assertEquals(1, fixture.writes.size)
    }
    @Test fun `string null and roster object HTTP envelopes reject missing wrong and non2xx`() {
        for (path in listOf("homeroomClasses:create", "homeroomClasses:assignUser", "homeroomClasses:transferStudent", "students:create", "studentRosterImport:generateUploadUrl")) {
            ConvexHttpClient.validateImportEnvelope(path, JSONObject().put("status", "success").put("value", "id"), true)
            assertTrue(runCatching { ConvexHttpClient.validateImportEnvelope(path, JSONObject().put("status", "success").put("value", JSONObject()), true) }.isFailure)
        }
        for (path in listOf("homeroomClasses:update", "homeroomClasses:archive", "homeroomClasses:restore", "homeroomClasses:withdrawStudent")) {
            ConvexHttpClient.validateImportEnvelope(path, JSONObject().put("status", "success").put("value", JSONObject.NULL), true)
            for (envelope in listOf(JSONObject().put("status", "success"), JSONObject().put("status", "success").put("value", JSONObject()))) assertTrue(runCatching { ConvexHttpClient.validateImportEnvelope(path, envelope, true) }.isFailure)
        }
        for (path in listOf("studentRosterImport:registerUpload", "studentRosterImport:validateUpload", "studentRosterImport:commit")) {
            for (value in listOf(JSONObject.NULL, "id", true, 1, JSONArray())) assertTrue(runCatching { ConvexHttpClient.validateImportEnvelope(path, JSONObject().put("status", "success").put("value", value), true) }.isFailure)
            assertTrue(runCatching { ConvexHttpClient.validateImportEnvelope(path, JSONObject().put("status", "success").put("value", JSONObject()), false) }.isFailure)
        }
    }
    @Test fun `lifecycle and mapping honest one hour no public idempotency guarantee`() {
        assertEquals(16, HomeroomManagementStore.columns.split(',').size); assertTrue(HomeroomManagementStore.lifecycle.contains("1 giờ")); assertTrue(HomeroomManagementStore.lifecycle.contains("KHÔNG")); assertTrue(HomeroomManagementStore.lifecycle.contains("không bảo đảm"))
        assertTrue(HomeroomManagementStore.validDate("2028-02-29")); assertFalse(HomeroomManagementStore.validDate("2026-02-29")); assertFalse(HomeroomManagementStore.validDate("2026-2-1"))
    }
    @Test fun `actual picker bounded read empty errors oversize and cancellation without side effects`() = runTest {
        assertEquals(2 * 1024 * 1024 + 1, RosterImportFile.read(java.io.ByteArrayInputStream(ByteArray(2 * 1024 * 1024 + 20))).size)
        assertEquals(0, RosterImportFile.read(java.io.ByteArrayInputStream(byteArrayOf())).size)
        assertTrue(runCatching { RosterImportFile.read(object : java.io.InputStream() { override fun read(): Int = throw java.io.IOException("offline provider failure") }) }.isFailure)
        assertTrue(runCatching { RosterImportFile.read(object : java.io.InputStream() { override fun read(): Int = 0; override fun read(buffer: ByteArray, offset: Int, length: Int): Int = 0 }) }.isFailure)
        val fixture = Fixture(); val store = fixture.store(); store.select("class")
        assertNull(store.state.value.uploadId); assertTrue(store.state.value.canPick); assertTrue(fixture.writes.isEmpty())
    }
    @Test fun `zero commit acknowledged public alreadyCommitted not promised and failed readback retained`() = runTest {
        for (fault in listOf("zero", "already", "commitReadFailure")) {
            val fixture = Fixture(); fixture.importFault = fault; val store = fixture.store(); store.select("class"); store.importFile("fixture.xlsx", bytes, "create"); store.commit(true)
            if (fault == "already") { assertTrue(store.state.value.locked); assertFalse(store.state.value.committed) }
            else { assertTrue(store.state.value.committed); assertEquals(1, store.state.value.acknowledgmentCount) }
            val count = fixture.writes.size; store.commit(true); assertEquals(count, fixture.writes.size)
        }
    }
    @Test fun `wrapped L5 backend errors safe exact codes`() {
        for (code in listOf("CLASS_CODE_TAKEN", "DUPLICATE_ACTIVE_ENROLLMENT", "IMPORT_VALIDATION_FAILED", "IMPORT_UPLOAD_ALREADY_COMMITTED", "ENROLLMENT_YEAR_MISMATCH")) assertEquals(code, ConvexHttpClient.extractImportCode("Uncaught Error: $code at handler"))
    }
    @Test fun `fresh role revocation before each roster write boundary clears sensitive data`() = runTest {
        for (boundary in 2..8) {
            val fixture = Fixture(); fixture.revokeAtSession = boundary; val store = fixture.store(); store.select("class"); store.importFile("fixture.xlsx", bytes, "create"); store.commit(true)
            assertTrue(store.state.value.denied); assertEquals(listOf(0, 1, 1, 2, 3, 3, 3)[boundary - 2], fixture.writes.size)
            assertTrue(store.state.value.roster.isEmpty()); assertNull(store.state.value.validation); assertTrue(store.state.value.history.isEmpty())
        }
    }
    @Test fun `read-only enrollment history fetched from actual scoped contract`() = runTest {
        val fixture = Fixture(); val store = fixture.store(); store.showHistory("student")
        assertEquals(1, store.state.value.history.size); assertTrue(store.state.value.history.single().contains("2026-08-01")); assertTrue(fixture.writes.isEmpty())
    }

    @Test fun `recovered roster identifiers stay locked through refresh mutation and discard`() = runTest {
        val directory = java.nio.file.Files.createTempDirectory("roster-recovery").toFile()
        try {
            val original = HomeroomPendingJournal(directory, "management", "year", "2026-10-07")
            original.restore("owner"); original.before("commit", JSONObject().put("classId", "class").put("uploadId", "upload").put("storageId", "storage"))
            val fixture = Fixture()
            val store = fixture.store(HomeroomPendingJournal(directory, "management", "year", "2026-10-07"))
            store.refresh(); store.refresh(); store.mutate("createClass", null, classInput()); store.discardKnown(); store.commit(true)
            assertTrue(store.state.value.locked); assertEquals("upload", store.state.value.uploadId); assertEquals("storage", store.state.value.storageId)
            assertTrue(fixture.writes.isEmpty()); assertEquals(0, fixture.binaries)
        } finally { directory.deleteRecursively() }
    }

    @Test fun `actual roster writes persist returned identifiers and confirmed commit clears marker`() = runTest {
        val directory = java.nio.file.Files.createTempDirectory("roster-receipts").toFile()
        try {
            val fixture = Fixture()
            val store = fixture.store(HomeroomPendingJournal(directory, "management", "year", "2026-10-07"))
            store.select("class"); store.importFile("fixture.xlsx", bytes, "create")
            val recovered = fixture.store(HomeroomPendingJournal(directory, "management", "year", "2026-10-07"))
            recovered.refresh()
            assertTrue(recovered.state.value.locked)
            assertEquals("upload", recovered.state.value.uploadId); assertEquals("storage", recovered.state.value.storageId)
            store.commit(true)
            assertTrue(directory.listFiles()!!.isEmpty())
            assertNull(HomeroomPendingJournal(directory, "management", "year", "2026-10-07").restore("owner"))
        } finally { directory.deleteRecursively() }
    }

    private class Fixture {
        var role = "admin"; var access = "hidden"; var owner = "owner"; var sessionFault = ""; var enrollmentFault = ""
        var failStage = ""; var failCode = "L5_UNCERTAIN"; var importFault = ""
        var archived = false; var current = true; var badAck = false; var failReadAfterAck = false; var suspended = false; var revokeAfterWrite = false
        var binaries = 0; var committed = false
        var revokeAtSession = Int.MAX_VALUE
        val writes = mutableListOf<Triple<String, String, JSONObject>>(); val queries = mutableListOf<String>()
        val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<JSONObject>()
        fun store(journal: HomeroomPendingJournal? = null) = HomeroomManagementStore("year", "2026-10-07", ::query, ::write, { _, _ -> binaries++; if (failStage == "binary") throw ConvexException(failCode); "storage" }, { current }, journal)
        private fun klass(id: String, archived: Boolean) = JSONObject().put("_id", id).put("schoolYearId", "year").put("code", "6A1").put("name", "Offline class").put("status", if (archived) "archived" else "active").put("gradeLevel", 6).put("rosterCount", 1)
        suspend fun query(path: String, args: JSONObject): JSONObject {
            queries.add(path)
            if (failReadAfterAck && writes.isNotEmpty()) throw ConvexException("OFFLINE_READ_FAILURE")
            return when (path) {
                "users:sessionContext" -> {
                    val user = JSONObject().put("_id", owner).put("status", "active").put("mustChangePassword", false).put("role", if (revokeAfterWrite && writes.isNotEmpty() || queries.count { it == "users:sessionContext" } >= revokeAtSession) "user" else role)
                    when (sessionFault) { "inactive" -> user.put("status", "inactive"); "password" -> user.put("mustChangePassword", true); "missingStatus" -> user.remove("status"); "wrongPasswordType" -> user.put("mustChangePassword", "false") }
                    JSONObject().put("user", user).put("menuAccess", JSONObject().put("homeroom", access))
                }
                "schoolYears:list" -> JSONObject().put("items", JSONArray().put(JSONObject().put("_id", "year").put("name", "2026–2027").put("startDate", "2026-08-01").put("endDate", "2027-06-01").put("active", true)))
                "homeroomClasses:listCatalog" -> JSONObject().put("items", JSONArray().put(klass("class", archived)).put(klass("target", false)))
                "homeroomClasses:listAssignmentCandidates" -> JSONObject().put("items", JSONArray().put(JSONObject().put("_id", "teacher").put("name", "Offline teacher").put("role", "user")))
                "students:listByClass" -> JSONObject().put("showContacts", false).put("rows", JSONArray().put(JSONObject().put("enrollment", JSONObject().put("_id", "enrollment").put("startDate", "2026-08-01")).put("student", JSONObject().put("_id", if (enrollmentFault == "wrongStudent") "other" else "student").put("studentCode", "HS01").put("fullName", "Offline student"))))
                "students:getScoped" -> JSONObject().put("student", JSONObject().put("_id", "student")).put("enrollments", JSONArray().put(JSONObject().put("_id", if (enrollmentFault == "wrongEnrollment") "other" else "enrollment").put("classId", "class").put("status", "active").put("startDate", "2026-08-01").put("endDate", if (enrollmentFault == "ended") "2026-09-01" else JSONObject.NULL)))
                "studentRosterImport:getResult" -> JSONObject().put("upload", JSONObject().put("_id", "upload").put("uploadedBy", if (importFault == "wrongOwner") "other" else owner).put("classId", if (importFault == "wrongClass") "target" else "class").put("schoolYearId", if (importFault == "wrongYear") "other" else "year").put("expiresAt", System.currentTimeMillis() + if (importFault == "expired") -1 else 3600000).put("status", if (committed) "committed" else if (importFault in listOf("parse", "rows")) "rejected" else if (importFault == "committing") "committing" else "validated")).put("rows", JSONArray())
                else -> throw ConvexException("UNEXPECTED_OFFLINE_QUERY")
            }
        }
        suspend fun write(kind: String, path: String, args: JSONObject): JSONObject {
            writes.add(Triple(kind, path, JSONObject(args.toString())))
            if (failStage == path) throw ConvexException(failCode)
            if (suspended) { entered.complete(Unit); return release.await() }
            if (badAck) return JSONObject().put("ok", true)
            return when (path) {
                "studentRosterImport:generateUploadUrl" -> JSONObject().put("value", "https://offline.invalid/upload")
                "studentRosterImport:registerUpload" -> JSONObject().put("uploadId", "upload").put("expiresAt", System.currentTimeMillis() + if (importFault == "expired") -1 else 3600000)
                "studentRosterImport:validateUpload" -> {
                    if (importFault == "wrongEnvelope") return JSONObject().put("ok", true).put("classes", JSONArray())
                    val issue = JSONObject().put("rowNumber", 0).put("field", "file").put("column", "").put("code", "INVALID_IMPORT_FILE").put("message", "Offline rejected file").put("severity", "error")
                    val rejected = importFault in listOf("parse", "rows")
                    val preview = JSONObject().put("ok", !rejected).put("issues", if (rejected) JSONArray().put(issue) else JSONArray()).put("blockers", if (rejected) JSONArray().put(issue) else JSONArray()).put("preview", if (rejected) JSONArray() else JSONArray().put(JSONObject().put("rowNumber", 2).put("studentCode", "HS01").put("fullName", "Offline student")))
                    if (importFault != "parse") preview.put("mode", writes.first { it.second == "studentRosterImport:registerUpload" }.third.getString("mode")).put("columns", JSONArray(HomeroomManagementStore.columns.split(',').map { it.trim() }))
                    preview
                }
                "studentRosterImport:commit" -> {
                    if (importFault == "already") return JSONObject().put("uploadId", "upload").put("alreadyCommitted", true)
                    committed = true; if (importFault == "commitReadFailure") failReadAfterAck = true
                    JSONObject().put("uploadId", "upload").put("committed", true).put("count", if (importFault == "zero") 0 else 1)
                }
                "homeroomClasses:create", "homeroomClasses:assignUser", "homeroomClasses:transferStudent", "students:create" -> JSONObject().put("value", "fixture-id")
                else -> JSONObject()
            }
        }
    }
}
