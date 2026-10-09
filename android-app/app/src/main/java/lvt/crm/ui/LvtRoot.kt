package lvt.crm.ui

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Dashboard
import androidx.compose.material.icons.outlined.Forum
import androidx.compose.material.icons.outlined.Groups
import androidx.compose.material.icons.outlined.TaskAlt
import androidx.compose.material.icons.outlined.WorkOutline
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Badge
import androidx.compose.material3.BadgedBox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import lvt.crm.AppContainer
import lvt.crm.R
import lvt.crm.data.auth.AuthState
import lvt.crm.data.notifications.NotificationItem
import lvt.crm.push.NotificationDestination
import lvt.crm.push.NotificationMarkReadWorker
import kotlinx.coroutines.delay
import lvt.crm.ui.auth.ChangePasswordScreen
import lvt.crm.ui.auth.LoginScreen
import lvt.crm.ui.auth.LoginViewModel
import lvt.crm.ui.components.AccountHeaderState
import lvt.crm.ui.components.LocalAccountHeader
import lvt.crm.ui.chat.ChatHubScreen
import lvt.crm.ui.components.accountInitials
import lvt.crm.ui.duties.DutiesTabHost
import lvt.crm.ui.duties.DutiesViewModel
import lvt.crm.ui.duties.DutyListTab
import lvt.crm.ui.home.DashboardScreen
import lvt.crm.ui.home.DashboardViewModel
import lvt.crm.ui.home.PlaceholderScreen
import lvt.crm.ui.homeroom.HomeroomScreen
import lvt.crm.ui.homeroom.HomeroomViewModel
import lvt.crm.ui.notifications.NotificationsScreen
import lvt.crm.ui.notifications.NotificationsViewModel
import lvt.crm.ui.profile.ProfileScreen
import lvt.crm.ui.work.WorkDashboardFilter
import lvt.crm.ui.work.WorkFileOpener
import lvt.crm.ui.work.WorkFilePreviewScreen
import lvt.crm.ui.work.WorkFilePreviewState
import lvt.crm.ui.work.WorkScreen
import lvt.crm.ui.work.WorkViewModel
import lvt.crm.data.convex.ConvexException
import lvt.crm.data.work.WorkApprovalItem
import kotlinx.coroutines.launch

private object Routes {
    const val Overview = "overview"
    const val Notifications = "notifications"
    const val Chat = "chat"
    const val Duties = "duties"
    const val Work = "work"
    const val Homeroom = "homeroom"
    const val Profile = "profile"
}

@Composable
fun LvtRoot(
    container: AppContainer,
    notificationDestination: NotificationDestination?,
    onNotificationDestinationHandled: () -> Unit,
) {
    val authState by container.authRepository.state.collectAsState()
    when (val state = authState) {
        AuthState.Loading -> PlaceholderScreen(title = "CRM Lê Văn Tám", body = "Đang tải…")
        AuthState.SignedOut -> {
            val loginVm: LoginViewModel = viewModel(
                factory = LoginViewModel.factory(container.authRepository),
            )
            LoginScreen(viewModel = loginVm)
        }
        is AuthState.MustChangePassword -> {
            ChangePasswordScreen(
                title = "Đổi mật khẩu bắt buộc",
                subtitle = "Bạn cần đặt mật khẩu mới trước khi dùng ứng dụng.",
                authRepository = container.authRepository,
                allowCancel = false,
                onDone = {},
            )
        }
        is AuthState.SignedIn -> {
            NotificationPermissionAndSync(container)
            MainShell(
                container = container,
                sessionUserId = state.session.userId,
                sessionName = state.session.name,
                sessionEmail = state.session.email,
                role = state.session.role,
                departmentName = state.session.departmentName,
                positionName = state.session.positionName,
                hasAvatar = state.session.hasAvatar,
                avatarVersion = state.session.avatarVersion,
                canSeeHomeroom = state.session.canSeeHomeroom,
                homeroomSupervisor = state.session.isHomeroomSupervisor,
                notificationDestination = notificationDestination,
                onNotificationDestinationHandled = onNotificationDestinationHandled,
                onSignOut = {
                    container.avatarRepository.clearLocal()
                    container.authRepository.signOut()
                    container.notificationScheduler.cancel()
                },
            )
        }
    }
}

