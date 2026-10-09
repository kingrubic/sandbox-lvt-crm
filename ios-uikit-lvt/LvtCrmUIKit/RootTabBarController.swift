import UIKit

/// Authenticated UIKit shell.
final class RootTabBarController: UITabBarController, UITabBarControllerDelegate {
    private let session: UserSession
    private let authRepository: AuthRepository
    private let sessionsRepository: SessionsRepository
    private let notificationsRepository: NotificationsRepository
    private let dutiesRepository: DutiesRepository
    private let workRepository: WorkRepository
    private let chatRepository: ChatRepository
    private let avatarRepository: AvatarRepository
    private let homeroomRepository: HomeroomRepository
    private let notificationsViewModel: NotificationsViewModel
    private var tabControllers: [AppTab: UINavigationController] = [:]
    private var headerClusters: [AccountHeaderClusterView] = []
    private var notificationsViewController: NotificationsViewController?
    private var profileViewController: ProfileViewController?
    private weak var dutiesHubViewController: DutiesHubViewController?
    private weak var workViewController: WorkViewController?
    private weak var chatHubViewController: ChatHubViewController?
    private var unreadTask: Task<Void, Never>?
    private var pushObserver: NSObjectProtocol?
    private var avatarObserver: NSObjectProtocol?
    private var avatarImage: UIImage?

