import Foundation
import Security

struct BackendConfiguration {
    private static let serverURLKey = "lillygram.backendURL"

    static var serverURLString: String {
        get { UserDefaults.standard.string(forKey: serverURLKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: serverURLKey) }
    }

    static var serverURL: URL? {
        guard let url = URL(string: serverURLString),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1"].contains(url.host))
        else { return nil }
        return url
    }
}

enum APIClientError: LocalizedError {
    case backendNotConfigured
    case invalidResponse
    case rejected(status: Int, message: String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .backendNotConfigured:
            "Enter the HTTPS address of your Lillygram backend."
        case .invalidResponse:
            "The backend returned an invalid response."
        case let .rejected(_, message):
            message
        case let .decoding(message):
            "The backend response could not be read: \(message)"
        }
    }
}

actor APIClient {
    private let baseURL: URL
    private let token: String?
    private let session: URLSession

    init(baseURL: URL, token: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    func login(
        username: String,
        password: String,
        verificationCode: String?,
        proxyURL: String?
    ) async throws -> LoginResponse {
        struct Body: Encodable {
            let username: String
            let password: String
            let verificationCode: String?
            let proxyURL: String?
        }
        return try await request(
            path: "v1/auth/login",
            method: "POST",
            body: Body(
                username: username,
                password: password,
                verificationCode: verificationCode?.nilIfBlank,
                proxyURL: proxyURL?.nilIfBlank
            ),
            authenticated: false
        )
    }

    func setTOTPSeed(_ seed: String?) async throws -> Account {
        struct Body: Encodable { let seed: String? }
        return try await request(
            path: "v1/auth/totp-seed",
            method: "PUT",
            body: Body(seed: seed?.nilIfBlank)
        )
    }

    func sessionAccount() async throws -> Account {
        try await request(path: "v1/session")
    }

    func settings() async throws -> BackendSettings {
        try await request(path: "v1/settings")
    }

    func updateProxy(_ proxyURL: String?) async throws -> BackendSettings {
        struct Body: Encodable { let proxyURL: String? }
        return try await request(
            path: "v1/settings/proxy",
            method: "PUT",
            body: Body(proxyURL: proxyURL?.nilIfBlank)
        )
    }

    func feed(cursor: String?) async throws -> Page<InstagramMedia> {
        try await request(path: "v1/feed", query: cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
    }

    func stories() async throws -> [StoryTray] {
        try await request(path: "v1/stories")
    }

    func searchAccounts(_ query: String) async throws -> [ProfileSummary] {
        try await request(
            path: "v1/search/accounts",
            query: [URLQueryItem(name: "q", value: query)]
        )
    }

    func profile(username: String) async throws -> Profile {
        try await request(path: "v1/profiles/\(username.pathComponentEncoded)")
    }

    func profileMedia(username: String, cursor: String?) async throws -> Page<InstagramMedia> {
        try await request(
            path: "v1/profiles/\(username.pathComponentEncoded)/media",
            query: cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? []
        )
    }

    func directThreads() async throws -> [DirectThread] {
        try await request(path: "v1/direct/threads")
    }

    func directMessages(threadID: String) async throws -> [DirectMessage] {
        try await request(path: "v1/direct/threads/\(threadID.pathComponentEncoded)/messages")
    }

    func media(id: String, sharedReel: Bool) async throws -> InstagramMedia {
        try await request(
            path: "v1/media/\(id.pathComponentEncoded)",
            query: [URLQueryItem(name: "shared_reel", value: sharedReel ? "true" : "false")]
        )
    }

    func uploadPost(_ upload: PendingUpload) async throws -> InstagramMedia {
        let response: UploadResponse = try await multipart(
            path: "v1/posts",
            upload: upload,
            fields: ["caption": upload.caption]
        )
        return response.media
    }

    func uploadStory(_ upload: PendingUpload) async throws -> InstagramMedia {
        let response: UploadResponse = try await multipart(
            path: "v1/stories",
            upload: upload,
            fields: [:]
        )
        return response.media
    }

    private func request<Response: Decodable>(
        path: String,
        method: String = "GET",
        query: [URLQueryItem] = []
    ) async throws -> Response {
        try await request(path: path, method: method, body: Optional<EmptyBody>.none, query: query)
    }

    private func request<Body: Encodable, Response: Decodable>(
        path: String,
        method: String,
        body: Body?,
        query: [URLQueryItem] = [],
        authenticated: Bool = true
    ) async throws -> Response {
        var request = URLRequest(url: try endpoint(path: path, query: query))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(body)
        }
        if authenticated, let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return try await perform(request)
    }

    private func multipart<Response: Decodable>(
        path: String,
        upload: PendingUpload,
        fields: [String: String]
    ) async throws -> Response {
        let boundary = "Lillygram-\(UUID().uuidString)"
        var body = Data()
        for (name, value) in fields {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.append("\(value)\r\n")
        }
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"media\"; filename=\"\(upload.filename)\"\r\n")
        body.append("Content-Type: \(upload.mimeType)\r\n\r\n")
        body.append(upload.data)
        body.append("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: try endpoint(path: path))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body
        return try await perform(request)
    }

    private func perform<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIClientError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let message = (try? decoder.decode(APIErrorEnvelope.self, from: data).error.message)
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw APIClientError.rejected(status: http.statusCode, message: message)
        }
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw APIClientError.decoding(error.localizedDescription)
        }
    }

    private func endpoint(path: String, query: [URLQueryItem] = []) throws -> URL {
        let url = baseURL.appending(path: path)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw APIClientError.invalidResponse
        }
        components.queryItems = query.isEmpty ? nil : query
        guard let result = components.url else { throw APIClientError.invalidResponse }
        return result
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { value in
            let container = try value.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = Self.fractionalDateFormatter.date(from: string)
                ?? Self.dateFormatter.date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 date \(string)"
            )
        }
        return decoder
    }

    private static let fractionalDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let dateFormatter = ISO8601DateFormatter()
}

struct PendingUpload: Equatable {
    let data: Data
    let filename: String
    let mimeType: String
    var caption: String = ""
}

private struct EmptyBody: Encodable {}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var pathComponentEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}

enum AppTokenStore {
    private static let service = "com.lillygram.app.backend"
    private static let account = "session-token"

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String) throws {
        clear()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
