import UIKit

@MainActor final class HomeroomDetailViewController: UITableViewController, UISearchBarDelegate {
    private let repository: HomeroomRepository
    private let store: HomeroomDetailStore
    private let picker = UIDatePicker()
    private let pane = UIButton(type: .system)
    private var dailyPane = false
    private let search = UISearchBar()
    private let historyFrom = UIDatePicker()
    private let historyTo = UIDatePicker()
    private var task: Task<Void, Never>?
    private var rows: [(title: String, detail: String, studentId: String?)] = []
    private lazy var writes = repository.writeOperations
    var onClassDateChanged: ((String) -> Void)?

    init(repository: HomeroomRepository, context: DetailContext, studentId: String? = nil) {
        self.repository = repository
        store = HomeroomDetailStore(operations: repository.detailOperations, context: context)
        store.studentId = studentId
        super.init(style: .insetGrouped)
        title = studentId == nil ? "Lớp" : "Học sinh"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { task?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 100
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(retry), for: .valueChanged)
        navigationItem.rightBarButtonItems = [UIBarButtonItem(title: "Tải lại", style: .plain, target: self, action: #selector(retry)), UIBarButtonItem(title: "Sửa", style: .plain, target: self, action: #selector(edit))]
        picker.datePickerMode = .date
        picker.preferredDatePickerStyle = .compact
        picker.calendar = Calendar(identifier: .gregorian)
        picker.timeZone = VietnamDate.timeZone
        picker.locale = Locale(identifier: "vi_VN")
        picker.date = VietnamDate.date(from: store.context.date) ?? Date()
        picker.accessibilityLabel = "Ngày điểm danh, múi giờ Việt Nam"
        picker.addTarget(self, action: #selector(dateChanged), for: .valueChanged)
        picker.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        pane.setTitle("Xem điểm danh ngày", for: .normal)
        pane.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        pane.titleLabel?.adjustsFontForContentSizeCategory = true
        pane.titleLabel?.numberOfLines = 0
        pane.accessibilityValue = "Đang xem danh sách lớp"
        pane.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        pane.addTarget(self, action: #selector(paneChanged), for: .touchUpInside)
        search.placeholder = "Tìm tên hoặc mã học sinh"
        search.delegate = self
        picker.isHidden = store.studentId != nil
        pane.isHidden = store.studentId != nil
        search.isHidden = store.studentId != nil
        let fromLabel = UILabel()
        fromLabel.text = "Lịch sử từ · Múi giờ Việt Nam"
        let toLabel = UILabel()
        toLabel.text = "Lịch sử đến · Múi giờ Việt Nam"
        for label in [fromLabel, toLabel] {
            label.font = .preferredFont(forTextStyle: .body)
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
            label.isHidden = store.studentId == nil
        }
        for datePicker in [historyFrom, historyTo] {
            datePicker.datePickerMode = .date
            datePicker.preferredDatePickerStyle = .compact
            datePicker.calendar = Calendar(identifier: .gregorian)
            datePicker.timeZone = VietnamDate.timeZone
            datePicker.locale = Locale(identifier: "vi_VN")
            datePicker.isHidden = store.studentId == nil
            datePicker.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            datePicker.addTarget(self, action: #selector(historyChanged), for: .valueChanged)
        }
        historyFrom.date = VietnamDate.date(from: store.context.from) ?? Date()
        historyTo.date = VietnamDate.date(from: store.context.to) ?? Date()
        historyFrom.maximumDate = historyTo.date
        historyTo.minimumDate = historyFrom.date
        historyFrom.accessibilityLabel = "Lịch sử từ, múi giờ Việt Nam"
        historyTo.accessibilityLabel = "Lịch sử đến, múi giờ Việt Nam"
        let controls: [UIView] = store.studentId == nil ? [picker, pane, search] : [fromLabel, historyFrom, toLabel, historyTo]
        let stack = UIStackView(arrangedSubviews: controls)
        stack.axis = .vertical
        stack.spacing = 12
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20)
        tableView.tableHeaderView = stack
        store.onChange = { [weak self] in self?.render() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        retry()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        task?.cancel()
        store.clear()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let header = tableView.tableHeaderView else { return }
        let size = header.systemLayoutSizeFitting(CGSize(width: tableView.bounds.width, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        if header.frame.size != size { header.frame.size = size; tableView.tableHeaderView = header }
    }

    @objc private func retry() {
        task?.cancel()
        store.clear()
        task = Task { [weak self] in await self?.store.load() }
    }
    @objc private func dateChanged() {
        let date = VietnamDate.string(from: picker.date)
        guard date != store.context.date else { return }
        let current = store.context
        store.context = DetailContext(yearId: current.yearId, classId: current.classId, date: date, from: current.from, to: current.to)
        onClassDateChanged?(date)
        retry()
    }
    @objc private func paneChanged() {
        dailyPane.toggle()
        pane.setTitle(dailyPane ? "Xem danh sách lớp" : "Xem điểm danh ngày", for: .normal)
        pane.accessibilityValue = dailyPane ? "Đang xem điểm danh ngày" : "Đang xem danh sách lớp"
        view.setNeedsLayout()
        render()
    }
    @objc private func historyChanged() {
        let current = store.context
        let from = VietnamDate.string(from: historyFrom.date)
        let to = VietnamDate.string(from: historyTo.date)
        guard from <= to else { return }
        historyFrom.maximumDate = historyTo.date
        historyTo.minimumDate = historyFrom.date
        store.context = DetailContext(yearId: current.yearId, classId: current.classId, date: current.date, from: from, to: to)
        retry()
    }
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) { render() }

    private func matches(_ name: String, _ code: String) -> Bool {
        HomeroomDetailDecoder.matchesStudent(name: name, code: code, search: search.text ?? "")
    }

    private func render() {
        rows = []
        if store.loading {
            rows = [("Đang tải…", "Ngày Việt Nam \(VietnamDate.display(store.context.date))", nil)]
        } else if let error = store.error {
            rows = [("Chưa tải được dữ liệu", "\(error)\nDữ liệu cũ đã được xóa. Nhấn Tải lại để thử lại.", nil)]
        } else if let data = store.classData {
            let klass = data.scoped.class
            title = klass.code
            rows.append(("\(klass.code) · \(klass.name)", "Ngày \(VietnamDate.display(store.context.date)) · Sĩ số \(data.scoped.rosterCount)\nGVCN \(data.scoped.currentTeacherName.isEmpty ? "Chưa phân công" : data.scoped.currentTeacherName)\n\(klass.status == "archived" ? "Lớp đã lưu trữ" : "Lớp đang hoạt động")", nil))
            if !dailyPane {
                let visible = data.roster.rows.filter { matches($0.student.fullName, $0.student.studentCode) }
                rows.append(("Danh sách lớp · \(visible.count)/\(data.roster.rows.count)", "Theo ghi danh tại ngày đã chọn; liên hệ chỉ hiển thị trong hồ sơ khi máy chủ cho phép.", nil))
                if visible.isEmpty { rows.append((data.roster.rows.isEmpty ? "Chưa có học sinh" : "Không có kết quả tìm kiếm", "Không suy diễn thành thiếu điểm danh.", nil)) }
                rows += visible.map { ("\($0.enrollment.rosterNumber.map(String.init) ?? "—"). \($0.student.fullName)", "\($0.student.studentCode) · Ghi danh từ \(VietnamDate.display($0.enrollment.startDate))", $0.student._id) }
            } else {
                let daily = data.daily
                rows.append(("Điểm danh \(VietnamDate.display(daily.date))", "\(daily.published ? "Đã có dữ liệu công bố" : "Chưa có dữ liệu công bố")\nQuyền phân loại từ máy chủ: \(daily.canCorrect ? "Có" : "Không") · Nhấn Sửa để chọn buổi vắng.", nil))
                if daily.schoolDay.outsideYear { rows.append(("Ngoài năm học", "Không suy diễn thành vắng.", nil)) }
                else if !daily.schoolDay.isSchoolDay { rows.append(("Không phải ngày học", daily.schoolDay.note ?? "Không cần điểm danh.", nil)) }
                let visible = daily.rows.filter { matches($0.student.fullName, $0.student.studentCode) }
                rows.append(("\(visible.count)/\(daily.rows.count) học sinh", "Trạng thái và quyền do máy chủ trả về.", nil))
                if visible.isEmpty { rows.append(("Không có học sinh trong danh sách", "Thử ngày khác hoặc thay đổi tìm kiếm.", nil)) }
                rows += visible.map { row in
                    let record = row.day
                    let observed = record?.rawObservedAt.map { "\nQuan sát: \(timestamp($0))" } ?? ""
                    return (row.student.fullName, "\(row.student.studentCode) · \(HomeroomDetailDecoder.statusText(record?.effectiveStatus ?? "no_data"))\(observed)\n\(record?.note ?? "")", row.student._id)
                }
            }
        } else if let data = store.studentData {
            let student = data.profile.student
            title = "Học sinh"
            rows.append((student.fullName, "\(student.studentCode) · \(student.status)\nNgày sinh: \(student.dateOfBirth.map(VietnamDate.display) ?? "—") · Giới tính: \(student.gender ?? "—")", nil))
            if data.profile.showContacts {
                rows.append(("Điện thoại học sinh", data.profile.studentPhone ?? "—", nil))
                rows += data.profile.guardians.map { ("\($0.fullName) · \(HomeroomWriteFormViewController.label($0.relationship))", "\($0.phone ?? "—")\($0.isPrimaryContact ? " · Liên hệ chính" : "")\n\($0.notes ?? "")", nil) }
                rows.append(("Liên hệ · \(data.profile.guardians.count)/6", data.profile.permissions.canEditContacts ? "Nhấn Sửa để sửa số điện thoại, thêm, sửa hoặc xóa người giám hộ." : "Máy chủ không cho phép sửa.", nil))
            } else { rows.append(("Liên hệ được máy chủ ẩn", "Không có quyền sửa.", nil)) }
            rows.append(("Ghi danh được phép xem · \(data.profile.enrollments.count)", "Không cấp quyền cho lớp ngoài phạm vi máy chủ.", nil))
            rows += data.profile.enrollments.map { ("\($0.classCode) · \($0.className)", "\(VietnamDate.display($0.startDate)) → \($0.endDate.map(VietnamDate.display) ?? "Đang tiếp tục")\n\($0.current ? "Hiện tại" : "Lịch sử") · \($0.status)\n\($0.transferReason ?? "")", nil) }
            let history = data.history
            rows.append(("Lịch sử · \(history.days.count) buổi · \(history.corrections.count) điều chỉnh", "\(VietnamDate.display(store.context.from)) → \(VietnamDate.display(store.context.to))\nHiển thị toàn bộ các buổi được máy chủ trả về trong khoảng và phạm vi được phép.", nil))
            if history.days.isEmpty { rows.append(("Chưa có lịch sử trong khoảng này", "Không suy diễn thành có mặt hoặc vắng.", nil)) }
            rows += history.days.reversed().map { ("\(VietnamDate.display($0.attendanceDate)) · \(HomeroomDetailDecoder.statusText($0.effectiveStatus))", "Lớp ID \($0.classId)\n\($0.rawObservedAt.map(timestamp) ?? "")\n\($0.reasonCode ?? "") \($0.note ?? "")", nil) }
            rows += history.corrections.sorted { $0.at > $1.at }.map { ("Điều chỉnh \(VietnamDate.display($0.attendanceDate))", "\(HomeroomDetailDecoder.statusText($0.previousEffectiveStatus)) → \(HomeroomDetailDecoder.statusText($0.nextEffectiveStatus))\n\(timestamp($0.at)) · Người sửa ID \($0.actorUserId)\n\($0.reasonCode ?? "") \($0.note ?? "")", nil) }
        }
        if !store.loading { refreshControl?.endRefreshing() }
        tableView.reloadData()
        navigationItem.rightBarButtonItems?.last?.isEnabled = store.studentData.map { $0.profile.showContacts && $0.profile.permissions.canEditContacts } ?? (dailyPane && store.classData?.daily.canCorrect == true && store.classData?.daily.archived == false)
    }

    @objc private func edit() {
        let context = store.context
        if let data = store.studentData, data.profile.showContacts, data.profile.permissions.canEditContacts {
            let chooser = UIAlertController(title: "Liên hệ · \(data.profile.guardians.count)/6", message: "Liên hệ chính do máy chủ quyết định.", preferredStyle: .actionSheet)
            chooser.addAction(UIAlertAction(title: "Sửa điện thoại học sinh", style: .default) { [weak self] _ in self?.showContact(context, profile: data.profile, guardian: nil, mode: "phone") })
            if data.profile.guardians.count < 6 { chooser.addAction(UIAlertAction(title: "Thêm người giám hộ", style: .default) { [weak self] _ in self?.showContact(context, profile: data.profile, guardian: nil, mode: "guardian") }) }
            for guardian in data.profile.guardians { chooser.addAction(UIAlertAction(title: "Sửa hoặc xóa · \(guardian.fullName)", style: .default) { [weak self] _ in self?.showContact(context, profile: data.profile, guardian: guardian, mode: "guardian") }) }
            chooser.addAction(UIAlertAction(title: "Hủy", style: .cancel)); chooser.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItems?.last; present(chooser, animated: true)
        } else if let data = store.classData, dailyPane, data.daily.canCorrect, !data.daily.archived {
            let rows = data.daily.rows.filter { $0.day?.rawObservation == "absent" }
            let targets = rows.compactMap { row in row.day.map { AbsenceTarget(id: $0._id, studentId: row.student._id, context: context) } }
            let selector = HomeroomAbsenceSelectionViewController(targets: targets, labels: rows.map { "\($0.student.fullName) · \($0.student.studentCode)" })
            selector.onSelect = { [weak self, weak selector] chosen, batch in
                guard let self, let selector else { return }
                let form = HomeroomWriteFormViewController(repository: writes, context: context, targets: chosen, batch: batch, isCurrent: { [weak self] in self?.store.context == context && self?.store.studentId == nil && self?.store.error == nil }, onClear: { [weak self] in self?.store.clear() }, onRefresh: { [weak self] in await self?.store.load() })
                selector.navigationController?.pushViewController(form, animated: true)
            }
            present(UINavigationController(rootViewController: selector), animated: true)
        }
    }
    private func showContact(_ context: DetailContext, profile: StudentProfile, guardian: StudentProfile.Guardian?, mode: String) {
        let id = profile.student._id
        let form = HomeroomWriteFormViewController(repository: writes, context: context, studentId: id, guardian: guardian, mode: mode, initialPhone: profile.studentPhone ?? "", isCurrent: { [weak self] in self?.store.context == context && self?.store.studentId == id && self?.store.error == nil }, onClear: { [weak self] in self?.store.clear() }, onRefresh: { [weak self] in await self?.store.load() })
        present(UINavigationController(rootViewController: form), animated: true)
    }

    private func timestamp(_ milliseconds: Double) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = VietnamDate.timeZone
        formatter.locale = Locale(identifier: "vi_VN")
        formatter.dateFormat = "dd/MM/yyyy HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: milliseconds / 1000))
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "detail") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "detail")
        let row = rows[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = row.title
        content.secondaryText = row.detail
        content.textProperties.font = .preferredFont(forTextStyle: .headline)
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .body)
        content.textProperties.numberOfLines = 0
        content.secondaryTextProperties.numberOfLines = 0
        cell.contentConfiguration = content
        cell.accessoryType = row.studentId == nil ? .none : .disclosureIndicator
        cell.selectionStyle = row.studentId == nil ? .none : .default
        cell.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let id = rows[indexPath.row].studentId else { return }
        navigationController?.pushViewController(HomeroomDetailViewController(repository: repository, context: store.context, studentId: id), animated: true)
    }
}