    init(
        session: UserSession,
        authRepository: AuthRepository,
        sessionsRepository: SessionsRepository,
        notificationsRepository: NotificationsRepository,
        dutiesRepository: DutiesRepository,
        workRepository: WorkRepository,
        chatRepository: ChatRepository,
        avatarRepository: AvatarRepository,
        homeroomRepository: HomeroomRepository
    ) {
        self.session = session
        self.authRepository = authRepository
        self.sessionsRepository = sessionsRepository
        self.notificationsRepository = notificationsRepository
        self.dutiesRepository = dutiesRepository
        self.workRepository = workRepository
        self.chatRepository = chatRepository
        self.avatarRepository = avatarRepository
        self.homeroomRepository = homeroomRepository
        self.notificationsViewModel = NotificationsViewModel(repository: notificationsRepository)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let pushObserver {
            NotificationCenter.default.removeObserver(pushObserver)
        }
        if let avatarObserver {
            NotificationCenter.default.removeObserver(avatarObserver)
        }
        unreadTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
        let previousOnChange = notificationsViewModel.onChange
        notificationsViewModel.onChange = { [weak self] in
            previousOnChange?()
            self?.updateHeaderClusters()
        }
        let notificationsViewController = NotificationsViewController(
            viewModel: notificationsViewModel,
            onOpenDestination: { [weak self] destination in
                self?.route(destination, markNotificationRead: false)
            }
        )
        let profileViewController = ProfileViewController(
            session: session,
            authRepository: authRepository,
            sessionsRepository: sessionsRepository,
            avatarRepository: avatarRepository
        )
        self.notificationsViewController = notificationsViewController
        self.profileViewController = profileViewController
        let overviewViewController = DashboardViewController(
            dutiesRepository: dutiesRepository,
            workRepository: workRepository,
            onOpenDuties: { [weak self] tab in self?.openDuties(tab: tab) },
            onOpenWork: { [weak self] filter in self?.openWork(filter: filter) }
        )
        overviewViewController.navigationItem.rightBarButtonItem = makeAccountHeaderItem()
        let overview = navigationController(
            title: "Tổng quan",
            systemImage: "rectangle.grid.2x2",
            viewController: overviewViewController
        )
        let dutiesHubViewController = DutiesHubViewController(
            dutiesViewModel: DutiesViewModel(repository: dutiesRepository, currentUserId: session.userId),
            dutiesRepository: dutiesRepository,
            chatRepository: chatRepository
        )
        dutiesHubViewController.navigationItem.rightBarButtonItem = makeAccountHeaderItem()
        dutiesHubViewController.dutiesListController.trailingAccessoryBarButtonItems = [makeAccountHeaderItem()]
        let duties = navigationController(
            title: "Lịch CT",
            systemImage: "briefcase",
            viewController: dutiesHubViewController
        )
        let repository = workRepository
        let workViewController = WorkViewController(
            viewModel: WorkViewModel(repository: repository),
            chatRepository: chatRepository,
            downloadDocument: { document in try await repository.downloadDocument(document) }
        )
        workViewController.trailingAccessoryBarButtonItems = [makeAccountHeaderItem()]
        let work = navigationController(
            title: "Công việc",
            systemImage: "checkmark.seal",
            viewController: workViewController
        )
        let chatHubViewController = ChatHubViewController(
            repository: chatRepository,
            onOpenDuty: { [weak self] dutyId in self?.openDutyFromChat(dutyId) },
            onOpenWork: { [weak self] documentId in self?.openWorkFromChat(documentId) },
            onUnread: { [weak self] count in self?.applyChatBadge(count) }
        )
        let chat = navigationController(
            title: "Trao đổi",
            systemImage: "bubble.left.and.bubble.right",
            viewController: chatHubViewController
        )
        chatHubViewController.installAccountHeader(makeAccountHeaderItem())
        tabControllers = [
            .overview: overview,
            .chat: chat,
            .duties: duties,
            .work: work,
        ]
        self.dutiesHubViewController = dutiesHubViewController
        self.workViewController = workViewController
        self.chatHubViewController = chatHubViewController
        viewControllers = [overview, chat, duties, work]
        if session.canSeeHomeroom {
            let homeroom = navigationController(
                title: "Lớp chủ nhiệm", systemImage: "person.3",
                viewController: HomeroomViewController(repository: homeroomRepository, session: session)
            )
            viewControllers = [overview, homeroom, chat, duties, work]
        }
        startUnreadPolling()
        pushObserver = NotificationCenter.default.addObserver(
            forName: .pushReceived,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.notificationsViewModel.refresh() }
        }
        notificationsViewModel.refresh(initial: true)
        Task { await sessionsRepository.registerCurrentDevice() }
        avatarObserver = NotificationCenter.default.addObserver(
            forName: .accountAvatarDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let image = notification.object as? UIImage
            Task { @MainActor in self?.applyAvatarImage(image) }
        }
        Task { await reloadAvatar() }
    }

    private func selectTab(_ tab: AppTab) {
        selectedViewController = tabControllers[tab]
    }

    private func openDuties(tab: DutyListTab) {
        selectTab(.duties)
        if let navigationController = tabControllers[.duties] {
            detachAuxiliary(from: navigationController)
        }
        dutiesHubViewController?.openPersonal(animated: false)
        dutiesHubViewController?.dutiesListController.applyListTab(tab)
    }

    private func openWork(filter: WorkDashboardFilter?) {
        selectTab(.work)
        tabControllers[.work]?.popToRootViewController(animated: false)
        workViewController?.applyDashboardFilter(filter)
    }

    private func openDutyFromChat(_ dutyId: String) {
        selectTab(.duties)
        if let navigationController = tabControllers[.duties] {
            detachAuxiliary(from: navigationController)
        }
        dutiesHubViewController?.openPersonal(animated: false)
        dutiesHubViewController?.dutiesListController.focus(dutyId: dutyId, openChat: false)
    }

    private func openWorkFromChat(_ documentId: String) {
        selectTab(.work)
        tabControllers[.work]?.popToRootViewController(animated: false)
        workViewController?.focus(itemId: documentId, openChat: false)
    }

    private func applyChatBadge(_ count: Int) {
        let item = tabControllers[.chat]?.tabBarItem
        item?.badgeValue = count > 0 ? (count > 99 ? "99+" : "\(count)") : nil
    }

    private func startUnreadPolling() {
        unreadTask?.cancel()
        unreadTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if let count = try? await self?.chatRepository.unreadTotal() {
                    self?.applyChatBadge(count)
                }
                try? await Task.sleep(nanoseconds: 12_000_000_000)
            }
        }
    }

    func openNotifications() {
        guard let controller = notificationsViewController else { return }
        presentAuxiliary(controller)
        controller.refreshAfterDestination()
    }

    func openProfile() {
        guard let controller = profileViewController else { return }
        presentAuxiliary(controller)
    }

    func route(_ destination: NotificationDestination, markNotificationRead: Bool = true) {
        let tab = destination.route
        guard let navigationController = tabControllers[tab] else { return }
        selectedViewController = navigationController
        detachAuxiliary(from: navigationController)
        if destination.opensChat {
            navigationController.popToRootViewController(animated: false)
            chatHubViewController?.openThread(kind: destination.chatKind, entityId: destination.sourceId)
        } else if tab == .duties {
            dutiesHubViewController?.openPersonal(animated: false)
            dutiesHubViewController?.dutiesListController.focus(
                dutyId: destination.sourceId,
                openChat: destination.opensChat
            )
        } else {
            navigationController.popToRootViewController(animated: false)
            if tab == .work {
                workViewController?.focus(itemId: destination.sourceId, openChat: destination.opensChat)
            }
        }
        if markNotificationRead, let key = destination.notificationKey {
            Task { [weak self] in
                guard let self else { return }
                try? await notificationsRepository.markRead(notificationKey: key)
                notificationsViewController?.refreshAfterDestination()
                updateHeaderClusters()
            }
        }
    }

    private func makeAccountHeaderItem() -> UIBarButtonItem {
        let cluster = AccountHeaderClusterView(
            initials: accountInitials(name: session.name, email: session.email),
            unreadCount: notificationsViewModel.unreadCount
        )
        cluster.onBell = { [weak self] in self?.openNotifications() }
        cluster.onAvatar = { [weak self] in self?.openProfile() }
        cluster.setAvatarImage(avatarImage)
        headerClusters.append(cluster)
        return UIBarButtonItem(customView: cluster)
    }

    private func applyAvatarImage(_ image: UIImage?) {
        avatarImage = image
        headerClusters.forEach { $0.setAvatarImage(image) }
        profileViewController?.applyAvatarImage(image)
    }

    private func reloadAvatar() async {
        let image = await avatarRepository.image(
            userId: session.userId,
            hasAvatar: session.hasAvatar,
            version: session.avatarVersion
        )
        applyAvatarImage(image)
    }

    private func updateHeaderClusters() {
        let count = notificationsViewModel.unreadCount
        headerClusters.forEach { $0.unreadCount = count }
    }

    private func presentAuxiliary(_ controller: UIViewController) {
        guard let navigationController = selectedViewController as? UINavigationController else { return }
        if let existing = navigationController.viewControllers.first(where: { $0 === controller }) {
            navigationController.popToViewController(existing, animated: !UIAccessibility.isReduceMotionEnabled)
            return
        }
        detachAuxiliary(controller)
        navigationController.pushViewController(controller, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    private func detachAuxiliary(_ controller: UIViewController) {
        guard let host = controller.navigationController else { return }
        let remaining = host.viewControllers.filter { $0 !== controller }
        if remaining.count != host.viewControllers.count {
            host.setViewControllers(remaining, animated: false)
        }
    }

    private func detachAuxiliary(from navigationController: UINavigationController) {
        let remaining = navigationController.viewControllers.filter {
            $0 !== notificationsViewController && $0 !== profileViewController
        }
        if remaining.count != navigationController.viewControllers.count {
            navigationController.setViewControllers(remaining, animated: false)
        }
    }

    private func navigationController(
        title: String,
        systemImage: String,
        viewController: UIViewController
    ) -> UINavigationController {
        let navigationController = UINavigationController(rootViewController: viewController)
        navigationController.navigationBar.prefersLargeTitles = true
        navigationController.tabBarItem = UITabBarItem(
            title: title,
            image: UIImage(systemName: systemImage),
            selectedImage: nil
        )
        return navigationController
    }

    func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
        if viewController === tabControllers[.duties] {
            tabControllers[.duties]?.popToRootViewController(animated: false)
        }
        return true
    }
}

