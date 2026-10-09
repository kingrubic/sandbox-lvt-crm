import Foundation

struct AppChangelogEntry: Equatable {
    let version: String
    let highlights: [String]
}

enum AppChangelog {
    static let entries: [AppChangelogEntry] = [
        AppChangelogEntry(
            version: "1.14.1",
            highlights: [
                "Mục Lớp chủ nhiệm (theo nhóm quyền): tổng quan lớp theo ngày, vắng chờ xử lý, danh sách lớp và hồ sơ học sinh.",
                "Sửa lỗi danh sách lớp trống khi chưa nhập tìm kiếm; lớp chưa có GVCN hiện “Chưa phân công”.",
            ]
        ),
        AppChangelogEntry(
            version: "1.13.0",
            highlights: [
                "Mục Trao đổi: mọi cuộc trò chuyện Công tác, Công việc và nhóm, theo hoạt động mới nhất.",
                "Tạo nhóm, thêm hoặc xóa thành viên, đổi tên, rời nhóm và giải tán nhóm.",
                "Chuông thông báo trao đổi mở đúng cuộc trò chuyện. Số chưa đọc hiện trên mục Trao đổi.",
            ]
        ),
        AppChangelogEntry(
            version: "1.11.0",
            highlights: [
                "Trao đổi trên công tác và công việc: gửi in đậm, in nghiêng, gạch chân và thu hồi trong 15 phút.",
                "Chuông thông báo trao đổi mở đúng cuộc hội thoại.",
            ]
        ),
        AppChangelogEntry(
            version: "1.10.0",
            highlights: [
                "Sau khi chọn ảnh đại diện, cắt khung 1:1 rồi lưu WebP (nhẹ hơn JPEG).",
            ]
        ),
        AppChangelogEntry(
            version: "1.9.0",
            highlights: [
                "Thông báo và Cá nhân chuyển lên góc phải (chuông + ảnh đại diện); thanh dưới còn Tổng quan, Lịch CT và Công việc.",
                "Đổi ảnh đại diện ngay trên Cá nhân; ảnh hiện ở góc phải và đồng bộ với web.",
            ]
        ),
        AppChangelogEntry(
            version: "1.8.4",
            highlights: [
                "Hết treo màn hình tải khi mở app lần đầu; nếu máy chủ không trả lời thì hiện đăng nhập để thử lại.",
            ]
        ),
        AppChangelogEntry(
            version: "1.8.3",
            highlights: [
                "Bắt buộc cập nhật khi App Store có bản mới hơn (giống Android).",
            ]
        ),
        AppChangelogEntry(
            version: "1.8.2",
            highlights: [
                "Chuyển kết nối backend sang Convex Cloud (ổn định hơn bản self-hosted).",
                "Giữ webURL production https://lvt.vscgroup.io.vn.",
            ]
        ),
        AppChangelogEntry(
            version: "1.8.1",
            highlights: ["Màn Lịch CT hiện đủ hai nút lịch cá nhân và lịch chung."]
        ),
        AppChangelogEntry(
            version: "1.8.0",
            highlights: ["Tab Lịch CT: chọn lịch cá nhân hoặc xem PDF lịch công tác chung giống trên máy tính."]
        ),
        AppChangelogEntry(
            version: "1.7.0",
            highlights: ["Chi tiết công tác hiện Thành phần khác."]
        ),
        AppChangelogEntry(
            version: "1.6.1",
            highlights: [
                "Nộp được bằng chứng hoàn thành sau khi chọn ảnh hoặc tệp.",
                "Hết treo màn hình trắng khi mở lại app sau một thời gian.",
            ]
        ),
        AppChangelogEntry(
            version: "1.6.0",
            highlights: ["Khi đính kèm file công việc hoặc nộp bằng chứng, chọn Loại văn bản (Kế hoạch, Biên bản, Báo cáo)."]
        ),
        AppChangelogEntry(
            version: "1.5.3",
            highlights: ["Xem trước tệp đính kèm trong ứng dụng, tải xuống khi cần, và mở lại nhanh trong 24 giờ."]
        ),
        AppChangelogEntry(
            version: "1.5.2",
            highlights: ["Chi tiết nhiệm vụ Công việc hiện tệp đính kèm và cho phép mở tệp."]
        ),
        AppChangelogEntry(
            version: "1.5.1",
            highlights: ["Danh sách Công việc hiện tên công việc, không lấy tên file hay chữ Công văn."]
        ),
        AppChangelogEntry(
            version: "1.5.0",
            highlights: ["Tạo công việc ngay trên ứng dụng, giống trên web."]
        ),
        AppChangelogEntry(
            version: "1.4.0",
            highlights: ["Thêm mục Lịch sử thay đổi trong tab Cá nhân."]
        ),
        AppChangelogEntry(
            version: "1.3.0",
            highlights: ["Công việc: tab Việc cần làm, Đang chờ duyệt, Quá hạn và Đã duyệt hoàn thành."]
        ),
        AppChangelogEntry(
            version: "1.2.0",
            highlights: ["Công việc thêm tab Chưa đến hạn và Đã quá hạn."]
        ),
        AppChangelogEntry(
            version: "1.1.2",
            highlights: ["Hiện số việc chưa xong trên các tab Công việc."]
        ),
        AppChangelogEntry(
            version: "1.1.1",
            highlights: ["Danh sách Công việc chia theo trạng thái hoàn thành."]
        ),
        AppChangelogEntry(
            version: "1.1.0",
            highlights: ["Có thể gửi ghi chú khi nộp hoàn thành công việc."]
        ),
        AppChangelogEntry(
            version: "1.0",
            highlights: ["Bản đầu trên App Store: đăng nhập, công tác, công việc và thông báo."]
        ),
    ]

    static func visibleEntries(currentVersion: String) -> [AppChangelogEntry] {
        entries.filter { compareVersions($0.version, currentVersion) <= 0 }
    }
}

func compareVersions(_ left: String, _ right: String) -> Int {
    let leftParts = versionParts(left)
    let rightParts = versionParts(right)
    let size = max(leftParts.count, rightParts.count)
    for index in 0..<size {
        let leftValue = index < leftParts.count ? leftParts[index] : 0
        let rightValue = index < rightParts.count ? rightParts[index] : 0
        if leftValue != rightValue { return leftValue < rightValue ? -1 : 1 }
    }
    return 0
}

private func versionParts(_ version: String) -> [Int] {
    version.split(separator: ".").map { Int($0) ?? 0 }
}
