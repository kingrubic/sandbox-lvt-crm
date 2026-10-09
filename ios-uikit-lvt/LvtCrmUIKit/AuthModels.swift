import Foundation

enum MenuAccess: String, Equatable, Sendable {
    case hidden
    case view
    case viewAll = "view_all"
    case supervisor

    static func decode(_ value: Any?) -> MenuAccess {
        guard let raw = value as? String else { return .hidden }
        if raw == "edit" { return .view }
        return MenuAccess(rawValue: raw) ?? .hidden
    }
}

struct UserSession: Equatable, Sendable {
    let userId: String
    let email: String
    let name: String
    let role: String
    let status: String
    let mustChangePassword: Bool
    let departmentName: String?
    let positionName: String?
    let positionLevel: Int?
    let hasAvatar: Bool
    let avatarVersion: String?
    let menuAccess: [String: MenuAccess]

    var isOperationalManager: Bool {
        role == "admin" || role == "moderator"
    }

    var homeroomAccess: MenuAccess { menuAccess["homeroom"] ?? .hidden }
    var canSeeHomeroom: Bool {
        status == "active" && !mustChangePassword && (isOperationalManager || homeroomAccess != .hidden)
    }
    var isHomeroomSupervisor: Bool { !isOperationalManager && homeroomAccess == .supervisor }

    var roleLabel: String {
        switch role {
        case "admin": return "Quản trị viên"
        case "moderator": return "Điều phối viên"
        default: return "Nhân sự"
        }
    }
}

extension UserSession {
    init?(sessionContext result: [String: Any]) {
        guard let user = result["user"] as? [String: Any], !user.isEmpty else { return nil }
        let department = result["department"] as? [String: Any]
        let position = result["position"] as? [String: Any]
        let email = (user["email"] as? String) ?? ""
        let rawMenuAccess = result["menuAccess"] as? [String: Any] ?? [:]
        let menuAccess = rawMenuAccess.reduce(into: [String: MenuAccess]()) { result, entry in
            result[entry.key] = MenuAccess.decode(entry.value)
        }
        let rawName = (user["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.init(
            userId: (user["_id"] as? String) ?? "",
            email: email,
            name: rawName.isEmpty ? email : rawName,
            role: (user["role"] as? String) ?? "user",
            status: (user["status"] as? String) ?? "active",
            mustChangePassword: (user["mustChangePassword"] as? Bool) ?? false,
            departmentName: department?["name"] as? String,
            positionName: position?["name"] as? String,
            positionLevel: position?["level"] as? Int,
            hasAvatar: (user["hasAvatar"] as? Bool) ?? false,
            avatarVersion: user["avatarVersion"] as? String,
            menuAccess: menuAccess
        )
    }
}

enum AuthState: Equatable, Sendable {
    case loading
    case signedOut
    case signedIn(UserSession)
    case mustChangePassword(UserSession)

    var isAuthenticated: Bool {
        switch self {
        case .signedIn, .mustChangePassword: return true
        default: return false
        }
    }

    var session: UserSession? {
        switch self {
        case .signedIn(let session), .mustChangePassword(let session): return session
        default: return nil
        }
    }
}
