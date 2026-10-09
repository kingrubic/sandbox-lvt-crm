import UIKit

@MainActor final class HomeroomWriteFormViewController: UITableViewController {
    private let repository: HomeroomWriteRepository
    private let context: DetailContext
    private let studentId: String?
    private let targets: [AbsenceTarget]
    private let batch: Bool
    private let guardian: StudentProfile.Guardian?
    private let mode: String
    private let isCurrent: () -> Bool
    private let onClear: () -> Void
    private let onRefresh: () async -> Void
    private let name = UITextField()
    private let phone = UITextField()
    private let notes = UITextField()
    private let reason = UITextField()
    private let primary = UISwitch()
    private var choice: String
    private var fields: [(String, UITextField)] = []
    private var busy = false
    private var locked = false
    private var status = "Quyền được kiểm tra lại trước khi ghi. Không gửi tin nhắn; liên hệ chính do máy chủ quyết định."
    private var task: Task<Void, Never>?

    init(repository: HomeroomWriteRepository, context: DetailContext, studentId: String? = nil, targets: [AbsenceTarget] = [], batch: Bool = false, guardian: StudentProfile.Guardian? = nil, mode: String = "phone", initialPhone: String = "", isCurrent: @escaping () -> Bool, onClear: @escaping () -> Void, onRefresh: @escaping () async -> Void) {
        self.repository = repository; self.context = context; self.studentId = studentId; self.targets = targets; self.batch = batch; self.guardian = guardian; self.mode = mode
        self.isCurrent = isCurrent; self.onClear = onClear; self.onRefresh = onRefresh
        choice = guardian?.relationship ?? (targets.isEmpty ? "guardian" : "excused")
        super.init(style: .insetGrouped)
        name.text = guardian?.fullName ?? ""; phone.text = guardian?.phone ?? initialPhone; notes.text = guardian?.notes ?? ""; primary.isOn = guardian?.isPrimaryContact ?? false
        title = targets.isEmpty ? (mode == "phone" ? "Điện thoại học sinh" : "Người giám hộ") : "Phân loại \(Set(targets.map(\.id)).count) buổi"
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { task?.cancel() }
    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 64
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Đóng", style: .plain, target: self, action: #selector(close))
        fields = !targets.isEmpty ? [("Mã lý do (hoặc ghi chú)", reason), ("Ghi chú (tối đa 500)", notes)] : mode == "phone" ? [("Điện thoại (để trống để xóa)", phone)] : [("Họ tên (1–120)", name), ("Điện thoại (để trống để xóa)", phone), ("Ghi chú (tối đa 300)", notes)]
        for (label, field) in fields {
            field.placeholder = label; field.accessibilityLabel = label; field.font = .preferredFont(forTextStyle: .body); field.adjustsFontForContentSizeCategory = true
            field.borderStyle = .roundedRect; field.clearButtonMode = .whileEditing
        }
        phone.keyboardType = .phonePad
        primary.accessibilityLabel = "Liên hệ chính"
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if navigationController?.presentingViewController == nil { task?.cancel() }
    }
    @objc private func close() { guard !busy else { return }; task?.cancel(); dismiss(animated: true) }
    override func numberOfSections(in tableView: UITableView) -> Int { 3 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? fields.count : section == 1 ? (targets.isEmpty && mode == "phone" ? 0 : (targets.isEmpty ? 2 : 1)) : (guardian == nil ? 2 : 3) }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.textProperties.font = .preferredFont(forTextStyle: .body); content.secondaryTextProperties.font = .preferredFont(forTextStyle: .body)
        content.textProperties.numberOfLines = 0; content.secondaryTextProperties.numberOfLines = 0
        cell.contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        if indexPath.section == 0 {
            let field = fields[indexPath.row].1
            field.isEnabled = !busy && !locked
            cell.contentView.addSubview(field); field.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([field.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor), field.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor), field.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 10), field.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -10), field.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)])
            cell.selectionStyle = .none
        } else if indexPath.section == 1 {
            content.text = indexPath.row == 0 ? "Chọn: \(Self.label(choice))" : "Liên hệ chính"
            cell.accessoryType = indexPath.row == 0 ? .disclosureIndicator : .none
            if indexPath.row == 1 { cell.accessoryView = primary; primary.isEnabled = !busy && !locked }
        } else {
            content.text = indexPath.row == 0 ? status : indexPath.row == 1 ? (locked ? "Chỉ tải lại; không gửi lại" : "Kiểm tra và xác nhận") : "Xóa người giám hộ"
            cell.selectionStyle = indexPath.row == 0 || busy ? .none : .default
        }
        cell.contentConfiguration = content
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !busy else { return }
        view.endEditing(true)
        if indexPath.section == 1 && indexPath.row == 0 && !locked {
            let picker = UIAlertController(title: "Chọn", message: nil, preferredStyle: .actionSheet)
            for value in targets.isEmpty ? HomeroomWritePayload.relationships : ["pending", "excused", "unexcused"] { picker.addAction(UIAlertAction(title: Self.label(value), style: .default) { [weak self] _ in self?.choice = value; self?.tableView.reloadData() }) }
            picker.addAction(UIAlertAction(title: "Hủy", style: .cancel)); picker.popoverPresentationController?.sourceView = tableView.cellForRow(at: indexPath); present(picker, animated: true)
        } else if indexPath.section == 2 && indexPath.row > 0 {
            if locked { task = Task { await onRefresh() }; return }
            do {
                let write: HomeroomWrite
                if indexPath.row == 2, let guardian, let studentId { write = HomeroomWritePayload.remove(context, studentId: studentId, id: guardian._id) }
                else if !targets.isEmpty { write = try HomeroomWritePayload.disposition(targets, next: choice, reason: reason.text ?? "", note: notes.text ?? "", batch: batch) }
                else if mode == "phone", let studentId { write = try HomeroomWritePayload.studentPhone(context, studentId: studentId, value: phone.text ?? "") }
                else if let studentId { write = try HomeroomWritePayload.guardian(context, studentId: studentId, id: guardian?._id, relationship: choice, name: name.text ?? "", phone: phone.text ?? "", primary: primary.isOn, notes: notes.text ?? "") }
                else { return }
                let confirm = UIAlertController(title: "Xác nhận ghi", message: targets.isEmpty ? (write.path == "students:removeGuardian" ? "Xóa người giám hộ này?" : "Lưu liên hệ này?") : "\(write.targets.count) buổi duy nhất được chọn; thao tác lô toàn bộ hoặc không ghi. Đây chưa phải số thay đổi thành công.", preferredStyle: .alert)
                confirm.addAction(UIAlertAction(title: "Quay lại sửa", style: .cancel))
                confirm.addAction(UIAlertAction(title: "Xác nhận", style: write.path == "students:removeGuardian" ? .destructive : .default) { [weak self] _ in self?.submit(write) })
                present(confirm, animated: true)
            } catch { status = error.localizedDescription; tableView.reloadData() }
        }
    }
    private func submit(_ write: HomeroomWrite) {
        guard !busy, !locked else { return }
        busy = true; isModalInPresentation = true; navigationController?.isModalInPresentation = true; navigationController?.interactivePopGestureRecognizer?.isEnabled = false; status = "Đang kiểm tra quyền và gửi…"; tableView.reloadData()
        task = Task { [weak self] in
            guard let self else { return }
            defer { busy = false; isModalInPresentation = false; navigationController?.isModalInPresentation = false; navigationController?.interactivePopGestureRecognizer?.isEnabled = true; tableView.reloadData() }
            do {
                let receipt = try await repository.submit(write, isCurrent: isCurrent) { for (_, field) in self.fields { field.text = "" }; self.locked = true; self.onClear() }
                status = receipt.status; locked = true
                if isCurrent() { await onRefresh() }
            } catch is CancellationError { status = "Thao tác đã dừng. Tải lại để kiểm tra; không tự gửi lại."; locked = true }
            catch {
                status = error.localizedDescription
                let code = (error as? ConvexException)?.code ?? ""
                if HomeroomWritePayload.isDenied(error) {
                    for (_, field) in fields { field.text = "" }; locked = true; onClear(); await onRefresh()
                } else if code == "WRITE_UNCERTAIN" { locked = true; onClear() }
            }
        }
    }
    static func label(_ value: String) -> String { ["father": "Cha", "mother": "Mẹ", "guardian": "Người giám hộ", "grandparent": "Ông/Bà", "sibling": "Anh/Chị/Em", "other": "Khác", "pending": "Chờ xử lý", "excused": "Có phép", "unexcused": "Không phép"][value] ?? value }
}