@MainActor
private final class DashboardViewController: UIViewController {
    private let dutiesRepository: DutiesRepository
    private let workRepository: WorkRepository
    private let onOpenDuties: (DutyListTab) -> Void
    private let onOpenWork: (WorkDashboardFilter?) -> Void
    private let dutiesCard = DashboardCard(
        title: "Công tác",
        subtitle: "Lịch điều phối",
        icon: "briefcase.fill",
        tint: DashboardPalette.dutiesAccent
    )
    private let workCard = DashboardCard(
        title: "Công việc",
        subtitle: "Tiến độ vận hành",
        icon: "checkmark.seal.fill",
        tint: DashboardPalette.workAccent
    )
    private let synchronizationView = DashboardSynchronizationView()
    private let refreshButton = UIButton(type: .system)
    private let headerRow = UIStackView()
    private let refreshControl = UIRefreshControl()
    private var refreshTask: Task<Void, Never>?
    private var appearanceObserver: NSObjectProtocol?

    init(
        dutiesRepository: DutiesRepository,
        workRepository: WorkRepository,
        onOpenDuties: @escaping (DutyListTab) -> Void,
        onOpenWork: @escaping (WorkDashboardFilter?) -> Void
    ) {
        self.dutiesRepository = dutiesRepository
        self.workRepository = workRepository
        self.onOpenDuties = onOpenDuties
        self.onOpenWork = onOpenWork
        super.init(nibName: nil, bundle: nil)
        title = "Tổng quan"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        refreshTask?.cancel()
        if let appearanceObserver {
            NotificationCenter.default.removeObserver(appearanceObserver)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .always
        configureView()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (controller: DashboardViewController, _) in
            controller.applyAppearance()
        }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (controller: DashboardViewController, _) in
            controller.updateResponsiveLayout()
        }
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: .lvtUserInterfaceStyleDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyAppearance()
        }
        applyAppearance()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applyAppearance()
        refresh()
    }

    private func configureView() {
        let scrollView = UIScrollView()
        let stack = UIStackView()
        let eyebrowLabel = UILabel()
        let subtitleLabel = UILabel()

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.refreshControl = refreshControl
        refreshControl.tintColor = DashboardPalette.primaryText
        refreshControl.accessibilityLabel = "Làm mới tổng quan"
        refreshControl.addAction(UIAction { [weak self] _ in self?.refresh() }, for: .valueChanged)

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 20
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 24, leading: 20, bottom: 36, trailing: 20)

        eyebrowLabel.text = "TRUNG TÂM ĐIỀU HÀNH"
        eyebrowLabel.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(
            for: .systemFont(ofSize: 12, weight: .semibold),
            maximumPointSize: 18
        )
        eyebrowLabel.adjustsFontForContentSizeCategory = true
        eyebrowLabel.textColor = DashboardPalette.dutiesAccent
        eyebrowLabel.numberOfLines = 0
        eyebrowLabel.accessibilityTraits = .header

        subtitleLabel.text = "Theo dõi những nội dung cần bạn xử lý."
        subtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        subtitleLabel.textColor = DashboardPalette.secondaryText
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.numberOfLines = 0
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var buttonConfiguration = UIButton.Configuration.tinted()
        buttonConfiguration.title = "Làm mới"
        buttonConfiguration.image = UIImage(systemName: "arrow.clockwise")
        buttonConfiguration.imagePadding = 7
        buttonConfiguration.cornerStyle = .capsule
        buttonConfiguration.baseForegroundColor = DashboardPalette.dutiesAccent
        buttonConfiguration.baseBackgroundColor = DashboardPalette.dutiesAccent.withAlphaComponent(0.16)
        buttonConfiguration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .preferredFont(forTextStyle: .subheadline)
            return attributes
        }
        refreshButton.configuration = buttonConfiguration
        refreshButton.addAction(UIAction { [weak self] _ in self?.refresh() }, for: .touchUpInside)
        refreshButton.accessibilityLabel = "Làm mới tổng quan"
        refreshButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        headerRow.addArrangedSubview(subtitleLabel)
        headerRow.addArrangedSubview(UIView())
        headerRow.addArrangedSubview(refreshButton)
        headerRow.spacing = 12

        stack.addArrangedSubview(eyebrowLabel)
        stack.setCustomSpacing(8, after: eyebrowLabel)
        stack.addArrangedSubview(headerRow)
        stack.setCustomSpacing(28, after: headerRow)
        stack.addArrangedSubview(dutiesCard)
        stack.addArrangedSubview(workCard)
        stack.setCustomSpacing(24, after: workCard)
        stack.addArrangedSubview(synchronizationView)
        scrollView.addSubview(stack)
        view.addSubview(scrollView)

        dutiesCard.onOpenPrimary = { [weak self] in self?.onOpenDuties(.upcoming) }
        dutiesCard.onOpenSecondary = { [weak self] in self?.onOpenDuties(.ongoing) }
        workCard.onOpenPrimary = { [weak self] in self?.onOpenWork(.pendingApproval) }
        workCard.onOpenSecondary = { [weak self] in self?.onOpenWork(.needsExecution) }
        dutiesCard.addAction(UIAction { [weak self] _ in self?.onOpenDuties(.upcoming) }, for: .touchUpInside)
        workCard.addAction(UIAction { [weak self] _ in self?.onOpenWork(nil) }, for: .touchUpInside)

        updateResponsiveLayout()
        synchronizationView.setLoading()

        let readableLeading = stack.leadingAnchor.constraint(
            greaterThanOrEqualTo: view.readableContentGuide.leadingAnchor
        )
        readableLeading.priority = .defaultHigh
        let readableTrailing = stack.trailingAnchor.constraint(
            lessThanOrEqualTo: view.readableContentGuide.trailingAnchor
        )
        readableTrailing.priority = .defaultHigh

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            readableLeading,
            readableTrailing,
            dutiesCard.heightAnchor.constraint(greaterThanOrEqualToConstant: 224),
            workCard.heightAnchor.constraint(greaterThanOrEqualToConstant: 224),
        ])
    }

    private func updateResponsiveLayout() {
        let usesAccessibilityLayout = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        headerRow.axis = usesAccessibilityLayout ? .vertical : .horizontal
        headerRow.alignment = usesAccessibilityLayout ? .leading : .center
        dutiesCard.setUsesAccessibilityLayout(usesAccessibilityLayout)
        workCard.setUsesAccessibilityLayout(usesAccessibilityLayout)
    }

    private func applyAppearance() {
        let traits = AppAppearance.resolvedTraits(for: view)
        view.backgroundColor = DashboardPalette.canvas.resolvedColor(with: traits)
        refreshControl.tintColor = DashboardPalette.primaryText.resolvedColor(with: traits)
        dutiesCard.applyColors()
        workCard.applyColors()
        synchronizationView.applyColors()
        guard let navigationBar = navigationController?.navigationBar else { return }
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = DashboardPalette.canvas.resolvedColor(with: traits)
        appearance.shadowColor = .clear
        appearance.titleTextAttributes = [
            .foregroundColor: DashboardPalette.primaryText.resolvedColor(with: traits),
        ]
        appearance.largeTitleTextAttributes = [
            .foregroundColor: DashboardPalette.primaryText.resolvedColor(with: traits),
        ]
        navigationBar.standardAppearance = appearance
        navigationBar.scrollEdgeAppearance = appearance
        navigationBar.compactAppearance = appearance
        navigationBar.tintColor = DashboardPalette.dutiesAccent
    }

    private func refresh() {
        refreshButton.isEnabled = false
        synchronizationView.setLoading()
        dutiesCard.setLoading()
        workCard.setLoading()
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer {
                refreshButton.isEnabled = true
                refreshControl.endRefreshing()
            }
            do {
                async let duties = dutiesRepository.listMine()
                async let work = workRepository.listMine()
                let (dutiesSnapshot, workSnapshot) = try await (duties, work)
                guard !Task.isCancelled else { return }
                dutiesCard.setValues(
                    primaryTitle: "Sắp diễn ra",
                    primaryValue: String(dutiesSnapshot.duties.filter(\.isUpcoming).count),
                    secondaryTitle: "Đang diễn ra",
                    secondaryValue: String(dutiesSnapshot.duties.filter(\.isOngoing).count)
                )
                let pendingApproval = workSnapshot.completionReviews.count
                let pendingExecution = workSnapshot.tasks.filter { WorkHelpers.needsCompletion($0.status) }.count
                workCard.setValues(
                    primaryTitle: "Chờ duyệt nộp",
                    primaryValue: String(pendingApproval),
                    secondaryTitle: "Cần thực hiện",
                    secondaryValue: String(pendingExecution)
                )
                synchronizationView.setSynchronized()
            } catch is CancellationError {
                return
            } catch {
                dutiesCard.setError()
                workCard.setError()
                synchronizationView.setError()
            }
        }
    }
}

