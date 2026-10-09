package lvt.crm.data.auth

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicLong
import lvt.crm.data.convex.ConvexException
import lvt.crm.data.convex.AuthApi
import lvt.crm.data.convex.ConvexHttpClient
import org.json.JSONObject

interface SignInGateway {
    suspend fun signIn(email: String, password: String): Result<UserSession>
    suspend fun requestPasswordReset(email: String): Result<Unit>
}

class AuthRepository(
    private val tokenStore: CredentialStore,
    private val convex: AuthApi,
    private val beforeSignOut: (suspend (String) -> Unit)? = null,
    private val afterAuthenticated: (suspend () -> Result<*>)? = null,
) : SignInGateway {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val _state = MutableStateFlow<AuthState>(AuthState.Loading)
    val state: StateFlow<AuthState> = _state.asStateFlow()
    private val authGeneration = AtomicLong(0)
    private val credentialTransitionLock = Any()

    init {
        scope.launch { restoreSession() }
    }

    suspend fun restoreSession() {
        val generation = authGeneration.get()
        val credentials = tokenStore.snapshot()
        if (credentials == null) {
            synchronized(credentialTransitionLock) {
                if (authGeneration.get() == generation) _state.value = AuthState.SignedOut
            }
            return
        }
        try {
            val session = fetchSession()
            if (session == null) {
                clearCurrentCredentialsAndSignOut(credentials, generation)
            } else {
                publish(session, generation, credentials)
                runCatching { afterAuthenticated?.invoke() }
            }
        } catch (e: Exception) {
            // Keep tokens if network blip; only clear on hard auth failure.
            if (e is ConvexException && (
                    e.code.contains("Unauthenticated", ignoreCase = true) ||
                        e.code.contains("Authentication", ignoreCase = true)
                    )
            ) {
                clearCurrentCredentialsAndSignOut(credentials, generation)
            } else {
                synchronized(credentialTransitionLock) {
                    if (
                        authGeneration.get() == generation &&
                        tokenStore.snapshot() == credentials
                    ) {
                        // Leave the loading state so the user can retry login.
                        _state.value = AuthState.SignedOut
                    }
                }
            }
        }
    }

    override suspend fun signIn(email: String, password: String): Result<UserSession> {
        val normalized = email.trim().lowercase()
        if (normalized.isEmpty() || password.isEmpty()) {
            return Result.failure(IllegalArgumentException("EMAIL_PASSWORD_REQUIRED"))
        }
        val (previousCredentials, previousState, generation, credentialRevision) =
            synchronized(credentialTransitionLock) {
                val credentials = tokenStore.snapshot()
                val state = _state.value
                val nextGeneration = authGeneration.incrementAndGet()
                val nextRevision = tokenStore.invalidatePendingWrites()
                if (credentials != null && state.isAuthenticated()) {
                    _state.value = AuthState.Loading
                }
                SignInAttempt(credentials, state, nextGeneration, nextRevision)
            }
        var credentialsIssued = false
        var issuedCredentials: CredentialSnapshot? = null
        return try {
            val args = JSONObject()
                .put("provider", "password")
                .put(
                    "params",
                    JSONObject()
                        .put("email", normalized)
                        .put("password", password)
                        .put("flow", "signIn"),
                )
            val result = convex.action("auth:signIn", args, authenticated = false)
            val tokens = result.optJSONObject("tokens")
                ?: throw ConvexException("NO_TOKENS", "Đăng nhập không trả về token.")
            val access = tokens.getString("token")
            val refresh = tokens.getString("refreshToken")
            credentialsIssued = synchronized(credentialTransitionLock) {
                authGeneration.get() == generation &&
                    tokenStore.saveIfRevision(credentialRevision, access, refresh)
            }
            if (!credentialsIssued) {
                return Result.failure(ConvexException("SIGN_IN_SUPERSEDED"))
            }
            issuedCredentials = CredentialSnapshot(access, refresh, credentialRevision)

            val session = fetchSession()
                ?: throw ConvexException("NO_SESSION", "Không tải được phiên đăng nhập.")
            if (!publish(session, generation)) {
                return Result.failure(ConvexException("SIGN_IN_SUPERSEDED"))
            }
            runCatching { afterAuthenticated?.invoke() }
            Result.success(session)
        } catch (e: ConvexException) {
            if (previousCredentials != null && previousState.isAuthenticated()) {
                rollbackAccountSwitch(
                    generation,
                    credentialRevision,
                    issuedCredentials,
                    previousCredentials,
                    previousState,
                )
            } else if (credentialsIssued && e.invalidatesCredentials()) {
                issuedCredentials?.let { clearCurrentCredentialsAndSignOut(it, generation) }
            }
            Result.failure(e)
        } catch (e: Exception) {
            if (previousCredentials != null && previousState.isAuthenticated()) {
                rollbackAccountSwitch(
                    generation,
                    credentialRevision,
                    issuedCredentials,
                    previousCredentials,
                    previousState,
                )
            }
            Result.failure(ConvexException("SIGN_IN_FAILED", e.message ?: "SIGN_IN_FAILED"))
        }
    }

    override suspend fun requestPasswordReset(email: String): Result<Unit> {
        val normalized = email.trim().lowercase()
        if (normalized.isEmpty()) {
            return Result.failure(IllegalArgumentException("EMAIL_REQUIRED"))
        }
        return try {
            convex.action(
                "users:requestPasswordReset",
                JSONObject().put("email", normalized),
                authenticated = false,
            )
            Result.success(Unit)
        } catch (e: ConvexException) {
            Result.failure(e)
        } catch (e: Exception) {
            Result.failure(ConvexException("PASSWORD_RESET_FAILED", e.message ?: "PASSWORD_RESET_FAILED"))
        }
    }

    suspend fun changePassword(newPassword: String, currentPassword: String? = null): Result<Unit> {
        val generation = authGeneration.get()
        if (newPassword.length < 8) {
            return Result.failure(ConvexException("PASSWORD_TOO_SHORT", ConvexHttpClient.humanize("PASSWORD_TOO_SHORT")))
        }
        try {
            val args = JSONObject().put("newPassword", newPassword)
            if (!currentPassword.isNullOrBlank()) {
                args.put("currentPassword", currentPassword)
            }
            convex.action("users:changeOwnPassword", args)
        } catch (e: ConvexException) {
            return Result.failure(e)
        } catch (e: Exception) {
            return Result.failure(ConvexException("PASSWORD_CHANGE_FAILED", e.message ?: "PASSWORD_CHANGE_FAILED"))
        }
        return try {
            val session = fetchSession()
            if (session != null) {
                publish(session, generation)
            } else if (authGeneration.get() == generation) {
                // Password changed; force re-login if session vanished
                synchronized(credentialTransitionLock) {
                    if (authGeneration.get() == generation) {
                        authGeneration.incrementAndGet()
                        tokenStore.clear()
                        _state.value = AuthState.SignedOut
                    }
                }
            }
            Result.success(Unit)
        } catch (e: Exception) {
            // The mutation is the commit point. A refresh failure must not be reported as a failed change.
            Result.success(Unit)
        }
    }

    suspend fun refreshSession() {
        val generation = authGeneration.get()
        val credentials = tokenStore.snapshot() ?: return
        try {
            val session = fetchSession() ?: return
            publish(session, generation, credentials)
        } catch (_: Exception) {
            // Avatar/header refresh is best-effort; keep the current signed-in session.
        }
    }

    fun signOut() {
        val accessToken = synchronized(credentialTransitionLock) {
            val captured = tokenStore.accessToken
            authGeneration.incrementAndGet()
            tokenStore.clear()
            _state.value = AuthState.SignedOut
            captured
        }
        if (accessToken.isNullOrBlank()) return
        scope.launch {
            try {
                beforeSignOut?.invoke(accessToken)
            } catch (_: Exception) {
                // Device cleanup is independent from server-side token revocation.
            }
            try {
                convex.actionWithToken("auth:signOut", JSONObject(), accessToken)
            } catch (_: Exception) {
                // Local credentials are already revoked; remote cleanup is best-effort.
            }
        }
    }

    private fun publish(
        session: UserSession,
        generation: Long = authGeneration.get(),
        expectedCredentials: CredentialSnapshot? = null,
    ): Boolean =
        synchronized(credentialTransitionLock) {
            if (
                authGeneration.get() != generation ||
                expectedCredentials != null && tokenStore.snapshot() != expectedCredentials
            ) {
                return@synchronized false
            }
            _state.value = if (session.mustChangePassword) {
                AuthState.MustChangePassword(session)
            } else {
                AuthState.SignedIn(session)
            }
            true
        }

    private fun clearCurrentCredentialsAndSignOut(
        credentials: CredentialSnapshot,
        generation: Long,
    ): Boolean = synchronized(credentialTransitionLock) {
        if (authGeneration.get() != generation) return@synchronized false
        if (!tokenStore.clearIfCurrent(credentials)) return@synchronized false
        authGeneration.incrementAndGet()
        _state.value = AuthState.SignedOut
        true
    }

    private suspend fun fetchSession(): UserSession? {
        val result = convex.query("users:sessionContext")
        return decodeUserSession(result)
    }

    private fun ConvexException.invalidatesCredentials(): Boolean =
        code == "NO_SESSION" ||
            code.contains("Unauthenticated", ignoreCase = true) ||
            code.contains("Authentication", ignoreCase = true) ||
            code == "UNAUTHENTICATED"

    private fun rollbackAccountSwitch(
        generation: Long,
        credentialRevision: Long,
        issuedCredentials: CredentialSnapshot?,
        previousCredentials: CredentialSnapshot,
        previousState: AuthState,
    ) = synchronized(credentialTransitionLock) {
        if (authGeneration.get() != generation) return@synchronized

        val restored = if (issuedCredentials == null) {
            tokenStore.snapshot()?.hasSameTokens(previousCredentials) == true
        } else {
            tokenStore.replaceIfCurrent(
                issuedCredentials,
                previousCredentials.accessToken,
                previousCredentials.refreshToken,
            )
        }
        if (restored) {
            _state.value = previousState
        } else if (tokenStore.clearIfRevision(credentialRevision)) {
            authGeneration.incrementAndGet()
            _state.value = AuthState.SignedOut
        }
    }

    private fun AuthState.isAuthenticated(): Boolean =
        this is AuthState.SignedIn || this is AuthState.MustChangePassword

    private fun CredentialSnapshot.hasSameTokens(other: CredentialSnapshot): Boolean =
        accessToken == other.accessToken && refreshToken == other.refreshToken

    private data class SignInAttempt(
        val previousCredentials: CredentialSnapshot?,
        val previousState: AuthState,
        val generation: Long,
        val credentialRevision: Long,
    )
}
