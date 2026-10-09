import UIKit
import UniformTypeIdentifiers

@MainActor
final class HomeroomCameraImportViewController: UIViewController, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
    private let store: CameraImportStore
    private let stack = UIStackView()
    private var task: Task<Void, Never>?
    private var mode: String?
    private var picking = false
    private var reading = false
    init(store: CameraImportStore) { self.store = store; super.init(nibName: nil, bundle: nil); title = "Nhập camera toàn trường" }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Đóng", style: .plain, target: self, action: #selector(close))
        let scroll = UIScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        stack.axis = .vertical; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor), scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16), stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -16), stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -16), stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -32)
        ])
        store.changed = { [weak self] in self?.render() }
        render(); task = Task { await store.refreshStatus() }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true { store.invalidate(); task?.cancel() }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        navigationController?.presentationController?.delegate = self
    }
    func presentationControllerWillDismiss(_ presentationController: UIPresentationController) { store.invalidate(); task?.cancel() }
    @objc private func close() { store.invalidate(); task?.cancel(); dismiss(animated: true) }
    private func text(_ value: String) {
        let label = UILabel(); label.text = value; label.numberOfLines = 0; label.font = .preferredFont(forTextStyle: .body); label.adjustsFontForContentSizeCategory = true
        stack.addArrangedSubview(label)
    }
    private func button(_ title: String, enabled: Bool = true, action: @escaping () -> Void) {
        let button = UIButton(type: .system); button.setTitle(title, for: .normal); button.titleLabel?.numberOfLines = 0; button.titleLabel?.font = .preferredFont(forTextStyle: .body); button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true; button.isEnabled = enabled
        button.addAction(UIAction { _ in action() }, for: .touchUpInside); stack.addArrangedSubview(button)
    }
    private func render() {
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        text("Năm học: \(store.yearId) · Ngày Việt Nam: \(store.date)")
        text("File camera toàn trường: Lớp học, Tên học sinh, Ngày sinh, Trạng thái điểm danh; Thời gian điểm danh nếu có. Nhận diện bằng lớp + họ tên + ngày sinh. Tối đa 3.000 dòng; máy chủ kiểm tra mẫu.")
        text(store.message)
        if store.busy || reading { let spinner = UIActivityIndicatorView(style: .medium); spinner.startAnimating(); stack.addArrangedSubview(spinner) }
        button("Chọn file Excel .xlsx (tối đa 4 MiB)", enabled: !store.busy && !store.locked && store.storageId == nil && store.uploadId == nil && !picking && !reading) { [weak self] in self?.pick() }
        if store.canStartNew { button("Bỏ bản hiện tại ở ứng dụng và chọn file khác (không xóa trên máy chủ)") { [weak self] in self?.mode = nil; self?.store.newFile() } }
        for upload in store.previousUploads { text("Lịch sử cục bộ: \(upload)") }
        if let storage = store.storageId { text("Storage: \(storage)") }; if let id = store.uploadId { text("Bản đăng ký: \(id)") }
        button("Tải lại danh sách đã công bố (không gửi lại)", enabled: !store.busy) { [weak self] in guard let self else { return }; self.task = Task { await self.store.refreshStatus() } }
        if store.uploadId != nil {
            button("Kiểm tra lại bản xem trước (cần xác nhận lại chế độ)", enabled: !store.busy && !store.locked) { [weak self] in guard let self else { return }; self.mode = nil; self.task = Task { await self.store.refreshPreview() } }
        }
        if let status = store.status {
            text("Đã có dữ liệu: \(status.publishedClassCount) lớp. Chỉ liệt kê file đã công bố.")
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "vi_VN"); formatter.timeZone = VietnamDate.timeZone; formatter.dateFormat = "dd/MM/yyyy HH:mm"
            for upload in status.uploads {
                let publishedTime = upload.publishedAt > 0 ? formatter.string(from: Date(timeIntervalSince1970: Double(upload.publishedAt) / 1000)) : "Chưa có thời điểm công bố"
                text("\(upload.fileName) · \(upload.uploadedByName) · \(publishedTime) · \(upload.rowCount) dòng / \(upload.matchedCount) khớp · ID \(upload.id)")
            }
        }
        guard let preview = store.preview else { return }
        text("\(preview.fileName) · Sheet: \(preview.sheetName)\n\(preview.totalRows) dòng, \(preview.matchedCount) khớp; \(preview.errorCount) lỗi, \(preview.warningCount) cảnh báo. ok=\(preview.ok)")
        text("Lịch học: \(preview.schoolDay.kind) · \(preview.schoolDay.note) · Ngày học: \(preview.schoolDay.isSchoolDay) · Ngoài năm: \(preview.schoolDay.outsideYear)")
        text("Lớp lỗi/không có dòng bị bỏ qua. Học sinh trong danh sách lớp có thể công bố nhưng thiếu trong file sẽ thành vắng chờ xử lý. Không sửa phân loại GVCN trên ứng dụng nhập.")
        for row in preview.classes { text("\(row.code) · \(row.name) · \(row.publishable ? "Có thể công bố" : "Bỏ qua") · \(row.alreadyPublished ? "Đã có dữ liệu" : "Chưa có dữ liệu")\nDòng \(row.rowCount) / khớp \(row.matchedCount), sĩ số \(row.rosterCount), thiếu \(row.missingCount); có mặt \(row.present), muộn \(row.late), vắng \(row.absent); lỗi \(row.errorCount), cảnh báo \(row.warningCount)") }
        for row in preview.classesWithoutRows { text("Bỏ qua — không có dòng: \(row.code) · \(row.name) · đã công bố: \(row.alreadyPublished)") }
        if preview.issuesTruncated { text("Danh sách lỗi đã bị máy chủ cắt (tối đa 400); tổng lỗi/cảnh báo vẫn hiển thị.") }
        for issue in preview.issues { text("\(issue.severity) · Dòng \(issue.rowNumber) · \(issue.field) / \(issue.column) · \(issue.rejectedValue ?? "—") · \(issue.code)\n\(issue.message)") }
        if preview.conflicts {
            for (index, label) in ["Bổ sung — giữ quan sát và phân loại đã có", "Thay quan sát camera — giữ phân loại GVCN khi còn hợp lệ", "Bỏ qua lớp đã có dữ liệu — vẫn công bố lớp mới"].enumerated() {
                button("\(mode == CameraImportStore.modes[index] ? "✓ " : "")\(label)", enabled: !store.busy) { [weak self] in self?.mode = CameraImportStore.modes[index]; self?.render() }
            }
        }
        let rows = preview.classes.filter { $0.publishable && (mode != "cancel" || !$0.alreadyPublished) }
        button("Công bố \(rows.count) lớp · thiếu \(rows.reduce(0) { $0 + $1.missingCount }) học sinh", enabled: !store.busy && !store.locked && !rows.isEmpty && (!preview.conflicts || mode != nil)) { [weak self] in self?.confirm() }
    }
    private func pick() {
        picking = true; render()
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType(filenameExtension: "xlsx") ?? .data], asCopy: false)
        picker.allowsMultipleSelection = false; picker.delegate = self; present(picker, animated: true)
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        picking = false; render()
        Task { await store.picked(name: nil, data: nil) }
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        picking = false
        guard let url = urls.first else { render(); return }
        reading = true; render()
        task = Task { [weak self] in
            guard let self else { return }
            defer { reading = false; render() }
            do {
                let data = try await Task.detached { try CameraImportFile.read(url: url) }.value
                await store.picked(name: url.lastPathComponent, data: data)
            } catch {
                let alert = UIAlertController(title: "Không đọc được file", message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Đóng", style: .cancel)); present(alert, animated: true)
            }
            render()
        }
    }
    private func confirm() {
        let selectedMode = mode
        let alert = UIAlertController(title: "Xác nhận công bố", message: "Ngày Việt Nam \(store.date). \(selectedMode ?? "Công bố mới"). Lớp lỗi/không có dòng bị bỏ qua; học sinh thiếu thành vắng chờ xử lý. Thao tác ghi điểm danh; không tự động gửi lại.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Quay lại", style: .cancel))
        alert.addAction(UIAlertAction(title: "Công bố", style: .destructive) { [weak self] _ in guard let self else { return }; self.task = Task { await self.store.publish(mode: selectedMode, confirmed: true) } })
        present(alert, animated: true)
    }
}