private enum DashboardPalette {
    static let dutiesAccent = UIColor(red: 0.24, green: 0.58, blue: 1.00, alpha: 1)
    static let workAccent = UIColor(red: 0.23, green: 0.78, blue: 0.52, alpha: 1)

    static let canvas = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.025, green: 0.055, blue: 0.105, alpha: 1)
            : UIColor(red: 0.945, green: 0.965, blue: 0.985, alpha: 1)
    }

    static let cardStart = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.070, green: 0.115, blue: 0.180, alpha: 1)
            : .white
    }

    static let cardEnd = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.045, green: 0.080, blue: 0.135, alpha: 1)
            : UIColor(red: 0.925, green: 0.950, blue: 0.975, alpha: 1)
    }

    static let panelStart = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.060, green: 0.095, blue: 0.150, alpha: 1)
            : UIColor(red: 0.975, green: 0.985, blue: 0.995, alpha: 1)
    }

    static let panelEnd = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.040, green: 0.068, blue: 0.115, alpha: 1)
            : UIColor(red: 0.920, green: 0.945, blue: 0.970, alpha: 1)
    }

    static let primaryText = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.955, green: 0.975, blue: 1.000, alpha: 1)
            : UIColor(red: 0.045, green: 0.085, blue: 0.145, alpha: 1)
    }

    static let secondaryText = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.630, green: 0.695, blue: 0.785, alpha: 1)
            : UIColor(red: 0.310, green: 0.385, blue: 0.475, alpha: 1)
    }

    static let cardBorder = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.09)
            : UIColor(red: 0.090, green: 0.180, blue: 0.300, alpha: 0.11)
    }
}