@MainActor final class HomeroomAbsenceSelectionViewController: UITableViewController {
    private let targets: [AbsenceTarget]
    private let labels: [String]
    private var selected: Set<String> = []
    var onSelect: (([AbsenceTarget], Bool) -> Void)?
    init(targets: [AbsenceTarget], labels: [String]) { self.targets = targets; self.labels = labels; super.init(style: .insetGrouped); title = "Chọn buổi vắng · 0/100" }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad(); tableView.rowHeight = UITableView.automaticDimension; tableView.estimatedRowHeight = 64
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Phân loại lô", style: .plain, target: self, action: #selector(batchSelected))
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Đóng", style: .plain, target: self, action: #selector(close))
    }
    @objc private func close() { dismiss(animated: true) }
    @objc private func batchSelected() { let chosen = targets.filter { selected.contains($0.id) }; if !chosen.isEmpty { onSelect?(chosen, true) } }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { targets.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration(); content.text = labels[indexPath.row]; content.secondaryText = "\(VietnamDate.display(targets[indexPath.row].context.date)) · Chạm để chọn lô; nút thông tin để phân loại một buổi"
        content.textProperties.font = .preferredFont(forTextStyle: .headline); content.secondaryTextProperties.font = .preferredFont(forTextStyle: .body); content.textProperties.numberOfLines = 0; content.secondaryTextProperties.numberOfLines = 0
        cell.contentConfiguration = content; cell.accessoryType = .detailButton; cell.accessibilityValue = selected.contains(targets[indexPath.row].id) ? "Đã chọn" : "Chưa chọn"
        cell.backgroundColor = selected.contains(targets[indexPath.row].id) ? .secondarySystemGroupedBackground : .systemBackground
        cell.contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let id = targets[indexPath.row].id
        if selected.contains(id) { selected.remove(id) } else if selected.count < 100 { selected.insert(id) }
        title = "Chọn buổi vắng · \(selected.count)/100"; tableView.reloadData()
    }
    override func tableView(_ tableView: UITableView, accessoryButtonTappedForRowWith indexPath: IndexPath) { onSelect?([targets[indexPath.row]], false) }
}
