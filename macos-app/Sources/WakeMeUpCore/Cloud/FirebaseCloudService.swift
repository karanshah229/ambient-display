import Foundation
import AppKit
import Combine
import Network

public struct CloudUserInfo: Codable {
    public let uid: String
    public let email: String?
    public let displayName: String?
    public let photoUrl: String?
    public let idToken: String
    public let refreshToken: String
}

public struct CloudDeviceDTO: Codable, Identifiable {
    public var id: String { deviceId }
    public let deviceId: String
    public let deviceName: String
    public let deviceType: String
    public let status: String
    public let lastSeen: String?
    public let activeCanvas: [String: String]?
}

@MainActor
public final class FirebaseCloudService: ObservableObject {
    public static let shared = FirebaseCloudService()

    @Published public private(set) var currentUser: CloudUserInfo? = nil
    @Published public private(set) var isConnected: Bool = false
    @Published public private(set) var registeredDevices: [CloudDeviceDTO] = []
    @Published public private(set) var lastSyncTime: Date? = nil
    @Published public private(set) var syncError: String? = nil

    public struct FirebaseConfig {
        public let projectId: String
        public let apiKey: String
        public let googleClientId: String

        public static func load() -> FirebaseConfig {
            let env = ProcessInfo.processInfo.environment
            var pId = env["FIREBASE_PROJECT_ID"] ?? ""
            var aKey = env["FIREBASE_API_KEY"] ?? ""
            var cId = env["FIREBASE_CLIENT_ID"] ?? ""

            if pId.isEmpty || aKey.isEmpty || cId.isEmpty {
                let currentFileDir = URL(fileURLWithPath: #file)
                    .deletingLastPathComponent() // Cloud
                    .deletingLastPathComponent() // WakeMeUpCore
                    .deletingLastPathComponent() // Sources
                    .deletingLastPathComponent() // macos-app

                let possiblePaths: [String] = [
                    Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") ?? "",
                    (Bundle.main.resourcePath ?? "") + "/GoogleService-Info.plist",
                    FileManager.default.currentDirectoryPath + "/GoogleService-Info.plist",
                    FileManager.default.currentDirectoryPath + "/macos-app/GoogleService-Info.plist",
                    currentFileDir.appendingPathComponent("GoogleService-Info.plist").path
                ].filter { !$0.isEmpty }

                for path in possiblePaths {
                    if FileManager.default.fileExists(atPath: path),
                       let dict = NSDictionary(contentsOfFile: path) as? [String: Any] {
                        if pId.isEmpty, let v = dict["PROJECT_ID"] as? String { pId = v }
                        if aKey.isEmpty, let v = dict["API_KEY"] as? String { aKey = v }
                        if cId.isEmpty, let v = dict["CLIENT_ID"] as? String { cId = v }
                        if !pId.isEmpty && !aKey.isEmpty && !cId.isEmpty { break }
                    }
                }
            }

            return FirebaseConfig(
                projectId: pId,
                apiKey: aKey,
                googleClientId: cId
            )
        }
    }

    public private(set) var config: FirebaseConfig = FirebaseConfig.load()
    public var projectId: String { config.projectId }
    public var apiKey: String { config.apiKey }
    public var googleClientId: String { config.googleClientId }

    private var pollTimer: Timer?
    private var heartbeatTimer: Timer?
    private var lastReceivedCanvasId: String? = nil
    private let urlSession = URLSession.shared
    private var oauthListener: NWListener?

    private init() {
        loadPersistedSession()
        setupDismissalHook()
        if currentUser != nil {
            startSync()
        }
    }

    public var deviceId: String {
        if let stored = AppState.defaultUserDefaults.string(forKey: "WakeMeUp_CloudDeviceId"), !stored.isEmpty {
            return stored
        }
        let rawName = Host.current().localizedName ?? "Mac"
        let clean = rawName.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
        let generated = "machine_\(clean.prefix(20))"
        AppState.defaultUserDefaults.set(generated, forKey: "WakeMeUp_CloudDeviceId")
        return generated
    }