private final class DashboardCard: UIControl {
    var onOpenPrimary: (() -> Void)?
    var onOpenSecondary: (() -> Void)?
    private let tint: UIColor
    private let backgroundView = DashboardGradientView(
        colors: { [DashboardPalette.cardStart.resolvedColor(with: $0), DashboardPalette.cardEnd.resolvedColor(with: $0)] },
        startPoint: CGPoint(x: 0, y: 0),
        endPoint: CGPoint(x: 1, y: 1)
    )
    private let accentView: DashboardGradientView
    private let iconTile: DashboardIconTile
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let primaryMetric: DashboardMetricView
    private let secondaryMetric: DashboardMetricView
    private let metricsStack = UIStackView()
    private let arrowView = UIImageView(image: UIImage(systemName: "chevron.right"))

    init(title: String, subtitle: String, icon: String, tint: UIColor) {
        self.tint = tint
        self.accentView = DashboardGradientView(
            colors: { _ in [tint, tint.withAlphaComponent(0.08)] },
            startPoint: CGPoint(x: 0, y: 0.5),
            endPoint: CGPoint(x: 1, y: 0.5)
        )
        self.iconTile = DashboardIconTile(icon: icon, tint: tint)
        self.primaryMetric = DashboardMetricView(tint: tint)
        self.secondaryMetric = DashboardMetricView(tint: tint)
        super.init(frame: .zero)
        accessibilityLabel = title
        isAccessibilityElement = false
        configure(title: title, subtitle: subtitle)
        setLoading()
        applyColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (card: DashboardCard, _) in
            card.applyColors()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.16) {
                self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.985, y: 0.985) : .identity
                self.alpha = self.isHighlighted ? 0.86 : 1
            }
        }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled,
              !isHidden,
              alpha > 0.01,
              self.point(inside: point, with: event) else { return nil }
        let primaryPoint = convert(point, to: primaryMetric)
        if primaryMetric.point(inside: primaryPoint, with: event) {
            return primaryMetric
        }
        let secondaryPoint = convert(point, to: secondaryMetric)
        if secondaryMetric.point(inside: secondaryPoint, with: event) {
            return secondaryMetric
        }
        return self
    }

    func setUsesAccessibilityLayout(_ enabled: Bool) {
        metricsStack.axis = enabled ? .vertical : .horizontal
        metricsStack.distribution = enabled ? .fill : .fillEqually
        primaryMetric.setUsesAccessibilityLayout(enabled)
        secondaryMetric.setUsesAccessibilityLayout(enabled)
    }

    func setLoading() {
        primaryMetric.setLoading(title: "Sắp cập nhật")
        secondaryMetric.setLoading(title: "Sắp cập nhật")
        accessibilityValue = "Đang tải"
    }

    func setError() {
        primaryMetric.setError(title: "Chưa tải được")
        secondaryMetric.setError(title: "Chạm để mở")
        accessibilityValue = "Chưa tải được dữ liệu"
    }

    func setValues(primaryTitle: String, primaryValue: String, secondaryTitle: String, secondaryValue: String) {
        primaryMetric.setValue(primaryValue, title: primaryTitle)
        secondaryMetric.setValue(secondaryValue, title: secondaryTitle)
        accessibilityValue = "\(primaryTitle) \(primaryValue), \(secondaryTitle) \(secondaryValue)"
    }

    private func configure(title: String, subtitle: String) {
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.22
        layer.shadowRadius = 22
        layer.shadowOffset = CGSize(width: 0, height: 12)

        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.layer.cornerRadius = 24
        backgroundView.layer.cornerCurve = .continuous
        backgroundView.clipsToBounds = true
        backgroundView.isUserInteractionEnabled = false
        addSubview(backgroundView)

        accentView.translatesAutoresizingMaskIntoConstraints = false
        accentView.layer.cornerRadius = 1.5
        accentView.isUserInteractionEnabled = false
        addSubview(accentView)

        titleLabel.text = title
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.textColor = DashboardPalette.primaryText
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0

        subtitleLabel.text = subtitle.uppercased()
        subtitleLabel.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(
            for: .systemFont(ofSize: 11, weight: .semibold),
            maximumPointSize: 16
        )
        subtitleLabel.textColor = DashboardPalette.secondaryText
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.numberOfLines = 0

        let headingStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        headingStack.axis = .vertical
        headingStack.spacing = 3

        arrowView.tintColor = DashboardPalette.secondaryText
        arrowView.contentMode = .scaleAspectFit
        arrowView.setContentCompressionResistancePriority(.required, for: .horizontal)
        arrowView.widthAnchor.constraint(equalToConstant: 14).isActive = true

        let titleRow = UIStackView(arrangedSubviews: [iconTile, headingStack, UIView(), arrowView])
        titleRow.axis = .horizontal
        titleRow.alignment = .center
        titleRow.spacing = 14

        metricsStack.addArrangedSubview(primaryMetric)
        metricsStack.addArrangedSubview(secondaryMetric)
        metricsStack.axis = .horizontal
        metricsStack.distribution = .fillEqually
        metricsStack.alignment = .fill
        metricsStack.spacing = 16
        primaryMetric.addAction(UIAction { [weak self] _ in self?.onOpenPrimary?() }, for: .touchUpInside)
        secondaryMetric.addAction(UIAction { [weak self] _ in self?.onOpenSecondary?() }, for: .touchUpInside)
        accessibilityElements = [primaryMetric, secondaryMetric]

        let contentStack = UIStackView(arrangedSubviews: [titleRow, metricsStack])
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 24
        addSubview(contentStack)

        NSLayoutConstraint.activate([
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),
            accentView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            accentView.topAnchor.constraint(equalTo: topAnchor),
            accentView.widthAnchor.constraint(equalToConstant: 116),
            accentView.heightAnchor.constraint(equalToConstant: 3),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 22),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -22),
        ])
    }

    fileprivate func applyColors() {
        let traits = AppAppearance.resolvedTraits(for: self)
        backgroundView.applyColors()
        accentView.applyColors()
        iconTile.applyColors()
        primaryMetric.applyColors()
        secondaryMetric.applyColors()
        backgroundView.layer.borderWidth = 1
        backgroundView.layer.borderColor = DashboardPalette.cardBorder.resolvedColor(with: traits).cgColor
        titleLabel.textColor = DashboardPalette.primaryText.resolvedColor(with: traits)
        subtitleLabel.textColor = DashboardPalette.secondaryText.resolvedColor(with: traits)
        arrowView.tintColor = DashboardPalette.secondaryText.resolvedColor(with: traits)
        layer.shadowOpacity = traits.userInterfaceStyle == .dark ? 0.30 : 0.12
    }
}

