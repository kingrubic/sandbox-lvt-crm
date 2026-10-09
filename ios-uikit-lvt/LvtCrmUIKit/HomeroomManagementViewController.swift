import UIKit
import UniformTypeIdentifiers

@MainActor
final class HomeroomManagementViewController: UITableViewController, UIDocumentPickerDelegate {
    private let store: HomeroomManagementStore
    private var actions: [(String, String, (() -> Void)?)] = []
    private var task: Task<Void, Never>?
    private var reading = false
    private var importMode = "create"
    init(store: HomeroomManagementStore) { self.store = store; super.init(style: .insetGrouped); title = "Danh mục / Học sinh" }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Đóng", style: .plain, target: self, action: #selector(close))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Tải lại", style: .plain, target: self, action: #selector(refresh))
        store.changed = { [weak self] in self?.render() }
        refresh()
    }
    @objc private func close() {
        guard !store.busy, !reading else { return }
        confirm("Rời màn hình?", HomeroomManagementStore.lifecycle) { [weak self] in self?.dismiss(animated: true) }
    }
    @objc private func refresh() { task = Task { await store.refresh(classId: store.selectedClassId) } }
    private func confirm(_ title: String, _ message: String, _ action: @escaping () -> Void) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Hủy", style: .cancel))
        alert.addAction(UIAlertAction(title: "Xác nhận", style: .default) { _ in action() })
        present(alert, animated: true)
    }
    private func render() {
        navigationController?.isModalInPresentation = store.busy || reading || store.uploadId != nil || store.storageId != nil || store.locked
        let enabled = !store.busy && !store.locked && !reading
        actions = [("Năm học · \(store.yearName) / \(store.date) (Việt Nam)", store.message, nil), ("Giới hạn và vòng đời", HomeroomManagementStore.lifecycle, nil)]
        if store.busy || reading { actions.append(("Đang xử lý — không gửi lại", "", nil)) }
        if store.denied { tableView.reloadData(); return }
        actions.append(("Tạo lớp", "Khối 6–9", enabled ? { [weak self] in self?.classForm(nil) } : nil))
        if store.classes.isEmpty && !store.busy { actions.append(("Chưa có lớp trong danh mục", "Tạo lớp hoặc tải lại từ máy chủ.", nil)) }
        for klass in store.classes {
            let teacher = klass.currentHomeroomTeacher.map { "\($0.user.name) · từ \($0.effectiveFrom) đến \($0.effectiveTo ?? "không thời hạn")" } ?? "Chưa phân công"
            let upcoming = klass.upcomingHomeroomTeacher.map { "\nSắp tới: \($0.user.name) từ \($0.effectiveFrom)" } ?? ""
            actions.append(("\(klass.code) · \(klass.name) · \(klass.status)", "\(klass.rosterCount) học sinh\n\(teacher)\(upcoming)", enabled ? { [weak self] in self?.classActions(klass) } : nil))
        }
        if let klass = store.classes.first(where: { $0._id == store.selectedClassId }) {
            actions.append(("Danh sách \(klass.code)", "Ngày \(store.date), lịch sử theo thời điểm; thao tác chỉ trên quá trình học đang mở.", nil))
            if klass.status == "active" {
                actions.append(("Thêm học sinh", "", enabled ? { [weak self] in self?.studentForm(klass) } : nil))
                actions.append(("Nhập danh sách Excel", "2 MiB / 200 dòng · tạo mới hoặc hợp nhất", enabled && store.canPick ? { [weak self] in self?.pickMode() } : nil))
            }
            for row in store.roster?.rows ?? [] {
                actions.append(("\(row.student.studentCode) · \(row.student.fullName)", "Nhập học \(row.enrollment.startDate)", enabled && klass.status == "active" ? { [weak self] in self?.enrollmentActions(row, klass) } : nil))
            }
        }
        if let id = store.uploadId { actions.append(("Bản đăng ký \(id)", "\(store.uploadStatus ?? "chưa rõ") · hết hạn \(store.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000).description } ?? "chưa rõ")", nil)) }
        for row in store.history { actions.append(("Lịch sử quá trình học (máy chủ)", row, nil)) }
        if let preview = store.validation {
            actions.append(("Kiểm tra: \(preview.ok ? "hợp lệ" : "bị từ chối")", "\(preview.preview.count) dòng · \(preview.blockers.count) lỗi chặn", nil))
            for issue in preview.issues { actions.append(("Dòng \(issue.rowNumber) · \(issue.column) · \(issue.severity)", "\(issue.code) · \(issue.message)", nil)) }
            for row in preview.preview { actions.append(("Dòng \(row.rowNumber) · \(row.studentCode) · \(row.fullName)", row.details, nil)) }
        }
        if store.canCommit { actions.append(("Cam kết danh sách", "Máy chủ kiểm tra lại; không cam kết lại khi kết quả chưa rõ.", { [weak self] in self?.confirm("Cam kết danh sách?", "Hợp nhất có thể cập nhật hồ sơ. Không chuyển lớp. Ngày nhập học là ngày cam kết theo giờ Việt Nam.") { [weak self] in guard let self else { return }; self.task = Task { await self.store.commit(confirmed: true) } } })) }
        if store.canDiscard { actions.append(("Chọn bản mới / bỏ bản đã biết tại máy", "Không xóa dữ liệu máy chủ; giữ ID trong phiên.", { [weak self] in self?.confirm("Bỏ bản tại máy?", "Không xóa file trên máy chủ; không lặp lại cam kết trước.") { [weak self] in self?.store.discardKnown() } })) }
        actions.append(("Cột Excel bắt buộc (đủ 16 cột)", HomeroomManagementStore.columns + "\nNgày sinh: DD/MM/YYYY hoặc YYYY-MM-DD; giữ mã và điện thoại dạng văn bản.", nil))
        tableView.reloadData()
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { actions.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = actions[indexPath.row]; let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = row.0; cell.detailTextLabel?.text = row.1
        cell.textLabel?.numberOfLines = 0; cell.detailTextLabel?.numberOfLines = 0
        cell.textLabel?.font = .preferredFont(forTextStyle: .body); cell.detailTextLabel?.font = .preferredFont(forTextStyle: .caption1)
        cell.textLabel?.adjustsFontForContentSizeCategory = true; cell.detailTextLabel?.adjustsFontForContentSizeCategory = true
        cell.accessoryType = row.2 == nil ? .none : .disclosureIndicator; cell.selectionStyle = row.2 == nil ? .none : .default
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) { tableView.deselectRow(at: indexPath, animated: true); actions[indexPath.row].2?() }
    private func menu(_ title: String, options: [(String, () -> Void)]) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        for option in options { alert.addAction(UIAlertAction(title: option.0, style: .default) { _ in option.1() }) }
        alert.addAction(UIAlertAction(title: "Hủy", style: .cancel)); present(alert, animated: true)
    }
    private func classActions(_ klass: CatalogClass) {
        var options: [(String, () -> Void)] = [("Danh sách học sinh", { [weak self] in guard let self else { return }; self.task = Task { await self.store.select(klass._id) } })]
        if klass.status == "active" {
            options.append(("Sửa lớp", { [weak self] in self?.classForm(klass) }))
            options.append(("Phân công GVCN", { [weak self] in self?.assignmentForm(klass) }))
        }
        options.append((klass.status == "active" ? "Lưu trữ" : "Khôi phục", { [weak self] in self?.confirm("\(klass.code): \(klass.status == "active" ? "lưu trữ" : "khôi phục")?", "Lưu trữ đóng phân công hiện tại/sắp tới theo ngày Việt Nam của máy chủ; khôi phục không khôi phục phân công cũ.") { [weak self] in guard let self else { return }; self.task = Task { await self.store.mutate(klass.status == "active" ? "archive" : "restore", classId: klass._id, values: [:]) } } }))
        menu(klass.code, options: options)
    }
    private func form(_ title: String, fields: [(String, String, String)], dates: [String] = [], submit: @escaping ([String: Any]) async -> Void) {
        let controller = HomeroomManagementForm(title: title, fields: fields, dates: dates, store: store, submit: submit)
        navigationController?.pushViewController(controller, animated: true)
    }
    private func classForm(_ klass: CatalogClass?) {
        form(klass == nil ? "Tạo lớp" : "Sửa lớp", fields: [("code", "Mã lớp", klass?.code ?? ""), ("name", "Tên lớp", klass?.name ?? ""), ("gradeLevel", "Khối 6–9", klass.map { String($0.gradeLevel) } ?? "6"), ("notes", "Ghi chú", klass?.notes ?? "")]) { [weak self] values in
            guard let self else { return }; var args = values; args["gradeLevel"] = Int(values["gradeLevel"] as? String ?? "") ?? 0
            await self.store.mutate(klass == nil ? "createClass" : "updateClass", classId: klass?._id, values: args)
        }
    }
    private func assignmentForm(_ klass: CatalogClass) {
        menu("Chọn GVCN (người dùng đang hoạt động)", options: store.candidates.map { candidate in
            (candidate.name, { [weak self] in self?.form("Phân công \(candidate.name)", fields: [("effectiveFrom", "Hiệu lực từ (Việt Nam)", self?.store.date ?? "")], dates: ["effectiveFrom"]) { [weak self] values in var args = values; args["userId"] = candidate._id; await self?.store.mutate("assign", classId: klass._id, values: args) } })
        })
    }
    private func studentForm(_ klass: CatalogClass) {
        form("Thêm học sinh \(klass.code)", fields: [("studentCode", "Mã học sinh", ""), ("fullName", "Họ tên", ""), ("startDate", "Ngày nhập học", store.date), ("dateOfBirth", "Ngày sinh (tùy chọn)", ""), ("gender", "Giới tính (tùy chọn)", ""), ("studentPhone", "Điện thoại (tùy chọn)", ""), ("rosterNumber", "STT (tùy chọn)", "")], dates: ["startDate"]) { [weak self] values in
            var args = values
            for key in ["dateOfBirth", "gender", "studentPhone", "rosterNumber"] where values[key] as? String == "" { args.removeValue(forKey: key) }
            if let number = args["rosterNumber"] as? String { args["rosterNumber"] = Int(number) ?? 0 }
            await self?.store.mutate("createStudent", classId: klass._id, values: args)
        }
    }
    private func enrollmentActions(_ row: RosterRow, _ klass: CatalogClass) {
        menu(row.student.fullName, options: [("Lịch sử quá trình học", { [weak self] in guard let self else { return }; self.task = Task { await self.store.showHistory(studentId: row.student._id) } }), ("Chuyển lớp", { [weak self] in guard let self else { return }; self.menu("Lớp đích cùng năm học", options: self.store.classes.filter { $0.status == "active" && $0._id != klass._id }.map { target in (target.code, { [weak self] in self?.enrollmentForm(row, klass, target: target) }) }) }), ("Nghỉ học", { [weak self] in self?.enrollmentForm(row, klass, target: nil) })])
    }
    private func enrollmentForm(_ row: RosterRow, _ klass: CatalogClass, target: CatalogClass?) {
        form(target.map { "Chuyển sang \($0.code)" } ?? "Nghỉ học", fields: [("date", "Hiệu lực từ (cũ kết thúc ngày trước)", store.date), ("reason", "Lý do ≤300 ký tự", "")], dates: ["date"]) { [weak self] values in
            var args = values; args["enrollmentId"] = row.enrollment._id; if let target { args["toClassId"] = target._id }
            await self?.store.mutate(target == nil ? "withdraw" : "transfer", classId: klass._id, values: args, studentId: row.student._id)
        }
    }
    private func pickMode() {
        menu("Chế độ nhập Excel", options: ["create", "merge"].map { mode in (mode == "create" ? "Tạo mới" : "Hợp nhất (cập nhật hồ sơ)", { [weak self] in guard let self else { return }; self.importMode = mode; let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType(filenameExtension: "xlsx") ?? .data], asCopy: false); picker.delegate = self; self.present(picker, animated: true) }) })
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first, store.canPick, !reading else { return }; reading = true; render()
        let mode = importMode
        task = Task {
            do {
                let bytes = try await Task.detached { try CameraImportFile.read(url: url, maxBytes: 2 * 1024 * 1024) }.value
                await store.importFile(name: url.lastPathComponent, bytes: bytes, mode: mode)
            } catch { confirm("Không đọc được file", "Không có yêu cầu tải lên được gửi. Chọn lại file .xlsx có thể đọc.") {} }
            reading = false; render()
        }
    }
}

