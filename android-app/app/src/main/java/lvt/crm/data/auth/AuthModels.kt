package lvt.crm.data.auth

import org.json.JSONObject

enum class MenuAccess(val wireValue: String) {
    Hidden("hidden"),
    View("view"),
    ViewAll("view_all"),
    Supervisor("supervisor");

    companion object {
        fun decode(value: String?): MenuAccess = when (value) {
            "view", "edit" -> View
            "view_all" -> ViewAll
            "supervisor" -> Supervisor
            else -> Hidden
        }
    }
}

/**
 * Session for navigation. Admin/Mod use the same staff menus as normal users in the app.
 */
data class UserSession(
    val userId: String,
    val email: String,
    val name: String,
    val role: String,
    val status: String,
    val mustChangePassword: Boolean = false,
    val departmentName: String? = null,
    val positionName: String? = null,
    val positionLevel: Int? = null,
    val hasAvatar: Boolean = false,
    val avatarVersion: String? = null,
    val menuAccess: Map<String, MenuAccess> = emptyMap(),
) {
    val isOperationalManager: Boolean
        get() = role == "admin" || role == "moderator"

    val homeroomAccess: MenuAccess
        get() = menuAccess["homeroom"] ?: MenuAccess.Hidden

    val canSeeHomeroom: Boolean
        get() = status == "active" && !mustChangePassword &&
            (isOperationalManager || homeroomAccess != MenuAccess.Hidden)

    val isHomeroomSupervisor: Boolean
        get() = !isOperationalManager && homeroomAccess == MenuAccess.Supervisor
}

internal fun decodeUserSession(result: JSONObject): UserSession? {
    val user = result.optJSONObject("user") ?: return null
    if (user.length() == 0) return null
    val rawMenu = result.optJSONObject("menuAccess")
    val menu = buildMap {
        if (rawMenu != null) {
            val keys = rawMenu.keys()
            while (keys.hasNext()) {
                val key = keys.next()
                put(key, MenuAccess.decode(rawMenu.optString(key).takeIf { it.isNotBlank() }))
            }
        }
    }
    return UserSession(
        userId = user.optString("_id"),
        email = user.optString("email"),
        name = user.optString("name").ifBlank { user.optString("email") },
        role = user.optString("role", "user"),
        status = user.optString("status", "active"),
        mustChangePassword = user.optBoolean("mustChangePassword", false),
        departmentName = result.optJSONObject("department")?.optString("name"),
        positionName = result.optJSONObject("position")?.optString("name"),
        positionLevel = result.optJSONObject("position")?.optInt("level"),
        hasAvatar = user.optBoolean("hasAvatar", false),
        avatarVersion = user.optString("avatarVersion").takeIf { it.isNotBlank() },
        menuAccess = menu,
    )
}

sealed interface AuthState {
    data object Loading : AuthState
    data object SignedOut : AuthState
    data class SignedIn(val session: UserSession) : AuthState
    data class MustChangePassword(val session: UserSession) : AuthState
}
