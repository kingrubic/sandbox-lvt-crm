package lvt.crm

import android.content.Context
import lvt.crm.data.auth.AuthRepository
import lvt.crm.data.chat.ChatRepository
import lvt.crm.data.auth.AvatarRepository
import lvt.crm.data.auth.SessionsRepository
import lvt.crm.data.auth.TokenStore
import lvt.crm.data.convex.ConvexConfig
import lvt.crm.data.convex.ConvexHttpClient
import lvt.crm.data.duties.DutiesRepository
import lvt.crm.data.homeroom.HomeroomRepository
import lvt.crm.data.notifications.NotificationsRepository
import lvt.crm.data.work.WorkRepository
import lvt.crm.push.NotificationScheduler
import lvt.crm.push.FcmTokenRegistrar
import lvt.crm.ui.theme.AppearanceStore

class AppContainer(context: Context) {
    val appContext = context.applicationContext
    val tokenStore = TokenStore(appContext)

    val convex = ConvexHttpClient(
        baseUrl = ConvexConfig.url,
        tokenProvider = { tokenStore.accessToken },
        refreshCredentialsProvider = { tokenStore.snapshot() },
        onTokensRefreshed = { expected, access, refresh ->
            tokenStore.replaceIfCurrent(expected, access, refresh)
        },
    )

    val sessionsRepository = SessionsRepository(convex)
    val fcmTokenRegistrar = FcmTokenRegistrar(appContext, tokenStore, convex)
    val authRepository = AuthRepository(
        tokenStore,
        convex,
        beforeSignOut = { accessToken -> fcmTokenRegistrar.unregister(accessToken) },
        afterAuthenticated = { sessionsRepository.registerCurrentDevice() },
    )
    val dutiesRepository = DutiesRepository(
        convex,
        tokenProvider = { tokenStore.accessToken },
        cacheDir = appContext.cacheDir,
    )
    val notificationsRepository = NotificationsRepository(convex)
    val homeroomRepository = HomeroomRepository(convex, java.io.File(appContext.noBackupFilesDir, "homeroom-pending"))
    val chatRepository = ChatRepository(convex)
    val workRepository = WorkRepository(
        convex,
        tokenProvider = { tokenStore.accessToken },
        cacheDir = appContext.cacheDir,
    )
    val avatarRepository = AvatarRepository(
        convex,
        tokenProvider = { tokenStore.accessToken },
        cacheDir = appContext.cacheDir,
    )
    val notificationScheduler = NotificationScheduler(appContext)
    val appearanceStore = AppearanceStore(appContext)
}