    public var deviceName: String {
        Host.current().localizedName ?? "Mac Workstation"
    }

    // MARK: - Persistence
    private func loadPersistedSession() {
        let defaults = AppState.defaultUserDefaults
        guard let uid = defaults.string(forKey: "WakeMeUp_CloudUID"),
              let idToken = defaults.string(forKey: "WakeMeUp_CloudIdToken"),
              let refreshToken = defaults.string(forKey: "WakeMeUp_CloudRefreshToken") else {
            return
        }
        let email = defaults.string(forKey: "WakeMeUp_CloudEmail")
        let displayName = defaults.string(forKey: "WakeMeUp_CloudDisplayName")
        let photoUrl = defaults.string(forKey: "WakeMeUp_CloudPhotoUrl")

        self.currentUser = CloudUserInfo(
            uid: uid,
            email: email,
            displayName: displayName,
            photoUrl: photoUrl,
            idToken: idToken,
            refreshToken: refreshToken
        )
    }

    private func persistSession(_ user: CloudUserInfo) {
        let defaults = AppState.defaultUserDefaults
        defaults.set(user.uid, forKey: "WakeMeUp_CloudUID")
        defaults.set(user.idToken, forKey: "WakeMeUp_CloudIdToken")
        defaults.set(user.refreshToken, forKey: "WakeMeUp_CloudRefreshToken")
        defaults.set(user.email, forKey: "WakeMeUp_CloudEmail")
        defaults.set(user.displayName, forKey: "WakeMeUp_CloudDisplayName")
        defaults.set(user.photoUrl, forKey: "WakeMeUp_CloudPhotoUrl")
    }

    private func clearPersistedSession() {
        let defaults = AppState.defaultUserDefaults
        defaults.removeObject(forKey: "WakeMeUp_CloudUID")
        defaults.removeObject(forKey: "WakeMeUp_CloudIdToken")
        defaults.removeObject(forKey: "WakeMeUp_CloudRefreshToken")
        defaults.removeObject(forKey: "WakeMeUp_CloudEmail")
        defaults.removeObject(forKey: "WakeMeUp_CloudDisplayName")
        defaults.removeObject(forKey: "WakeMeUp_CloudPhotoUrl")
    }

    // MARK: - Authentication
    public func signInWithGoogleIdToken(_ googleIdToken: String) async throws {
        let url = URL(string: "https://identitytoolkit.googleapis.com/v1/accounts:signInWithIdp?key=\(apiKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "postBody": "id_token=\(googleIdToken)&providerId=google.com",
            "requestUri": "http://localhost",
            "returnIdpCredential": true,
            "returnSecureToken": true
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let errStr = String(data: data, encoding: .utf8) ?? "Authentication failed"
            throw NSError(domain: "FirebaseCloudService", code: 401, userInfo: [NSLocalizedDescriptionKey: errStr])
        }

        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let idToken = json["idToken"] as? String,
           let refreshToken = json["refreshToken"] as? String,
           let uid = json["localId"] as? String {
            let email = json["email"] as? String
            let displayName = json["displayName"] as? String
            let photoUrl = json["photoUrl"] as? String

            let user = CloudUserInfo(
                uid: uid,
                email: email,
                displayName: displayName,
                photoUrl: photoUrl,
                idToken: idToken,
                refreshToken: refreshToken
            )
            self.currentUser = user
            persistSession(user)
            startSync()
        }
    }

    public func signOut() {
        stopSync()
        currentUser = nil
        clearPersistedSession()
        registeredDevices = []
        isConnected = false
    }

    public func refreshIdToken() async -> Bool {
        guard let user = currentUser else { return false }
        let url = URL(string: "https://securetoken.googleapis.com/v1/token?key=\(apiKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "grant_type=refresh_token&refresh_token=\(user.refreshToken)".data(using: .utf8)

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let newIdToken = json["id_token"] as? String,
               let newRefreshToken = json["refresh_token"] as? String {
                let updated = CloudUserInfo(
                    uid: user.uid,
                    email: user.email,
                    displayName: user.displayName,
                    photoUrl: user.photoUrl,
                    idToken: newIdToken,
                    refreshToken: newRefreshToken
                )
                self.currentUser = updated
                persistSession(updated)
                return true
            }
        } catch {
            return false
        }
        return false
    }