private final class DashboardMetricView: UIControl {
    private let tint: UIColor
    private let circleView = UIView()
    private let valueLabel = UILabel()
    private let titleLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let stack = UIStackView()

    init(tint: UIColor) {
        self.tint = tint
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityTraits = .button
        configure()
        applyColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (metric: DashboardMetricView, _) in
            metric.applyColors()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setUsesAccessibilityLayout(_ enabled: Bool) {
        stack.axis = enabled ? .horizontal : .vertical
        stack.alignment = .center
        titleLabel.textAlignment = enabled ? .left : .center
    }

    func setLoading(title: String) {
        valueLabel.isHidden = true
        spinner.startAnimating()
        titleLabel.text = title
        accessibilityLabel = title
        accessibilityValue = "Đang tải"
    }

    func setError(title: String) {
        spinner.stopAnimating()
        valueLabel.isHidden = false
        valueLabel.text = "!"
        titleLabel.text = title
        accessibilityLabel = title
        accessibilityValue = "Chưa tải được"
    }

    func setValue(_ value: String, title: String) {
        spinner.stopAnimating()
        valueLabel.isHidden = false
        valueLabel.text = value
        titleLabel.text = title
        accessibilityLabel = "\(title), \(value)"
        accessibilityHint = "Mở danh sách \(title.lowercased())"
    }

    private func configure() {
        circleView.translatesAutoresizingMaskIntoConstraints = false
        circleView.layer.cornerRadius = 38
        circleView.layer.cornerCurve = .continuous
        circleView.layer.borderWidth = 1.5

        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.font = UIFontMetrics(forTextStyle: .title1).scaledFont(
            for: .systemFont(ofSize: 32, weight: .bold),
            maximumPointSize: 38
        )
        valueLabel.textAlignment = .center
        valueLabel.adjustsFontForContentSizeCategory = true
        valueLabel.adjustsFontSizeToFitWidth = true
        valueLabel.minimumScaleFactor = 0.62

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.color = tint
        circleView.addSubview(valueLabel)
        circleView.addSubview(spinner)

        titleLabel.font = .preferredFont(forTextStyle: .footnote)
        titleLabel.textColor = DashboardPalette.secondaryText
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        titleLabel.textAlignment = .center

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 10
        stack.addArrangedSubview(circleView)
        stack.addArrangedSubview(titleLabel)
        addSubview(stack)

        NSLayoutConstraint.activate([
            circleView.widthAnchor.constraint(equalToConstant: 76),
            circleView.heightAnchor.constraint(equalToConstant: 76),
            valueLabel.leadingAnchor.constraint(equalTo: circleView.leadingAnchor, constant: 8),
            valueLabel.trailingAnchor.constraint(equalTo: circleView.trailingAnchor, constant: -8),
            valueLabel.centerYAnchor.constraint(equalTo: circleView.centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: circleView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: circleView.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    fileprivate func applyColors() {
        let traits = AppAppearance.resolvedTraits(for: self)
        circleView.backgroundColor = tint.resolvedColor(with: traits).withAlphaComponent(
            traits.userInterfaceStyle == .dark ? 0.11 : 0.09
        )
        circleView.layer.borderColor = tint.resolvedColor(with: traits).withAlphaComponent(0.42).cgColor
        valueLabel.textColor = DashboardPalette.primaryText.resolvedColor(with: traits)
        titleLabel.textColor = DashboardPalette.secondaryText.resolvedColor(with: traits)
    }
}

private final class DashboardIconTile: UIView {
    private let tint: UIColor
    private let gradientLayer = CAGradientLayer()
    private let iconView = UIImageView()

    init(icon: String, tint: UIColor) {
        self.tint = tint
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = 17
        layer.cornerCurve = .continuous
        layer.shadowColor = tint.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 16
        layer.shadowOffset = .zero

        gradientLayer.cornerRadius = 17
        gradientLayer.startPoint = CGPoint(x: 0, y: 0)
        gradientLayer.endPoint = CGPoint(x: 1, y: 1)
        layer.insertSublayer(gradientLayer, at: 0)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = UIImage(systemName: icon)
        iconView.tintColor = .white
        iconView.contentMode = .scaleAspectFit
        addSubview(iconView)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 56),
            heightAnchor.constraint(equalToConstant: 56),
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 27),
            iconView.heightAnchor.constraint(equalToConstant: 27),
        ])
        applyColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (tile: DashboardIconTile, _) in
            tile.applyColors()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer.frame = bounds
        applyColors()
    }

    fileprivate func applyColors() {
        let traits = AppAppearance.resolvedTraits(for: self)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.colors = [
            tint.resolvedColor(with: traits).cgColor,
            tint.withAlphaComponent(0.55).resolvedColor(with: traits).cgColor,
        ]
        CATransaction.commit()
        layer.shadowOpacity = traits.userInterfaceStyle == .dark ? 0.30 : 0.18
    }
}

private final class DashboardSynchronizationView: UIView {
    private let backgroundView = DashboardGradientView(
        colors: { [DashboardPalette.panelStart.resolvedColor(with: $0), DashboardPalette.panelEnd.resolvedColor(with: $0)] },
        startPoint: CGPoint(x: 0, y: 0),
        endPoint: CGPoint(x: 1, y: 1)
    )
    private let symbolContainer = UIView()
    private let symbolView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let detailLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
        applyColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: DashboardSynchronizationView, _) in
            view.applyColors()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setLoading() {
        symbolView.isHidden = true
        spinner.startAnimating()
        detailLabel.text = "Đang lấy dữ liệu mới nhất…"
        accessibilityLabel = "Đồng bộ dữ liệu. Đang lấy dữ liệu mới nhất."
        accessibilityTraits = [.staticText, .updatesFrequently]
    }

