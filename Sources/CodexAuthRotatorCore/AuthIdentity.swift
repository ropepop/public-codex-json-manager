import Foundation

public struct ResolvedAuthIdentity: Hashable, Sendable {
    public let accountID: String
    public let userID: String?
    public let email: String?
    public let planType: String?

    public init(accountID: String, userID: String?, email: String?, planType: String?) {
        self.accountID = accountID
        self.userID = userID
        self.email = email
        self.planType = planType
    }

    public var trackingKey: String {
        if let userID = normalized(userID) {
            return "user:\(userID)|account:\(accountID)"
        }
        if let email = normalizedEmail(email) {
            return "email:\(email)|account:\(accountID)"
        }
        return "account:\(accountID)"
    }
}

public extension StoredAuthPayload {
    func resolvedIdentity() -> ResolvedAuthIdentity? {
        guard let rawAccountID = normalized(tokens?.accountID) else {
            return nil
        }

        let claims = DecodedAuthTokenClaims.decode(from: tokens?.idToken)
            ?? DecodedAuthTokenClaims.decode(from: tokens?.accessToken)

        let accountID = normalized(claims?.auth?.chatGPTAccountID) ?? rawAccountID
        let userID = normalized(claims?.auth?.userID) ?? normalized(claims?.auth?.chatGPTUserID)
        let email = normalizedEmail(claims?.email) ?? normalizedEmail(claims?.profile?.email)
        let planType = normalized(claims?.auth?.chatGPTPlanType)

        return ResolvedAuthIdentity(
            accountID: accountID,
            userID: userID,
            email: email,
            planType: planType
        )
    }
}

private struct DecodedAuthTokenClaims: Decodable {
    let email: String?
    let profile: ProfileClaims?
    let auth: OpenAIAuthClaims?

    enum CodingKeys: String, CodingKey {
        case email
        case profile = "https://api.openai.com/profile"
        case auth = "https://api.openai.com/auth"
    }

    static func decode(from token: String?) -> DecodedAuthTokenClaims? {
        guard let token else {
            return nil
        }

        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else {
            return nil
        }

        let segment = String(parts[1])
        let padding = String(repeating: "=", count: (4 - segment.count % 4) % 4)
        let base64 = segment
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            + padding

        guard let data = Data(base64Encoded: base64) else {
            return nil
        }

        return try? JSONDecoder().decode(DecodedAuthTokenClaims.self, from: data)
    }
}

private struct ProfileClaims: Decodable {
    let email: String?
}

private struct OpenAIAuthClaims: Decodable {
    let chatGPTAccountID: String?
    let chatGPTPlanType: String?
    let chatGPTUserID: String?
    let userID: String?

    enum CodingKeys: String, CodingKey {
        case chatGPTAccountID = "chatgpt_account_id"
        case chatGPTPlanType = "chatgpt_plan_type"
        case chatGPTUserID = "chatgpt_user_id"
        case userID = "user_id"
    }
}

private func normalized(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
        return nil
    }
    return trimmed
}

private func normalizedEmail(_ value: String?) -> String? {
    normalized(value)?.lowercased()
}