    // MARK: - Device Registration & Sync
    public func startSync() {
        guard currentUser != nil else { return }
        stopSync()
        isConnected = true

        Task {
            await registerDevice()
            await fetchDevices()
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.pollDeviceDoc()
            }
        }

        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 45.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.sendHeartbeat()
                await self?.fetchDevices()
            }
        }
    }

    public func stopSync() {
        pollTimer?.invalidate()
        pollTimer = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        isConnected = false
    }

    public func registerDevice() async {
        guard let user = currentUser else { return }
        let url = URL(string: "https://firestore.googleapis.com/v1/projects/\(projectId)/databases/(default)/documents/users/\(user.uid)/devices/\(deviceId)?updateMask.fieldPaths=deviceId&updateMask.fieldPaths=deviceName&updateMask.fieldPaths=deviceType&updateMask.fieldPaths=status&updateMask.fieldPaths=lastSeen")!

        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue("Bearer \(user.idToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let nowIso = ISO8601DateFormatter().string(from: Date())
        let body: [String: Any] = [
            "fields": [
                "deviceId": ["stringValue": deviceId],
                "deviceName": ["stringValue": deviceName],
                "deviceType": ["stringValue": "machine"],
                "status": ["stringValue": "online"],
                "lastSeen": ["timestampValue": nowIso]
            ]
        ]


        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, res) = try await urlSession.data(for: req)
            if let http = res as? HTTPURLResponse, http.statusCode == 401 {
                if await refreshIdToken() {
                    await registerDevice()
                }
            }
        } catch {
            self.syncError = error.localizedDescription
        }
    }

    public func sendHeartbeat() async {
        guard let user = currentUser else { return }
        let url = URL(string: "https://firestore.googleapis.com/v1/projects/\(projectId)/databases/(default)/documents/users/\(user.uid)/devices/\(deviceId)?updateMask.fieldPaths=status&updateMask.fieldPaths=lastSeen")!

        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue("Bearer \(user.idToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let nowIso = ISO8601DateFormatter().string(from: Date())
        let body: [String: Any] = [
            "fields": [
                "status": ["stringValue": "online"],
                "lastSeen": ["timestampValue": nowIso]
            ]
        ]

        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let _ = try await urlSession.data(for: req)
        } catch {}
    }

    public func pollDeviceDoc() async {
        guard let user = currentUser else { return }
        let url = URL(string: "https://firestore.googleapis.com/v1/projects/\(projectId)/databases/(default)/documents/users/\(user.uid)/devices/\(deviceId)")!

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(user.idToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, res) = try await urlSession.data(for: req)
            if let http = res as? HTTPURLResponse {
                if http.statusCode == 401 {
                    if await refreshIdToken() {
                        await pollDeviceDoc()
                    }
                    return
                }
                guard http.statusCode == 200 else { return }
            }

            self.lastSyncTime = Date()
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let fields = json["fields"] as? [String: Any] else { return }

            handleActiveCanvasField(fields["activeCanvas"] as? [String: Any])
        } catch {
            self.syncError = error.localizedDescription
        }
    }

    private func handleActiveCanvasField(_ activeCanvasDict: [String: Any]?) {
        guard let mapValue = activeCanvasDict?["mapValue"] as? [String: Any],
              let canvasFields = mapValue["fields"] as? [String: Any] else {
            // No active canvas in Firestore. If Mac is displaying one that was cloud-triggered, dismiss it.
            if lastReceivedCanvasId != nil && WindowManager.shared.hasActiveMessages() {
                lastReceivedCanvasId = nil
                WindowManager.shared.dismissCanvas(targetDisplayId: "all")
            }
            return
        }

        let typeStr = (canvasFields["type"] as? [String: Any])?["stringValue"] as? String ?? "billboard"
        let titleStr = (canvasFields["title"] as? [String: Any])?["stringValue"] as? String ?? "Ambient Display"
        let subtitleStr = (canvasFields["subtitle"] as? [String: Any])?["stringValue"] as? String
        let mediaUrlStr = (canvasFields["mediaUrl"] as? [String: Any])?["stringValue"] as? String
            ?? (canvasFields["media_url"] as? [String: Any])?["stringValue"] as? String
        let themeStr = (canvasFields["theme"] as? [String: Any])?["stringValue"] as? String
        let dismissPolicyStr = (canvasFields["dismissPolicy"] as? [String: Any])?["stringValue"] as? String
            ?? (canvasFields["dismiss_policy"] as? [String: Any])?["stringValue"] as? String ?? "esc_any"
        let targetDisplayIdStr = (canvasFields["targetDisplayId"] as? [String: Any])?["stringValue"] as? String
            ?? (canvasFields["target_display_id"] as? [String: Any])?["stringValue"] as? String ?? "all"
        let durationSecondsInt = (canvasFields["durationSeconds"] as? [String: Any])?["integerValue"] as? Int

        let canvasIdentifier = "\(typeStr)|\(titleStr)|\(subtitleStr ?? "")|\(mediaUrlStr ?? "")"
        if lastReceivedCanvasId == canvasIdentifier {
            return // Already rendered
        }
        lastReceivedCanvasId = canvasIdentifier

        let resolvedType: CanvasPayloadType
        switch typeStr.lowercased() {
        case "image": resolvedType = .image
        case "video": resolvedType = .video
        case "web", "webview": resolvedType = .webview
        case "sunrise": resolvedType = .sunrise
        default: resolvedType = .billboard
        }

        let policy = DismissPolicy(rawValue: dismissPolicyStr) ?? .escAny

        WindowManager.shared.showCanvas(
            type: resolvedType,
            title: titleStr,
            subtitle: subtitleStr,
            mediaUrl: mediaUrlStr,
            theme: themeStr,
            dismissPolicy: policy,
            targetDisplayId: targetDisplayIdStr,
            durationSeconds: durationSecondsInt
        )
    }

    public func clearActiveCanvasInFirestore() async {
        guard let user = currentUser else { return }
        let url = URL(string: "https://firestore.googleapis.com/v1/projects/\(projectId)/databases/(default)/documents/users/\(user.uid)/devices/\(deviceId)?updateMask.fieldPaths=activeCanvas")!

        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue("Bearer \(user.idToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "fields": [
                "activeCanvas": ["nullValue": NSNull()]
            ]
        ]

        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let _ = try await urlSession.data(for: req)
            lastReceivedCanvasId = nil
        } catch {}
    }

    public func fetchDevices() async {
        guard let user = currentUser else { return }
        let url = URL(string: "https://firestore.googleapis.com/v1/projects/\(projectId)/databases/(default)/documents/users/\(user.uid)/devices")!

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(user.idToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, res) = try await urlSession.data(for: req)
            guard let http = res as? HTTPURLResponse, http.statusCode == 200 else { return }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let docs = json["documents"] as? [[String: Any]] else { return }

            var list: [CloudDeviceDTO] = []
            for doc in docs {
                guard let fields = doc["fields"] as? [String: Any] else { continue }
                let dId = (fields["deviceId"] as? [String: Any])?["stringValue"] as? String ?? ""
                let dName = (fields["deviceName"] as? [String: Any])?["stringValue"] as? String ?? "Unnamed"
                let dType = (fields["deviceType"] as? [String: Any])?["stringValue"] as? String ?? "unknown"
                let dStatus = (fields["status"] as? [String: Any])?["stringValue"] as? String ?? "offline"
                let dLastSeen = (fields["lastSeen"] as? [String: Any])?["timestampValue"] as? String

                list.append(CloudDeviceDTO(
                    deviceId: dId,
                    deviceName: dName,
                    deviceType: dType,
                    status: dStatus,
                    lastSeen: dLastSeen,
                    activeCanvas: nil
                ))
            }
            self.registeredDevices = list
        } catch {}
    }

    private func setupDismissalHook() {
        WindowManager.shared.onCanvasDismissed = { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.clearActiveCanvasInFirestore()
            }
        }
    }

    // MARK: - Google OAuth Loopback Flow
    public func startGoogleOAuthFlow() {
        stopOAuthListener()
        do {
            let tcpOptions = NWProtocolTCP.Options()
            let params = NWParameters(tls: nil, tcp: tcpOptions)
            params.allowLocalEndpointReuse = true
            let port = NWEndpoint.Port(rawValue: 8322)!
            let listener = try NWListener(using: params, on: port)
            self.oauthListener = listener

            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .main)
                Task { @MainActor [weak self] in
                    self?.handleOAuthConnection(connection)
                }
            }
            listener.start(queue: .main)


            let redirectUri = "http://127.0.0.1:8322/oauth2callback".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
            let scope = "openid%20email%20profile"
            let authUrlStr = "https://accounts.google.com/o/oauth2/v2/auth?client_id=\(googleClientId)&redirect_uri=\(redirectUri)&response_type=code&scope=\(scope)"

            if let url = URL(string: authUrlStr) {
                NSWorkspace.shared.open(url)
            }
        } catch {
            self.syncError = "Failed to start OAuth loopback: \(error.localizedDescription)"
        }
    }

    public func stopOAuthListener() {
        oauthListener?.cancel()
        oauthListener = nil
    }

    private func handleOAuthConnection(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            guard let self = self, let data = data, let reqStr = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }

            var authCode: String? = nil
            if let firstLine = reqStr.components(separatedBy: "\r\n").first,
               let urlPart = firstLine.components(separatedBy: " ").dropFirst().first,
               let components = URLComponents(string: urlPart) {
                authCode = components.queryItems?.first(where: { $0.name == "code" })?.value
            }

            let htmlResponse: String
            if let code = authCode {
                htmlResponse = """
                HTTP/1.1 200 OK\r
                Content-Type: text/html; charset=utf-8\r
                Connection: close\r
                \r
                <!DOCTYPE html>
                <html>
                <head><title>Ambient Display Authenticated</title></head>
                <body style="font-family: -apple-system, sans-serif; background: #121212; color: #FFF; text-align: center; padding-top: 80px;">
                    <h1 style="color: #30D158;">✓ Signed In Successfully</h1>
                    <p style="color: #8E8E93; font-size: 16px;">Your Ambient Display workstation is now connected to Firebase.</p>
                    <p style="color: #636366; font-size: 13px;">You can close this tab and return to Ambient Display.</p>
                </body>
                </html>
                """

                Task { @MainActor [weak self] in
                    await self?.exchangeCodeForGoogleTokens(code: code)
                }
            } else {
                htmlResponse = "HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\nAuthorization code not received."
            }

            let respData = Data(htmlResponse.utf8)
            connection.send(content: respData, completion: .contentProcessed { [weak self] _ in
                connection.cancel()
                Task { @MainActor [weak self] in
                    self?.stopOAuthListener()
                }
            })
        }
    }

    public func exchangeCodeForGoogleTokens(code: String) async {
        let tokenUrl = URL(string: "https://oauth2.googleapis.com/token")!
        var req = URLRequest(url: tokenUrl)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = "code=\(code)&client_id=\(googleClientId)&redirect_uri=http://127.0.0.1:8322/oauth2callback&grant_type=authorization_code"
        req.httpBody = body.data(using: .utf8)

        do {
            let (data, res) = try await urlSession.data(for: req)
            guard let http = res as? HTTPURLResponse, http.statusCode == 200 else { return }
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let idToken = json["id_token"] as? String {
                try await signInWithGoogleIdToken(idToken)
            }
        } catch {
            self.syncError = error.localizedDescription
        }
    }
}

