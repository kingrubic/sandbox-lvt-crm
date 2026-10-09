import Foundation

@MainActor
final class AppContainer {
    let tokenStore: TokenStore
    let convex: ConvexHttpClient
    let authRepository: AuthRepository
    let sessionsRepository: SessionsRepository
    let notificationsRepository: NotificationsRepository
    let dutiesRepository: DutiesRepository
    let workRepository: WorkRepository
    let chatRepository: ChatRepository
    let avatarRepository: AvatarRepository
    let homeroomRepository: HomeroomRepository
    let notificationSync: NotificationSyncService
    let apnsRegistrar: APNsTokenRegistrar

    init() {
        let tokenStore = TokenStore()
        self.tokenStore = tokenStore
        let tokenProvider: @Sendable () -> String? = { tokenStore.accessToken }
        let refreshCredentialsProvider: @Sendable () -> CredentialSnapshot? = { tokenStore.snapshot() }
        let onTokensRefreshed: @Sendable (CredentialSnapshot, String, String) -> Bool = { expected, access, refresh in
            tokenStore.replaceIfCurrent(expected, accessToken: access, refreshToken: refresh)
        }
        let convex = ConvexHttpClient(
            baseURL: ConvexConfig.url,
            tokenProvider: tokenProvider,
            refreshCredentialsProvider: refreshCredentialsProvider,
            onTokensRefreshed: onTokensRefreshed
        )
        self.convex = convex
        sessionsRepository = SessionsRepository(convex: convex)
        let notificationsRepository = NotificationsRepository(convex: convex)
        self.notificationsRepository = notificationsRepository
        dutiesRepository = DutiesRepository(convex: convex, tokenProvider: { tokenStore.accessToken })
        workRepository = WorkRepository(convex: convex, tokenProvider: { tokenStore.accessToken })
        chatRepository = ChatRepository(convex: convex)
        avatarRepository = AvatarRepository(convex: convex, tokenProvider: { tokenStore.accessToken })
        homeroomRepository = HomeroomRepository(convex: convex)
        notificationSync = NotificationSyncService(
            tokenStore: tokenStore,
            repository: notificationsRepository
        )
        let apnsRegistrar = APNsTokenRegistrar(tokenStore: tokenStore, convex: convex)
        self.apnsRegistrar = apnsRegistrar
        authRepository = AuthRepository(
            tokenStore: tokenStore,
            convex: convex,
            beforeSignOut: { accessToken in
                await apnsRegistrar.unregister(accessToken: accessToken)
            }
        )
    }
}