    func setSynchronized() {
        spinner.stopAnimating()
        symbolView.isHidden = false
        symbolView.image = UIImage(systemName: "checkmark")
        symbolView.tintColor = DashboardPalette.workAccent
        detailLabel.text = "Dữ liệu đang hiển thị đã được cập nhật."
        accessibilityLabel = "Đồng bộ dữ liệu. Dữ liệu đang hiển thị đã được cập nhật."
        accessibilityTraits = .staticText
    }

    func setError() {
        spinner.stopAnimating()
        symbolView.isHidden = false
        symbolView.image = UIImage(systemName: "exclamationmark")
        symbolView.tintColor = .systemOrange
        detailLabel.text = "Chưa thể đồng bộ. Chạm Làm mới để thử lại."
        accessibilityLabel = "Đồng bộ dữ liệu. Chưa thể đồng bộ. Chạm Làm mới để thử lại."
        accessibilityTraits = .staticText
    }

    private func configure() {
        isAccessibilityElement = true
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.10
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: 6)

        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.layer.cornerRadius = 18
        backgroundView.layer.cornerCurve = .continuous
        backgroundView.clipsToBounds = true
        addSubview(backgroundView)

        symbolContainer.translatesAutoresizingMaskIntoConstraints = false
        symbolContainer.layer.cornerRadius = 18
        symbolContainer.layer.cornerCurve = .continuous