@MainActor
private final class HomeroomManagementForm: UIViewController {
    private let fields: [(String, String, String)]
    private let dates: [String]
    private let store: HomeroomManagementStore
    private let submit: ([String: Any]) async -> Void
    private var inputs: [String: UITextField] = [:]
    private var pickers: [String: UIDatePicker] = [:]
    private let save = UIButton(type: .system)
    private let status = UILabel()
    init(title: String, fields: [(String, String, String)], dates: [String], store: HomeroomManagementStore, submit: @escaping ([String: Any]) async -> Void) {
        self.fields = fields; self.dates = dates; self.store = store; self.submit = submit; super.init(nibName: nil, bundle: nil); self.title = title
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemBackground
        let scroll = UIScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(scroll)
        let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(stack)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor), scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor), stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -16), stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16), stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -16), stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -32)])
        for field in fields {
            let label = UILabel(); label.text = field.1; label.numberOfLines = 0; label.font = .preferredFont(forTextStyle: .body); label.adjustsFontForContentSizeCategory = true; stack.addArrangedSubview(label)
            if dates.contains(field.0) {
                let picker = UIDatePicker(); picker.datePickerMode = .date; picker.preferredDatePickerStyle = .compact; picker.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh"); picker.calendar = Calendar(identifier: .gregorian); picker.locale = Locale(identifier: "vi_VN"); picker.date = VietnamDate.date(from: field.2) ?? Date(); pickers[field.0] = picker; stack.addArrangedSubview(picker)
            } else {
                let input = UITextField(); input.text = field.2; input.borderStyle = .roundedRect; input.accessibilityLabel = field.1; input.font = .preferredFont(forTextStyle: .body); input.adjustsFontForContentSizeCategory = true; input.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true; inputs[field.0] = input; stack.addArrangedSubview(input)
            }
        }
        status.numberOfLines = 0; status.text = "Máy chủ kiểm tra quyền và xung đột. Hiệu lực theo ngày Việt Nam; giữ lịch sử cũ."; stack.addArrangedSubview(status)
        save.setTitle("Kiểm tra và xác nhận", for: .normal); save.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true; save.addTarget(self, action: #selector(send), for: .touchUpInside); stack.addArrangedSubview(save)
    }
    @objc private func send() {
        guard !store.busy && !store.locked else { status.text = store.message; return }
        var values: [String: Any] = inputs.mapValues { $0.text ?? "" }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")
        for picker in pickers { values[picker.key] = formatter.string(from: picker.value.date) }
        let alert = UIAlertController(title: "Xác nhận \(title ?? "thay đổi")?", message: "Không tự gửi lại nếu kết quả chưa rõ. Chuyển/nghỉ học đóng quá trình cũ ngày trước; phân công thay thế giữ lịch sử cũ.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Hủy", style: .cancel)); alert.addAction(UIAlertAction(title: "Gửi", style: .default) { [weak self] _ in
            guard let self else { return }; self.save.isEnabled = false; self.isModalInPresentation = true
            Task { let count = self.store.acknowledgmentCount; await self.submit(values); self.status.text = self.store.message; self.save.isEnabled = !self.store.locked; self.isModalInPresentation = false; if self.store.denied { self.inputs.values.forEach { $0.text = "" }; self.pickers.values.forEach { $0.isHidden = true } }; if self.store.acknowledgmentCount > count { self.navigationController?.popViewController(animated: true) } }
        }); present(alert, animated: true)
    }
}
