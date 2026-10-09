package lvt.crm.data.homeroom

import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.nio.channels.FileChannel
import java.security.MessageDigest
import java.util.UUID
import org.json.JSONObject

class HomeroomPendingJournal(private val directory: File, private val lane: String, private val year: String, private val date: String, private val session: String = UUID.randomUUID().toString()) {
    private var owner: String? = null
    private var checked = false
    private var recovered = false
    private var marker: JSONObject? = null
    private fun file(user: String): File {
        val digest = MessageDigest.getInstance("SHA-256").digest(user.toByteArray()).joinToString("") { "%02x".format(it) }
        return File(directory, "$lane-$digest.json")
    }
    @Synchronized fun restore(user: String): JSONObject? {
        require(owner == null || owner == user)
        owner = user
        if (checked) {
            check(!recovered || marker != null) { "PENDING_RECOVERY_REQUIRED" }
            return if (recovered) JSONObject(requireNotNull(marker).toString()) else null
        }
        checked = true
        val target = file(user)
        if (!target.exists()) return null
        recovered = true
        val value = JSONObject(target.readText())
        require(value.getInt("version") == 1 && value.getString("owner") == user && value.getString("lane") == lane)
        marker = value
        return JSONObject(value.toString())
    }
    @Synchronized fun before(operation: String, args: JSONObject) {
        check(checked && owner != null && !recovered) { "PENDING_RECOVERY_REQUIRED" }
        val value = marker ?: JSONObject().put("version", 1).put("owner", owner).put("lane", lane).put("session", session).put("operationId", UUID.randomUUID().toString()).put("year", year).put("date", date)
        value.put("operation", operation)
        for (key in listOf("classId", "uploadId", "storageId")) if (args.opt(key) is String) value.put(key, args.getString(key))
        save(value)
    }
    @Synchronized fun received(value: JSONObject) {
        check(!recovered) { "PENDING_RECOVERY_REQUIRED" }
        val current = marker ?: return
        for (key in listOf("uploadId", "storageId")) if (value.opt(key) is String && value.getString(key).length in 1..256) current.put(key, value.getString(key))
        save(current)
    }
    @Synchronized fun clear() {
        check(!recovered) { "PENDING_RECOVERY_REQUIRED" }
        owner?.let { if (file(it).exists()) check(file(it).delete()) }
        marker = null
    }
    private fun save(value: JSONObject) {
        check(directory.isDirectory || directory.mkdirs())
        val target = file(requireNotNull(owner))
        val staging = File(directory, target.name + ".writing")
        FileOutputStream(staging).use { it.write(value.toString().toByteArray()); it.fd.sync() }
        Files.move(staging.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
        FileChannel.open(directory.toPath(), StandardOpenOption.READ).use { it.force(true) }
        marker = value
    }
    companion object {
        const val recovery = "Có thao tác lưu bền chưa được đối chiếu sau khi mở lại. KHÔNG gửi lại hoặc nhập bản sao. Chỉ tải trạng thái bằng ID đã biết; không có ID thì cần quản trị viên đối chiếu. Hết hạn/không có trong danh sách không chứng minh chưa ghi hay đã xóa."
    }
}
