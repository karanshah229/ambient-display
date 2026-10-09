import Foundation
import AppKit
import Combine
import Network
import FirebaseCore
import FirebaseFirestore
import FirebaseAuth

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
                    .deletingLastPathComponent() // AmbientDisplayCore
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
    public var isConfigured: Bool { !config.projectId.isEmpty && !config.apiKey.isEmpty }

    private var devicesListener: ListenerRegistration?
    private var preferencesListener: ListenerRegistration?
    private var heartbeatTimer: Timer?
    private var tokenRefreshTimer: Timer?
    private var restSyncTimer: Timer?
    private var lastReceivedCanvasId: String? = nil
    private let urlSession = URLSession.shared
    private var oauthListener: NWListener?

    private init() {
        ensureFirebaseConfigured()
        loadPersistedSession()
        setupDismissalHook()
        if currentUser != nil {
            startSync()
        }
    }

    public func ensureFirebaseConfigured() {
        if FirebaseApp.app() == nil {
            let currentFileDir = URL(fileURLWithPath: #file)
                .deletingLastPathComponent() // Cloud
                .deletingLastPathComponent() // AmbientDisplayCore
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
                   let options = FirebaseOptions(contentsOfFile: path) {
                    FirebaseApp.configure(options: options)
                    break
                }
            }

            if FirebaseApp.app() == nil && !projectId.isEmpty && !apiKey.isEmpty {
                let options = FirebaseOptions(googleAppID: "1:229733401659:ios:0b7a7039cd42c6d3e6c81e", gcmSenderID: "229733401659")
                options.projectID = projectId
                options.apiKey = apiKey
                FirebaseApp.configure(options: options)
            }
        }
    }

    public var deviceId: String {
        let defaults = AppState.defaultUserDefaults
        if let stored = defaults.string(forKey: "AmbientDisplay_CloudDeviceId") ?? defaults.string(forKey: "AmbientDisplay_CloudDeviceId"), !stored.isEmpty {
            defaults.set(stored, forKey: "AmbientDisplay_CloudDeviceId")
            return stored
        }
        let rawName = Host.current().localizedName ?? "Mac"
        let clean = rawName.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
        let generated = "machine_\(clean.prefix(20))"
        defaults.set(generated, forKey: "AmbientDisplay_CloudDeviceId")
        return generated
    }


    public var deviceName: String {
        Host.current().localizedName ?? "Mac Workstation"
    }

    // MARK: - Persistence
    private func loadPersistedSession() {
        let defaults = AppState.defaultUserDefaults
        guard let uid = defaults.string(forKey: "AmbientDisplay_CloudUID") ?? defaults.string(forKey: "AmbientDisplay_CloudUID"),
              let idToken = defaults.string(forKey: "AmbientDisplay_CloudIdToken") ?? defaults.string(forKey: "AmbientDisplay_CloudIdToken"),
              let refreshToken = defaults.string(forKey: "AmbientDisplay_CloudRefreshToken") ?? defaults.string(forKey: "AmbientDisplay_CloudRefreshToken") else {
            return
        }
        let email = defaults.string(forKey: "AmbientDisplay_CloudEmail") ?? defaults.string(forKey: "AmbientDisplay_CloudEmail")
        let displayName = defaults.string(forKey: "AmbientDisplay_CloudDisplayName") ?? defaults.string(forKey: "AmbientDisplay_CloudDisplayName")
        let photoUrl = defaults.string(forKey: "AmbientDisplay_CloudPhotoUrl") ?? defaults.string(forKey: "AmbientDisplay_CloudPhotoUrl")

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
        defaults.set(user.uid, forKey: "AmbientDisplay_CloudUID")
        defaults.set(user.idToken, forKey: "AmbientDisplay_CloudIdToken")
        defaults.set(user.refreshToken, forKey: "AmbientDisplay_CloudRefreshToken")
        defaults.set(user.email, forKey: "AmbientDisplay_CloudEmail")
        defaults.set(user.displayName, forKey: "AmbientDisplay_CloudDisplayName")
        defaults.set(user.photoUrl, forKey: "AmbientDisplay_CloudPhotoUrl")
    }

    private func clearPersistedSession() {
        let defaults = AppState.defaultUserDefaults
        defaults.removeObject(forKey: "AmbientDisplay_CloudUID")
        defaults.removeObject(forKey: "AmbientDisplay_CloudIdToken")
        defaults.removeObject(forKey: "AmbientDisplay_CloudRefreshToken")
        defaults.removeObject(forKey: "AmbientDisplay_CloudEmail")
        defaults.removeObject(forKey: "AmbientDisplay_CloudDisplayName")
        defaults.removeObject(forKey: "AmbientDisplay_CloudPhotoUrl")
        defaults.removeObject(forKey: "AmbientDisplay_CloudUID")
        defaults.removeObject(forKey: "AmbientDisplay_CloudIdToken")
        defaults.removeObject(forKey: "AmbientDisplay_CloudRefreshToken")
        defaults.removeObject(forKey: "AmbientDisplay_CloudEmail")
        defaults.removeObject(forKey: "AmbientDisplay_CloudDisplayName")
        defaults.removeObject(forKey: "AmbientDisplay_CloudPhotoUrl")
    }

    // MARK: - Authentication
    public func signInWithGoogleIdToken(_ googleIdToken: String) async throws {
        ensureFirebaseConfigured()
        let credential = GoogleAuthProvider.credential(withIDToken: googleIdToken, accessToken: "")
        _ = try? await Auth.auth().signIn(with: credential)

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
        try? Auth.auth().signOut()
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

    // MARK: - Device Registration & Streaming Sync
    public func startSync() {
        guard let user = currentUser else { return }
        stopSync()
        isConnected = true
        ensureFirebaseConfigured()

        Task {
            _ = await refreshIdToken()
            await registerDevice()
            await fetchDevices()
            await fetchPreferencesViaRest()
        }

        // Proactively refresh ID token every 45 minutes before expiration
        tokenRefreshTimer = Timer.scheduledTimer(withTimeInterval: 2700.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                _ = await self?.refreshIdToken()
            }
        }

        // Single persistent Firestore streaming connection:
        // Listens to all devices in the user's fleet in real time.
        // Pushes updates for fleet discovery AND the activeCanvas for this Mac.
        let db = Firestore.firestore()
        devicesListener = db.collection("users").document(user.uid).collection("devices")
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    if let _ = error {
                        // When native SDK listener encounters permissions or unauthenticated state in SwiftPM,
                        // seamlessly activate REST polling fallback without blocking UI.
                        self.startRestSyncFallback()
                        return
                    }
                    guard let snapshot = snapshot else { return }

                    self.syncError = nil
                    self.lastSyncTime = Date()
                    var list: [CloudDeviceDTO] = []
                    var currentDeviceDoc: DocumentSnapshot? = nil

                    for doc in snapshot.documents {
                        let data = doc.data()
                        let dId = (data["deviceId"] as? String) ?? doc.documentID
                        let dName = (data["deviceName"] as? String) ?? "Unnamed"
                        let dType = (data["deviceType"] as? String) ?? "unknown"
                        let dStatus = (data["status"] as? String) ?? "offline"
                        let dLastSeen: String?
                        if let ts = data["lastSeen"] as? Timestamp {
                            dLastSeen = ISO8601DateFormatter().string(from: ts.dateValue())
                        } else if let str = data["lastSeen"] as? String {
                            dLastSeen = str
                        } else {
                            dLastSeen = nil
                        }

                        list.append(CloudDeviceDTO(
                            deviceId: dId,
                            deviceName: dName,
                            deviceType: dType,
                            status: dStatus,
                            lastSeen: dLastSeen,
                            activeCanvas: nil
                        ))

                        if dId == self.deviceId || doc.documentID == self.deviceId {
                            currentDeviceDoc = doc
                        }
                    }
                    self.registeredDevices = list

                    if let currentDoc = currentDeviceDoc {
                        let activeCanvas = currentDoc.data()?["activeCanvas"] as? [String: Any]
                        self.handleActiveCanvas(activeCanvas)
                    } else {
                        self.handleActiveCanvas(nil)
                    }
                }
            }

        // Persistent Firestore streaming connection for user preferences
        preferencesListener = db.collection("users").document(user.uid)
            .addSnapshotListener { [weak self] snapshot, error in
                if error != nil {
                    Task { @MainActor [weak self] in
                        await self?.fetchPreferencesViaRest()
                    }
                    return
                }
                guard let snapshot = snapshot, snapshot.exists else { return }
                if let data = snapshot.data(), let prefs = data["preferences"] as? [String: Any] {
                    Task { @MainActor in
                        AppState.shared.applyCloudPreferences(prefs)
                    }
                }
            }

        // Heartbeat updates presence status every 60 seconds (writes only, no reads)
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.sendHeartbeat()
            }
        }
    }

    public func startRestSyncFallback() {
        if restSyncTimer != nil { return }
        Task {
            await fetchDevices()
            await fetchPreferencesViaRest()
        }
        restSyncTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.fetchDevices()
                await self?.fetchPreferencesViaRest()
            }
        }
    }

    public func stopSync() {
        devicesListener?.remove()
        devicesListener = nil
        preferencesListener?.remove()
        preferencesListener = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        tokenRefreshTimer?.invalidate()
        tokenRefreshTimer = nil
        restSyncTimer?.invalidate()
        restSyncTimer = nil
        isConnected = false
    }

    public func pushPreferences(_ prefs: [String: Any]) {
        guard let user = currentUser else { return }
        ensureFirebaseConfigured()
        let db = Firestore.firestore()
        let docRef = db.collection("users").document(user.uid)
        var updateData: [String: Any] = [
            "userId": user.uid,
            "preferences": prefs,
            "updatedAt": FieldValue.serverTimestamp()
        ]
        if let email = user.email { updateData["email"] = email }
        if let displayName = user.displayName { updateData["displayName"] = displayName }
        docRef.setData(updateData, merge: true) { [weak self] error in
            if error != nil {
                Task { @MainActor [weak self] in
                    await self?.pushPreferencesViaRest(prefs)
                }
            }
        }
        Task {
            await pushPreferencesViaRest(prefs)
        }
    }

    public func pushPreferencesViaRest(_ prefs: [String: Any]) async {
        guard let user = currentUser else { return }
        let url = URL(string: "https://firestore.googleapis.com/v1/projects/\(projectId)/databases/(default)/documents/users/\(user.uid)?updateMask.fieldPaths=preferences&updateMask.fieldPaths=updatedAt&updateMask.fieldPaths=userId")!
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue("Bearer \(user.idToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var prefsFields: [String: Any] = [:]
        for (k, v) in prefs {
            if let s = v as? String {
                prefsFields[k] = ["stringValue": s]
            } else if let b = v as? Bool {
                prefsFields[k] = ["booleanValue": b]
            } else if let i = v as? Int {
                prefsFields[k] = ["integerValue": "\(i)"]
            } else if let d = v as? Double {
                prefsFields[k] = ["doubleValue": d]
            }
        }

        let nowIso = ISO8601DateFormatter().string(from: Date())
        let body: [String: Any] = [
            "fields": [
                "userId": ["stringValue": user.uid],
                "preferences": [
                    "mapValue": [
                        "fields": prefsFields
                    ]
                ],
                "updatedAt": ["timestampValue": nowIso]
            ]
        ]

        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, res) = try await urlSession.data(for: req)
            if let http = res as? HTTPURLResponse {
                if http.statusCode == 401 {
                    if await refreshIdToken() {
                        await pushPreferencesViaRest(prefs)
                    }
                } else if http.statusCode == 200 {
                    self.syncError = nil
                    self.lastSyncTime = Date()
                }
            }
        } catch {}
    }

    public func fetchPreferencesViaRest() async {
        guard let user = currentUser else { return }
        let url = URL(string: "https://firestore.googleapis.com/v1/projects/\(projectId)/databases/(default)/documents/users/\(user.uid)")!
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(user.idToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, res) = try await urlSession.data(for: req)
            if let http = res as? HTTPURLResponse {
                if http.statusCode == 401 {
                    if await refreshIdToken() {
                        await fetchPreferencesViaRest()
                    }
                    return
                }
                guard http.statusCode == 200 else { return }
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let fields = json["fields"] as? [String: Any],
                  let prefsField = fields["preferences"] as? [String: Any],
                  let prefsMap = prefsField["mapValue"] as? [String: Any],
                  let prefFields = prefsMap["fields"] as? [String: Any] else { return }

            var extractedPrefs: [String: Any] = [:]
            for (key, val) in prefFields {
                if let vMap = val as? [String: Any] {
                    if let s = vMap["stringValue"] { extractedPrefs[key] = s }
                    else if let i = vMap["integerValue"] as? String, let intVal = Int(i) { extractedPrefs[key] = intVal }
                    else if let i = vMap["integerValue"] as? Int { extractedPrefs[key] = i }
                    else if let b = vMap["booleanValue"] { extractedPrefs[key] = b }
                    else if let d = vMap["doubleValue"] { extractedPrefs[key] = d }
                }
            }
            AppState.shared.applyCloudPreferences(extractedPrefs)
            self.lastSyncTime = Date()
            self.syncError = nil
        } catch {}
    }

    public func registerDevice() async {
        guard let user = currentUser else { return }
        ensureFirebaseConfigured()
        let db = Firestore.firestore()
        let docRef = db.collection("users").document(user.uid).collection("devices").document(deviceId)
        let data: [String: Any] = [
            "deviceId": deviceId,
            "deviceName": deviceName,
            "deviceType": "machine",
            "status": "online",
            "lastSeen": FieldValue.serverTimestamp()
        ]
        do {
            try await docRef.setData(data, merge: true)
        } catch {
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
    }

    public func sendHeartbeat() async {
        guard let user = currentUser else { return }
        ensureFirebaseConfigured()
        let db = Firestore.firestore()
        let docRef = db.collection("users").document(user.uid).collection("devices").document(deviceId)
        do {
            try await docRef.setData([
                "status": "online",
                "lastSeen": FieldValue.serverTimestamp()
            ], merge: true)
        } catch {
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

            handleActiveCanvas(fields["activeCanvas"] as? [String: Any])
        } catch {
            self.syncError = error.localizedDescription
        }
    }

    private func handleActiveCanvasField(_ activeCanvasDict: [String: Any]?) {
        handleActiveCanvas(activeCanvasDict)
    }

    private func handleActiveCanvas(_ activeCanvas: [String: Any]?) {
        guard var dict = activeCanvas, !dict.isEmpty else {
            if lastReceivedCanvasId != nil && WindowManager.shared.hasActiveMessages() {
                lastReceivedCanvasId = nil
                WindowManager.shared.dismissCanvas(targetDisplayId: "all")
            }
            return
        }

        // If nullValue is present, document explicitly has null activeCanvas (no canvas active)
        if dict["nullValue"] != nil {
            if lastReceivedCanvasId != nil && WindowManager.shared.hasActiveMessages() {
                lastReceivedCanvasId = nil
                WindowManager.shared.dismissCanvas(targetDisplayId: "all")
            }
            return
        }

        // Unwrap REST mapValue format if present
        if let mapValue = dict["mapValue"] as? [String: Any],
           let fields = mapValue["fields"] as? [String: Any] {
            var extracted: [String: Any] = [:]
            for (key, val) in fields {
                if let vMap = val as? [String: Any] {
                    if let s = vMap["stringValue"] { extracted[key] = s }
                    else if let i = vMap["integerValue"] { extracted[key] = i }
                    else if let b = vMap["booleanValue"] { extracted[key] = b }
                }
            }
            dict = extracted
        }

        // A valid canvas must contain at least an explicit title, type, or media URL
        guard !dict.isEmpty,
              dict["title"] != nil || dict["type"] != nil || dict["mediaUrl"] != nil || dict["media_url"] != nil else {
            if lastReceivedCanvasId != nil && WindowManager.shared.hasActiveMessages() {
                lastReceivedCanvasId = nil
                WindowManager.shared.dismissCanvas(targetDisplayId: "all")
            }
            return
        }

        let typeStr = (dict["type"] as? String) ?? "billboard"
        let titleStr = (dict["title"] as? String) ?? "Ambient Display"
        let subtitleStr = dict["subtitle"] as? String
        let mediaUrlStr = (dict["mediaUrl"] as? String) ?? (dict["media_url"] as? String)
        let themeStr = dict["theme"] as? String
        let dismissPolicyStr = (dict["dismissPolicy"] as? String) ?? (dict["dismiss_policy"] as? String) ?? "esc_any"
        let targetDisplayIdStr = (dict["targetDisplayId"] as? String) ?? (dict["target_display_id"] as? String) ?? "all"
        let durationSecondsInt = (dict["durationSeconds"] as? Int) ?? (dict["duration_seconds"] as? Int)

        let canvasIdentifier = "\(typeStr)|\(titleStr)|\(subtitleStr ?? "")|\(mediaUrlStr ?? "")"
        if lastReceivedCanvasId == canvasIdentifier {
            return
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
        ensureFirebaseConfigured()
        let db = Firestore.firestore()
        let docRef = db.collection("users").document(user.uid).collection("devices").document(deviceId)
        do {
            try await docRef.updateData(["activeCanvas": FieldValue.delete()])
            self.lastReceivedCanvasId = nil
        } catch {
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
    }

    public func fetchDevices() async {
        guard let user = currentUser else { return }
        let url = URL(string: "https://firestore.googleapis.com/v1/projects/\(projectId)/databases/(default)/documents/users/\(user.uid)/devices")!

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(user.idToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, res) = try await urlSession.data(for: req)
            if let http = res as? HTTPURLResponse {
                if http.statusCode == 401 {
                    if await refreshIdToken() {
                        await fetchDevices()
                    }
                    return
                }
                guard http.statusCode == 200 else { return }
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let docs = json["documents"] as? [[String: Any]] else { return }

            var list: [CloudDeviceDTO] = []
            var currentDeviceDocFields: [String: Any]? = nil

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

                if dId == self.deviceId {
                    currentDeviceDocFields = fields
                }
            }
            self.registeredDevices = list
            self.lastSyncTime = Date()
            self.syncError = nil

            if let currentFields = currentDeviceDocFields {
                self.handleActiveCanvas(currentFields["activeCanvas"] as? [String: Any])
            } else {
                self.handleActiveCanvas(nil)
            }
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