        symbolView.translatesAutoresizingMaskIntoConstraints = false
        symbolView.contentMode = .scaleAspectFit
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.color = DashboardPalette.dutiesAccent
        symbolContainer.addSubview(symbolView)
        symbolContainer.addSubview(spinner)

        let titleLabel = UILabel()
        titleLabel.text = "Đồng bộ dữ liệu"
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textColor = DashboardPalette.primaryText
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0

        detailLabel.font = .preferredFont(forTextStyle: .footnote)
        detailLabel.textColor = DashboardPalette.secondaryText
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.numberOfLines = 0

        let textStack = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        textStack.axis = .vertical
        textStack.spacing = 3

        let contentStack = UIStackView(arrangedSubviews: [symbolContainer, textStack])
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .horizontal
        contentStack.alignment = .center
        contentStack.spacing = 13
        addSubview(contentStack)

        NSLayoutConstraint.activate([
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),
            symbolContainer.widthAnchor.constraint(equalToConstant: 36),
            symbolContainer.heightAnchor.constraint(equalToConstant: 36),
            symbolView.centerXAnchor.constraint(equalTo: symbolContainer.centerXAnchor),
            symbolView.centerYAnchor.constraint(equalTo: symbolContainer.centerYAnchor),
            symbolView.widthAnchor.constraint(equalToConstant: 16),
            symbolView.heightAnchor.constraint(equalToConstant: 16),
            spinner.centerXAnchor.constraint(equalTo: symbolContainer.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: symbolContainer.centerYAnchor),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
    }

    fileprivate func applyColors() {
        let traits = AppAppearance.resolvedTraits(for: self)
        backgroundView.applyColors()
        backgroundView.layer.borderWidth = 1
        backgroundView.layer.borderColor = DashboardPalette.cardBorder.resolvedColor(with: traits).cgColor
        symbolContainer.backgroundColor = DashboardPalette.dutiesAccent.withAlphaComponent(0.12)
        detailLabel.textColor = DashboardPalette.secondaryText.resolvedColor(with: traits)
        layer.shadowOpacity = traits.userInterfaceStyle == .dark ? 0.18 : 0.07
    }
}

private final class DashboardGradientView: UIView {
    private let gradientLayer = CAGradientLayer()
    private let colors: (UITraitCollection) -> [UIColor]

    init(
        colors: @escaping (UITraitCollection) -> [UIColor],
        startPoint: CGPoint,
        endPoint: CGPoint
    ) {
        self.colors = colors
        super.init(frame: .zero)
        gradientLayer.startPoint = startPoint
        gradientLayer.endPoint = endPoint
        layer.insertSublayer(gradientLayer, at: 0)
        applyColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: DashboardGradientView, _) in
            view.applyColors()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer.frame = bounds
        applyColors()
    }

    fileprivate func applyColors() {
        let traits = AppAppearance.resolvedTraits(for: self)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.colors = colors(traits).map(\.cgColor)
        CATransaction.commit()
    }
}

private final class PlaceholderViewController: UIViewController {
    private let message: String
    private let messageLabel = UILabel()

    init(title: String, message: String) {
        self.message = message
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        messageLabel.text = message
        messageLabel.font = .preferredFont(forTextStyle: .body)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textAlignment = .center
        messageLabel.textColor = .secondaryLabel
        messageLabel.numberOfLines = 0
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(messageLabel)
        NSLayoutConstraint.activate([
            messageLabel.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            messageLabel.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    func show(_ destination: NotificationDestination) {
        loadViewIfNeeded()
        messageLabel.text = "\(message)\n\nĐã chuyển đến đúng tab cho mục \(destination.sourceId)."
        messageLabel.accessibilityLabel = "\(message) Đã chuyển đến đúng tab cho thông báo đã chọn."
    }
}
