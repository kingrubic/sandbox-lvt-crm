import Foundation
import CryptoKit
import Darwin

final class HomeroomPendingJournal {
    private let directory: URL
    private let lane, year, date, session: String
    private var owner: String?
    private var checked = false
    private var recovered = false
    private var marker: [String: Any]?
    static let recovery = "Có thao tác lưu bền chưa được đối chiếu sau khi mở lại. KHÔNG gửi lại hoặc nhập bản sao. Chỉ tải trạng thái bằng ID đã biết; không có ID thì cần quản trị viên đối chiếu. Hết hạn/không có trong danh sách không chứng minh chưa ghi hay đã xóa."

    init(directory: URL, lane: String, year: String, date: String, session: String = UUID().uuidString) {
        self.directory = directory; self.lane = lane; self.year = year; self.date = date; self.session = session
    }
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("homeroom-pending", isDirectory: true)
    }
    private func file(_ user: String) -> URL {
        let digest = SHA256.hash(data: Data(user.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(lane)-\(digest).json")
    }
    func restore(_ user: String) throws -> [String: Any]? {
        guard owner == nil || owner == user else { throw ConvexException(code: "PENDING_RECOVERY_REQUIRED") }
        owner = user
        if checked {
            guard !recovered || marker != nil else { throw ConvexException(code: "PENDING_RECOVERY_REQUIRED") }
            return recovered ? marker : nil
        }
        checked = true
        let target = file(user)
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        recovered = true
        guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: target)) as? [String: Any], value["version"] as? Int == 1, value["owner"] as? String == user, value["lane"] as? String == lane else { throw ConvexException(code: "PENDING_RECOVERY_REQUIRED") }
        marker = value
        return value
    }
    func before(_ operation: String, _ args: [String: Any]) throws {
        guard checked, let owner, !recovered else { throw ConvexException(code: "PENDING_RECOVERY_REQUIRED") }
        var value = marker ?? ["version": 1, "owner": owner, "lane": lane, "session": session, "operationId": UUID().uuidString, "year": year, "date": date]
        value["operation"] = operation
        for key in ["classId", "uploadId", "storageId"] { if let identifier = args[key] as? String { value[key] = identifier } }
        try save(value)
    }
    func received(_ value: [String: Any]) throws {
        guard !recovered else { throw ConvexException(code: "PENDING_RECOVERY_REQUIRED") }
        guard var current = marker else { return }
        for key in ["uploadId", "storageId"] { if let identifier = value[key] as? String, !identifier.isEmpty, identifier.count <= 256 { current[key] = identifier } }
        try save(current)
    }
    func clear() throws {
        guard !recovered else { throw ConvexException(code: "PENDING_RECOVERY_REQUIRED") }
        if let owner, FileManager.default.fileExists(atPath: file(owner).path) { try FileManager.default.removeItem(at: file(owner)) }
        marker = nil
    }
    private func save(_ value: [String: Any]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var folder = directory
        var resources = URLResourceValues(); resources.isExcludedFromBackup = true
        try folder.setResourceValues(resources)
        let target = file(owner!)
        try JSONSerialization.data(withJSONObject: value).write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let handle = try FileHandle(forWritingTo: target); try handle.synchronize(); try handle.close()
        let descriptor = Darwin.open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw ConvexException(code: "PENDING_STORAGE_FAILED") }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw ConvexException(code: "PENDING_STORAGE_FAILED") }
        marker = value
    }
}