@Composable
private fun MainShell(
    container: AppContainer,
    sessionUserId: String,
    sessionName: String,
    sessionEmail: String,
    role: String,
    departmentName: String?,
    positionName: String?,
    hasAvatar: Boolean,
    avatarVersion: String?,
    canSeeHomeroom: Boolean,
    homeroomSupervisor: Boolean,
    notificationDestination: NotificationDestination?,
    onNotificationDestinationHandled: () -> Unit,
    onSignOut: () -> Unit,
) {
    val navController = rememberNavController()
    val backStack by navController.currentBackStackEntryAsState()
    val current = backStack?.destination?.route ?: Routes.Overview
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val fileOpener = remember(container.workRepository) {
        WorkFileOpener(context, container.workRepository)
    }
    val notificationsViewModel: NotificationsViewModel = viewModel(
        factory = NotificationsViewModel.factory(container.notificationsRepository),
    )
    val notificationState by notificationsViewModel.uiState.collectAsState()
    var focusTarget by remember { mutableStateOf<NotificationDestination?>(null) }
    var tabOpenToken by remember { mutableStateOf(0) }
    var dutyOpenTab by remember { mutableStateOf<DutyListTab?>(null) }
    var dutyFilterToken by remember { mutableStateOf(0) }
    var dutiesSkipHub by remember { mutableStateOf(false) }
    var workOpenFilter by remember { mutableStateOf<WorkDashboardFilter?>(null) }
    var workFilterToken by remember { mutableStateOf(0) }
    var fileError by remember { mutableStateOf<String?>(null) }
    var filePreview by remember { mutableStateOf<WorkFilePreviewState?>(null) }
    var openingFile by remember { mutableStateOf(false) }
    var selectedTab by remember { mutableStateOf(Routes.Overview) }
    var chatUnread by remember { mutableIntStateOf(0) }
    val avatarBitmap by container.avatarRepository.bitmap.collectAsState()

    LaunchedEffect(sessionUserId) {
        while (true) {
            runCatching { container.chatRepository.unreadTotal() }
                .onSuccess { chatUnread = it }
            delay(12_000)
        }
    }

    LaunchedEffect(sessionUserId, hasAvatar, avatarVersion) {
        container.avatarRepository.sync(sessionUserId, hasAvatar, avatarVersion)
    }

    val tabs = buildList {
        add(Triple(Routes.Overview, R.string.nav_overview, Icons.Outlined.Dashboard))
        if (canSeeHomeroom) add(Triple(Routes.Homeroom, R.string.nav_homeroom, Icons.Outlined.Groups))
        add(Triple(Routes.Chat, R.string.nav_chat, Icons.Outlined.Forum))
        add(Triple(Routes.Duties, R.string.nav_duties, Icons.Outlined.WorkOutline))
        add(Triple(Routes.Work, R.string.nav_work, Icons.Outlined.TaskAlt))
    }
    val mainTabRoutes = tabs.mapTo(mutableSetOf()) { it.first }
    val highlightedTab = if (current in mainTabRoutes) current else selectedTab

    LaunchedEffect(current) {
        if (current in mainTabRoutes) selectedTab = current
    }

    fun navigateToTab(route: String, restore: Boolean = true, extra: () -> Unit = {}) {
        selectedTab = route
        extra()
        navController.navigate(route) {
            popUpTo(navController.graph.findStartDestination().id) {
                saveState = restore
            }
            launchSingleTop = true
            restoreState = restore
        }
    }

    fun openNotifications() {
        if (current != Routes.Notifications) {
            navController.navigate(Routes.Notifications) {
                launchSingleTop = true
            }
        }
    }

    fun openProfile() {
        if (current != Routes.Profile) {
            navController.navigate(Routes.Profile) {
                launchSingleTop = true
            }
        }
    }

    val accountHeader = AccountHeaderState(
        unreadCount = notificationState.unreadCount,
        initials = accountInitials(sessionName, sessionEmail),
        avatarBitmap = avatarBitmap,
        onOpenNotifications = { openNotifications() },
        onOpenProfile = { openProfile() },
    )

    fun openDocument(document: WorkApprovalItem) {
        if (openingFile) return
        openingFile = true
        fileError = null
        scope.launch {
            runCatching { fileOpener.download(document) }
                .onSuccess { file ->
                    filePreview = WorkFilePreviewState(document = document, file = file)
                }
                .onFailure { failure ->
                    fileError = (failure as? ConvexException)?.message
                        ?: failure.message
                        ?: "Không thể mở tệp công văn."
                }
            openingFile = false
        }
    }

    fun openNotification(item: NotificationItem) {
        val destination = NotificationDestination(
            kind = item.kind,
            sourceType = item.sourceType,
            sourceId = item.sourceId,
            notificationKey = item.key,
        )
        if (destination.opensChat) {
            focusTarget = destination
            selectedTab = Routes.Chat
            navController.navigate(Routes.Chat) { launchSingleTop = true }
            return
        }
        if (destination.route == Routes.Duties) dutiesSkipHub = true
        focusTarget = destination
        selectedTab = destination.route
        navController.navigate(destination.route) {
            launchSingleTop = true
        }
    }

    LaunchedEffect(notificationDestination) {
        val destination = notificationDestination ?: return@LaunchedEffect
        if (destination.opensChat) {
            focusTarget = destination
            selectedTab = Routes.Chat
            navController.navigate(Routes.Chat) { launchSingleTop = true }
        } else {
            if (destination.route == Routes.Duties) dutiesSkipHub = true
            focusTarget = destination
            selectedTab = destination.route
            navController.navigate(destination.route) {
                launchSingleTop = true
            }
        }
        destination.notificationKey?.let { key ->
            runCatching { container.notificationsRepository.markRead(key) }
                .onFailure {
                    runCatching { NotificationMarkReadWorker.enqueue(container.appContext, key) }
                        .onFailure { enqueueError ->
                            Log.e("LvtNotifications", "Mark-read retry scheduling failed", enqueueError)
                        }
                }
            notificationsViewModel.refresh()
        }
        onNotificationDestinationHandled()
    }

    Box(modifier = Modifier.fillMaxSize()) {
    CompositionLocalProvider(LocalAccountHeader provides accountHeader) {
    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        bottomBar = {
            NavigationBar {
                tabs.forEach { (route, labelRes, icon) ->
                    NavigationBarItem(
                        selected = highlightedTab == route,
                        onClick = {
                            tabOpenToken += 1
                            focusTarget = null
                            navigateToTab(route) {
                                if (route == Routes.Duties) {
                                    dutiesSkipHub = false
                                    dutyOpenTab = null
                                }
                            }
                        },
                        icon = {
                            if (route == Routes.Chat && chatUnread > 0) {
                                BadgedBox(
                                    badge = {
                                        Badge {
                                            Text(if (chatUnread > 99) "99+" else chatUnread.toString())
                                        }
                                    },
                                ) {
                                    Icon(icon, contentDescription = stringResource(labelRes))
                                }
                            } else {
                                Icon(icon, contentDescription = stringResource(labelRes))
                            }
                        },
                        label = { Text(stringResource(labelRes)) },
                    )
                }
            }
        },
    ) { padding ->
        if (fileError != null) {
            AlertDialog(
                onDismissRequest = { fileError = null },
                title = { Text("Không mở được tệp") },
                text = { Text(fileError.orEmpty()) },
                confirmButton = {
                    TextButton(onClick = { fileError = null }) { Text("Đóng") }
                },
            )
        }
        NavHost(
            navController = navController,
            startDestination = Routes.Overview,
            modifier = Modifier.padding(padding),
        ) {
            composable(Routes.Overview) {
                val vm: DashboardViewModel = viewModel(
                    factory = DashboardViewModel.factory(
                        container.dutiesRepository,
                        container.workRepository,
                    ),
                )
                DashboardScreen(
                    viewModel = vm,
                    tabOpenToken = tabOpenToken,
                    onOpenDuties = { tab ->
                        focusTarget = null
                        navigateToTab(Routes.Duties) {
                            dutiesSkipHub = true
                            dutyOpenTab = tab
                            dutyFilterToken += 1
                        }
                    },
                    onOpenWork = { filter ->
                        focusTarget = null
                        navigateToTab(Routes.Work) {
                            workOpenFilter = filter
                            workFilterToken += 1
                        }
                    },
                )
            }
            composable(Routes.Notifications) {
                NotificationsScreen(
                    viewModel = notificationsViewModel,
                    onOpenItem = ::openNotification,
                    tabOpenToken = tabOpenToken,
                    onBack = { navController.popBackStack() },
                )
            }
            if (canSeeHomeroom) {
                composable(Routes.Homeroom) {
                    val vm: HomeroomViewModel = viewModel(
                        key = "homeroom-$sessionUserId-$homeroomSupervisor-$role",
                        factory = HomeroomViewModel.factory(
                            container.homeroomRepository,
                            homeroomSupervisor,
                        ),
                    )
                    HomeroomScreen(vm, canImport = role == "admin" || role == "moderator" || homeroomSupervisor, canManage = role == "admin" || role == "moderator")
                }
            }
            composable(Routes.Chat) {
                val chatFocus = focusTarget?.takeIf { it.opensChat }
                ChatHubScreen(
                    repository = container.chatRepository,
                    openKind = chatFocus?.chatKind,
                    openEntityId = chatFocus?.sourceId,
                    openToken = chatFocus?.let { it.notificationKey ?: it.sourceId },
                    onOpenWork = { documentId ->
                        focusTarget = NotificationDestination(
                            kind = "work",
                            sourceType = "document",
                            sourceId = documentId,
                            notificationKey = "chat-work-$documentId-${System.currentTimeMillis()}",
                        )
                        navigateToTab(Routes.Work)
                    },
                    onOpenDuty = { dutyId ->
                        dutiesSkipHub = true
                        focusTarget = NotificationDestination(
                            kind = "duty",
                            sourceType = "duty",
                            sourceId = dutyId,
                            notificationKey = "chat-duty-$dutyId-${System.currentTimeMillis()}",
                        )
                        navigateToTab(Routes.Duties)
                    },
                    onUnread = { chatUnread = it },
                )
            }
            composable(Routes.Duties) {
                val vm: DutiesViewModel = viewModel(
                    factory = DutiesViewModel.factory(container.dutiesRepository, sessionUserId),
                )
                DutiesTabHost(
                    viewModel = vm,
                    dutiesRepository = container.dutiesRepository,
                    chatRepository = container.chatRepository,
                    focusId = focusTarget
                        ?.takeIf { it.route == Routes.Duties }
                        ?.sourceId,
                    openChat = focusTarget?.opensChat == true && focusTarget?.route == Routes.Duties,
                    focusToken = focusTarget
                        ?.takeIf { it.route == Routes.Duties }
                        ?.let { it.notificationKey ?: it.sourceId },
                    tabOpenToken = tabOpenToken,
                    openTab = dutyOpenTab,
                    openFilterToken = dutyFilterToken,
                    skipHub = dutiesSkipHub,
                )
            }
            composable(Routes.Work) {
                val vm: WorkViewModel = viewModel(
                    factory = WorkViewModel.factory(container.workRepository),
                )
                WorkScreen(
                    viewModel = vm,
                    chatRepository = container.chatRepository,
                    focusId = focusTarget
                        ?.takeIf { it.route == Routes.Work }
                        ?.sourceId,
                    openChat = focusTarget?.opensChat == true && focusTarget?.route == Routes.Work,
                    focusToken = focusTarget
                        ?.takeIf { it.route == Routes.Work }
                        ?.let { it.notificationKey ?: it.sourceId },
                    tabOpenToken = tabOpenToken,
                    openFilter = workOpenFilter,
                    openFilterToken = workFilterToken,
                    onOpenDocument = ::openDocument,
                )
            }
            composable(Routes.Profile) {
                ProfileScreen(
                    name = sessionName,
                    email = sessionEmail,
                    role = role,
                    departmentName = departmentName,
                    positionName = positionName,
                    avatarRepository = container.avatarRepository,
                    authRepository = container.authRepository,
                    sessionsRepository = container.sessionsRepository,
                    appearanceStore = container.appearanceStore,
                    onSignOut = onSignOut,
                    onBack = { navController.popBackStack() },
                )
            }
        }
    }
    }

        if (openingFile && filePreview == null) {
            AlertDialog(
                onDismissRequest = {},
                title = { Text("Đang tải tệp…") },
                text = { CircularProgressIndicator() },
                confirmButton = {},
            )
        }
        filePreview?.let { preview ->
            WorkFilePreviewScreen(
                preview = preview,
                onBack = { filePreview = null },
                onOpenExternally = {
                    runCatching { fileOpener.openExternally(preview.document, preview.file) }
                        .onFailure { failure ->
                            fileError = (failure as? ConvexException)?.message
                                ?: failure.message
                                ?: "Không có ứng dụng nào mở được tệp này."
                        }
                },
            )
        }
    }
}

@Composable
private fun NotificationPermissionAndSync(container: AppContainer) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) {
        runCatching { container.notificationScheduler.syncNow() }
            .onFailure { Log.e("LvtNotifications", "Immediate sync scheduling failed", it) }
    }

    DisposableEffect(container, lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_START) {
                runCatching { container.notificationScheduler.syncNow() }
                    .onFailure { Log.e("LvtNotifications", "Foreground sync scheduling failed", it) }
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    LaunchedEffect(container) {
        runCatching { container.notificationScheduler.schedule() }
            .onFailure { Log.e("LvtNotifications", "Notification scheduling failed", it) }
        runCatching { container.fcmTokenRegistrar.sync() }
            .onFailure { Log.e("LvtNotifications", "FCM token sync failed", it) }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.POST_NOTIFICATIONS,
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            val preferences = context.getSharedPreferences(
                "lvt_notification_permission",
                Context.MODE_PRIVATE,
            )
            if (!preferences.getBoolean("requested", false)) {
                preferences.edit().putBoolean("requested", true).apply()
                permissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
            }
        }
    }
}
