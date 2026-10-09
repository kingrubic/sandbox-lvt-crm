import UIKit

@MainActor
final class HomeroomViewController: UITableViewController {
    private let repository: HomeroomRepository
    private let session: UserSession
    private let yearButton = UIButton(type: .system)
    private let datePicker = UIDatePicker()
    private let pane = UISegmentedControl(items: ["Tổng quan", "Vắng chờ xử lý"])
    private var years: [SchoolYear] = []
    private var yearId: String?
    private var date = VietnamDate.today()
    private var overview: HomeroomOverview?
    private var pending: PendingAbsences?
    private var status: HomeroomImportStatus?
    private var loading = false
    private lazy var writes = repository.writeOperations
    private var errorMessage: String?
    private var loadTask: Task<Void, Never>?
    private var generation = 0
    private var rows: [(String, String)] = []
    private var cameraStores: [String: CameraImportStore] = [:]
    private var managementStores: [String: HomeroomManagementStore] = [:]

    init(repository: HomeroomRepository, session: UserSession) {
        self.repository = repository
        self.session = session
        super.init(style: .insetGrouped)
        title = "Lớp chủ nhiệm"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { loadTask?.cancel() }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        load()
        navigationItem.rightBarButtonItems = [UIBarButtonItem(title: "Phân loại vắng", style: .plain, target: self, action: #selector(editPending))]
        if session.isOperationalManager || session.isHomeroomSupervisor {
            navigationItem.rightBarButtonItems?.append(UIBarButtonItem(title: "Nhập camera", style: .plain, target: self, action: #selector(importCamera)))
        }
        if session.isOperationalManager {
            navigationItem.rightBarButtonItems?.append(UIBarButtonItem(title: "Danh mục", style: .plain, target: self, action: #selector(manage)))
        }
    }
    @objc private func manage() {
        guard !loading, session.isOperationalManager, let yearId else { return }
        let requestedDate = date
        let key = "\(yearId)/\(requestedDate)"
        let store = managementStores[key] ?? repository.management(yearId: yearId, date: requestedDate) { [weak self] in self?.yearId == yearId && self?.date == requestedDate }
        managementStores[key] = store
        present(UINavigationController(rootViewController: HomeroomManagementViewController(store: store)), animated: true)
    }
    @objc private func importCamera() {
        guard !loading, let yearId, years.contains(where: { $0.id == yearId }), session.isOperationalManager || session.isHomeroomSupervisor else { return }
        let requestedDate = date
        let key = "\(yearId)/\(requestedDate)"
        let store = cameraStores[key] ?? repository.cameraImport(yearId: yearId, date: requestedDate) { [weak self] in self?.yearId == yearId && self?.date == requestedDate }
        cameraStores[key] = store
        present(UINavigationController(rootViewController: HomeroomCameraImportViewController(store: store)), animated: true)
    }
    @objc private func editPending() {
        guard !loading, !session.isHomeroomSupervisor, pane.selectedSegmentIndex == 1, let year = years.first(where: { $0.id == yearId }), let pending else { return }
        let available = pending.rows.filter { $0.canCorrect && !$0.classId.isEmpty && !$0.studentId.isEmpty }
        let targets = available.map { AbsenceTarget(id: $0.id, studentId: $0.studentId, context: DetailContext(yearId: year.id, classId: $0.classId, date: $0.attendanceDate, from: year.startDate, to: year.endDate)) }
        let selector = HomeroomAbsenceSelectionViewController(targets: targets, labels: available.map { "\($0.fullName) · \($0.classCode)" })
        let requestedDate = date
        selector.onSelect = { [weak self, weak selector] chosen, batch in
            guard let self, let selector, let context = chosen.first?.context else { return }
            let form = HomeroomWriteFormViewController(repository: writes, context: context, targets: chosen, batch: batch, isCurrent: { [weak self] in self?.yearId == year.id && self?.date == requestedDate && self?.pane.selectedSegmentIndex == 1 && self?.errorMessage == nil }, onClear: { [weak self] in self?.overview = nil; self?.pending = nil; self?.render() }, onRefresh: { [weak self] in self?.load() })
            selector.navigationController?.pushViewController(form, animated: true)
        }
        present(UINavigationController(rootViewController: selector), animated: true)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        loadTask?.cancel()
        generation += 1
        overview = nil
        pending = nil
        status = nil
        rows = []
        tableView.reloadData()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 110
        tableView.allowsSelection = true
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(retry), for: .valueChanged)
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Tải lại", style: .plain, target: self, action: #selector(retry))
        yearButton.showsMenuAsPrimaryAction = true
        yearButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        yearButton.titleLabel?.adjustsFontForContentSizeCategory = true
        yearButton.titleLabel?.numberOfLines = 0
        yearButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        datePicker.datePickerMode = .date
        datePicker.preferredDatePickerStyle = .compact
        datePicker.calendar = Calendar(identifier: .gregorian)
        datePicker.timeZone = VietnamDate.timeZone
        datePicker.locale = Locale(identifier: "vi_VN")
        datePicker.date = VietnamDate.date(from: date) ?? Date()
        datePicker.accessibilityLabel = "Ngày điểm danh, múi giờ Việt Nam"
        datePicker.addTarget(self, action: #selector(dateChanged), for: .valueChanged)
        pane.selectedSegmentIndex = 0
        pane.isHidden = session.isHomeroomSupervisor
        pane.addTarget(self, action: #selector(paneChanged), for: .valueChanged)
        pane.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        let stack = UIStackView(arrangedSubviews: [yearButton, datePicker, pane])
        stack.axis = .vertical
        stack.spacing = 12
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20)
        tableView.tableHeaderView = stack
        updateHeader()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let header = tableView.tableHeaderView else { return }
        let size = header.systemLayoutSizeFitting(
            CGSize(width: tableView.bounds.width, height: 0),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        )
        if header.frame.size != size {
            header.frame.size = size
            tableView.tableHeaderView = header
        }
    }

    @objc private func retry() { load() }
    @objc private func paneChanged() { render() }
    @objc private func dateChanged() {
        let selected = VietnamDate.string(from: datePicker.date)
        guard selected != date else { return }
        managementStores.values.forEach { $0.invalidate() }
        date = selected
        load()
    }

    private func updateHeader() {
        yearButton.setTitle(years.first { $0.id == yearId }?.name ?? "Chọn năm học", for: .normal)
        yearButton.menu = UIMenu(children: years.map { year in
            UIAction(title: year.name, state: year.id == yearId ? .on : .off) { [weak self] _ in
                guard let self, self.yearId != year.id else { return }
                self.yearId = year.id
                self.managementStores.values.forEach { $0.invalidate() }
                self.updateHeader()
                self.load()
            }
        })
        pane.setTitle("Vắng chờ xử lý (\(pending?.total ?? 0))", forSegmentAt: 1)
        view.setNeedsLayout()
    }

    private func load() {
        guard session.canSeeHomeroom else {
            overview = nil
            pending = nil
            status = nil
            errorMessage = "Bạn không có quyền truy cập Lớp chủ nhiệm."
            render()
            return
        }
        loadTask?.cancel()
        generation += 1
        let version = generation
        let requestedDate = date
        let requestedYear = yearId
        loading = true
        errorMessage = nil
        overview = nil
        pending = nil
        status = nil
        render()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loadedYears = try await repository.listSchoolYears()
                guard !Task.isCancelled, generation == version else { return }
                years = loadedYears
                yearId = loadedYears.first { $0.id == requestedYear }?.id
                    ?? loadedYears.first { $0.active }?.id ?? loadedYears.first?.id
                updateHeader()
                if let selectedYear = yearId {
                    if session.isHomeroomSupervisor {
                        let result = try await repository.importStatus(schoolYearId: selectedYear, date: requestedDate)
                        guard !Task.isCancelled, generation == version else { return }
                        status = result
                    } else {
                        let result = try await repository.overview(schoolYearId: selectedYear, date: requestedDate)
                        let pendingResult = try await repository.pendingAbsences(schoolYearId: selectedYear)
                        guard !Task.isCancelled, generation == version else { return }
                        guard result.date == requestedDate, result.schoolYear.id == selectedYear else {
                            throw ConvexException(code: "INVALID_RESPONSE", message: "Phản hồi không khớp năm học/ngày đã chọn.")
                        }
                        overview = result
                        pending = pendingResult
                    }
                }
                loading = false
                updateHeader()
                refreshControl?.endRefreshing()
                render()
            } catch {
                guard !Task.isCancelled, generation == version else { return }
                loading = false
                errorMessage = error.localizedDescription
                refreshControl?.endRefreshing()
                render()
            }
        }
    }

    private func render() {
        rows = []
        if loading {
            rows = [("Đang tải lớp chủ nhiệm…", "Ngày Việt Nam: \(VietnamDate.display(date))")]
        } else if let errorMessage {
            rows = [("Chưa tải được dữ liệu", "\(errorMessage)\nNhấn Tải lại để thử lại. Ngày \(VietnamDate.display(date)).")]
        } else if years.isEmpty {
            rows = [("Chưa có năm học", "Quản trị viên cần tạo năm học trước khi xem điểm danh.")]
        } else if session.isHomeroomSupervisor, let status {
            rows.append(("Giám thị · Chỉ xem trạng thái công bố", "Ngày \(VietnamDate.display(date)). Không cấp quyền xem danh sách lớp/học sinh. Nhập, kiểm tra và công bố tệp chưa được triển khai."))
            rows.append(("Đã có dữ liệu cho \(status.publishedClassCount) lớp", status.uploads.isEmpty ? "Chưa có tệp đã công bố cho ngày này." : "\(status.uploads.count) tệp đã công bố."))
            rows += status.uploads.map { ($0.fileName, "\($0.matchedCount)/\($0.rowCount) dòng khớp · \($0.uploadedByName)") }
        } else if pane.selectedSegmentIndex == 1, let pending {
            rows.append(("Vắng chờ xử lý · \(pending.total) buổi", "Toàn năm học, không lọc theo ngày tổng quan. Nhấn Phân loại vắng để chọn rõ từng buổi; tối đa 100 buổi duy nhất, không chọn phần bị giới hạn."))
            if pending.truncated {
                rows.append(("Danh sách bị giới hạn bởi máy chủ", "Hiển thị \(pending.rows.count)/\(pending.total) buổi mới nhất; không phải danh sách đầy đủ."))
            }
            if pending.rows.isEmpty { rows.append(("Không có buổi vắng chờ xử lý", "Trong phạm vi được máy chủ cho phép.")) }
            rows += pending.rows.map {
                ($0.fullName, "\($0.studentCode) · Lớp \($0.classCode) · \(VietnamDate.display($0.attendanceDate))\n\($0.note)\nQuyền phân loại từ máy chủ: \($0.canCorrect ? "Có" : "Không")")
            }
        } else if let overview {
            rows.append(("Tổng quan \(VietnamDate.display(overview.date))", "\(overview.studentCount) học sinh · \(overview.classes.count) lớp\n\(countsText(overview.counts))"))
            rows.append(("Chuyên cần", overview.ratedRows > 0 ? String(format: "%.1f%% · %d dòng được đánh giá", overview.attendanceRate * 100, overview.ratedRows) : "— Chưa có dữ liệu đánh giá"))
            if overview.schoolDay.outsideYear {
                rows.append(("Ngoài năm học", "Ngày đã chọn nằm ngoài năm học \(overview.schoolYear.name)."))
            } else if !overview.schoolDay.isSchoolDay {
                rows.append(("Không phải ngày học", overview.schoolDay.note.isEmpty ? "Không cần điểm danh." : overview.schoolDay.note))
            }
            if overview.missingUploadShouldAlert {
                rows.append(("Thiếu dữ liệu sau \(overview.missingUploadCutoffTime)", overview.missingClassCodes.joined(separator: ", ")))
            }
            if overview.classes.isEmpty {
                rows.append(("Chưa có lớp trong phạm vi ngày này", "Chưa được phân công lớp hoặc năm học chưa có lớp đang hoạt động."))
            }
            rows += overview.classes.map {
                ("\($0.code) · \($0.name)", "Sĩ số \($0.rosterCount) · GVCN \($0.teacherName.isEmpty ? "Chưa phân công" : $0.teacherName)\n\($0.published ? countsText($0.counts) : "Chưa có dữ liệu điểm danh")\nChờ xử lý \($0.pendingTotal) · Xem danh sách lớp và điểm danh")
            }
        }
        tableView.reloadData()
        navigationItem.rightBarButtonItem?.isEnabled = !loading && errorMessage == nil && !session.isHomeroomSupervisor && pane.selectedSegmentIndex == 1 && pending?.rows.contains(where: { $0.canCorrect && !$0.classId.isEmpty && !$0.studentId.isEmpty }) == true
    }

    private func countsText(_ counts: AttendanceCounts) -> String {
        "Có mặt \(counts.present) · Trễ \(counts.late) · Vắng \(counts.absent)\nChưa có dữ liệu \(counts.noData) · Miễn \(counts.exempt)"
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "homeroom")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "homeroom")
        var content = cell.defaultContentConfiguration()
        content.text = rows[indexPath.row].0
        content.secondaryText = rows[indexPath.row].1
        content.textProperties.font = .preferredFont(forTextStyle: .headline)
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .body)
        content.textProperties.numberOfLines = 0
        content.secondaryTextProperties.numberOfLines = 0
        cell.contentConfiguration = content
        let isClass = classAt(indexPath.row) != nil
        cell.selectionStyle = isClass ? .default : .none
        cell.accessoryType = isClass ? .disclosureIndicator : .none
        return cell
    }

    private func classAt(_ row: Int) -> HomeroomClassSummary? {
        guard !loading, errorMessage == nil, !session.isHomeroomSupervisor, pane.selectedSegmentIndex == 0,
              let overview else { return nil }
        let offset = rows.count - overview.classes.count
        guard row >= offset, row - offset < overview.classes.count else { return nil }
        return overview.classes[row - offset]
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let klass = classAt(indexPath.row), let year = years.first(where: { $0.id == yearId }) else { return }
        let context = DetailContext(yearId: year.id, classId: klass.id, date: date, from: year.startDate, to: year.endDate)
        let controller = HomeroomDetailViewController(repository: repository, context: context)
        controller.onClassDateChanged = { [weak self] selected in
            self?.date = selected
            if let value = VietnamDate.date(from: selected) { self?.datePicker.date = value }
        }
        navigationController?.pushViewController(controller, animated: true)
    }
}
