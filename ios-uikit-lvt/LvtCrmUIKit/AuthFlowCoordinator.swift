import Combine
import UIKit

@MainActor
final class AuthFlowCoordinator {
    private let window: UIWindow
    private let container: AppContainer
    private var stateObservation: AnyCancellable?
    private var displayedState: AuthState?
    private var pendingDestination: NotificationDestination?

    init(window: UIWindow, container: AppContainer) {
        self.window = window
        self.container = container
    }

    func start() {
        stateObservation = container.authRepository.$state
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                Task { @MainActor in self?.show(state) }
            }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            self?.container.authRepository.failOpenIfStillLoading()
        }
    }

    func open(_ destination: NotificationDestination) {
        pendingDestination = destination
        (window.rootViewController as? RootTabBarController)?.route(destination)
        if window.rootViewController is RootTabBarController {
            pendingDestination = nil
        }
    }

    private func show(_ state: AuthState) {
        guard state != displayedState else { return }
        displayedState = state
        let root: UIViewController
        switch state {
        case .loading:
            root = LoadingViewController()
        case .signedOut:
            container.notificationSync.cancel()
            root = UINavigationController(
                rootViewController: LoginViewController(authRepository: container.authRepository)
            )
        case .mustChangePassword:
            root = UINavigationController(
                rootViewController: ChangePasswordViewController(
                    title: "Đổi mật khẩu bắt buộc",
                    subtitle: "Bạn cần đặt mật khẩu mới trước khi dùng ứng dụng.",
                    authRepository: container.authRepository,
                    allowsCancel: false
                )
            )
        case .signedIn(let session):
            activatePushDelivery()
            let tabBarController = RootTabBarController(
                session: session,
                authRepository: container.authRepository,
                sessionsRepository: container.sessionsRepository,
                notificationsRepository: container.notificationsRepository,
                dutiesRepository: container.dutiesRepository,
                workRepository: container.workRepository,
                chatRepository: container.chatRepository,
                avatarRepository: container.avatarRepository,
                homeroomRepository: container.homeroomRepository
            )
            root = tabBarController
            if let pendingDestination {
                tabBarController.loadViewIfNeeded()
                tabBarController.route(pendingDestination)
                self.pendingDestination = nil
            }
        }
        replaceRoot(with: root)
    }

    private func activatePushDelivery() {
        Task { [container] in
            await NotificationCenterService.requestAuthorizationIfNeeded()
            container.notificationSync.schedule()
            await container.notificationSync.syncNow()
            container.apnsRegistrar.registerForRemoteNotifications()
            await container.apnsRegistrar.sync()
        }
    }

    private func replaceRoot(with viewController: UIViewController) {
        guard window.rootViewController != nil else {
            window.rootViewController = viewController
            return
        }
        UIView.transition(
            with: window,
            duration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.25,
            options: [.transitionCrossDissolve, .allowAnimatedContent],
            animations: { self.window.rootViewController = viewController }
        )
    }
}

private final class LoadingViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        let indicator = UIActivityIndicatorView(style: .large)
        indicator.startAnimating()
        indicator.accessibilityLabel = "Đang kiểm tra phiên đăng nhập"
        let label = UILabel()
        label.text = "Đang kiểm tra phiên đăng nhập"
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.adjustsFontForContentSizeCategory = true
        let stack = UIStackView(arrangedSubviews: [indicator, label])
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.trailingAnchor),
        ])
    }
}
