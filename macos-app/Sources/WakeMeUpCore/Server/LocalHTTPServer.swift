import Foundation
import Network
import AppKit

public final class LocalHTTPServer {
    public static let shared = LocalHTTPServer()

    private var listener: NWListener?
    public let port: UInt16
    private let queue = DispatchQueue(label: "com.wakemeup.httpserver", qos: .userInitiated)

    public init(port: UInt16 = 8321) {
        self.port = port
    }

    public func start() {
        guard listener == nil else { return }

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
            
            // Advertise on local network via Bonjour / DNS-SD
            listener.service = NWListener.Service(name: "WakeMeUpMac", type: "_wakemeup._tcp")
            self.listener = listener

            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("[LocalHTTPServer] Running and listening on http://0.0.0.0:\(self.port)")
                case .failed(let error):
                    print("[LocalHTTPServer] Failed with error: \(error)")
                case .cancelled:
                    print("[LocalHTTPServer] Stopped.")
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }

            listener.start(queue: queue)
        } catch {
            print("[LocalHTTPServer] Could not start listener on port \(port): \(error)")
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveData(from: connection)
    }

    private func receiveData(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }

            if let data = content, !data.isEmpty {
                let response = self.processRawHTTPRequest(data, from: connection)
                self.sendHTTPResponse(response, on: connection)
            } else if isComplete || error != nil {
                connection.cancel()
            }
        }
    }

    private func processRawHTTPRequest(_ data: Data, from connection: NWConnection) -> (statusCode: Int, contentType: String, body: Data) {
        guard let requestString = String(data: data, encoding: .utf8) else {
            return (400, "text/plain", Data("Bad Request".utf8))
        }

        let lines = requestString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return (400, "text/plain", Data("Bad Request".utf8))
        }

        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            return (400, "text/plain", Data("Bad Request".utf8))
        }

        let method = parts[0].uppercased()
        let path = parts[1].components(separatedBy: "?")[0]

        // Extract body if present
        var bodyData = Data()
        if let emptyLineIndex = lines.firstIndex(of: "") {
            let bodyLines = lines[(emptyLineIndex + 1)...].joined(separator: "\r\n")
            bodyData = Data(bodyLines.utf8)
        }

        let remoteEndpoint = connection.endpoint
        print("[LocalHTTPServer] \(method) \(path) from \(remoteEndpoint) (body: \(bodyData.count) bytes)")

        return route(method: method, path: path, body: bodyData)
    }

    private func route(method: String, path: String, body: Data) -> (statusCode: Int, contentType: String, body: Data) {
        // Handle CORS Preflight
        if method == "OPTIONS" {
            return (200, "text/plain", Data("OK".utf8))
        }

        switch (method, path) {
        case ("GET", "/api/status"):
            return handleGetStatus()

        case ("POST", "/api/sleep"):
            return handlePostSleep(body: body)

        case ("POST", "/api/wake"):
            return handlePostWake()

        case ("POST", "/api/test"):
            return handlePostTest(body: body)

        case ("POST", "/api/away"):
            return handlePostAway(body: body)

        case ("POST", "/api/preferences"):
            DispatchQueue.main.async {
                PreferencesWindowController.shared.show()
            }
            let json = "{\"status\": \"success\", \"message\": \"Preferences opened\"}".data(using: .utf8)!
            return (200, "application/json", json)

        case ("GET", "/api/config"):
            return handleGetConfig()

        case ("POST", "/api/config"):
            return handlePostConfig(body: body)

        case ("GET", "/api/displays"):
            return handleGetDisplays()

        case ("POST", "/api/message"):
            return handlePostMessage(body: body)

        case ("POST", "/api/message/dismiss"):
            return handlePostDismissMessage(body: body)

        case ("GET", "/api/message/status"):
            return handleGetMessageStatus()

        case ("GET", "/"):
            return handleGetIndex()

        default:
            let errorJson = "{\"error\": \"Not Found\", \"path\": \"\(path)\"}".data(using: .utf8)!
            return (404, "application/json", errorJson)
        }
    }

    // MARK: - Handlers

    private func handleGetStatus() -> (Int, String, Data) {
        let payload: StatusResponsePayload = DispatchQueue.main.sync {
            let appState = AppState.shared
            let session = appState.currentSession

            return StatusResponsePayload(
                state: appState.state.rawValue,
                is_away_mode: appState.isAwayMode,
                is_test_mode: appState.isTestMode,
                bedtime: session?.formattedBedtime,
                target_wake_time: session?.formattedTargetTime,
                remaining_seconds: session?.timeRemaining(at: appState.lastUpdated),
                countdown_text: session?.formattedCountdown(at: appState.lastUpdated),
                screens_count: NSScreen.screens.count,
                power_assertion_active: PowerAssertionManager.shared.isAsserted
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = (try? encoder.encode(payload)) ?? Data()
        return (200, "application/json", data)
    }

    private func handlePostSleep(body: Data) -> (Int, String, Data) {
        let req = (try? JSONDecoder().decode(SleepRequestPayload.self, from: body))

        var bedtime = Date()
        if let epochMs = req?.bedtime_epoch_ms, epochMs > 0 {
            bedtime = Date(timeIntervalSince1970: epochMs / 1000.0)
        }

        let durationMinutes: Double = DispatchQueue.main.sync {
            req?.duration_minutes ?? AppState.shared.defaultSleepMinutes
        }
        let reason = req?.reason ?? "remote_trigger"

        DispatchQueue.main.async {
            AppState.shared.startSleep(
                bedtime: bedtime,
                durationMinutes: durationMinutes,
                reason: reason
            )
        }

        let json = "{\"status\": \"success\", \"message\": \"Sleep session started\", \"duration_minutes\": \(durationMinutes)}".data(using: .utf8)!
        return (200, "application/json", json)
    }

    private func handlePostWake() -> (Int, String, Data) {
        DispatchQueue.main.async {
            AppState.shared.stopSleep()
        }
        let json = "{\"status\": \"success\", \"message\": \"Sleep session stopped\"}".data(using: .utf8)!
        return (200, "application/json", json)
    }

    private func handlePostTest(body: Data) -> (Int, String, Data) {
        let req = try? JSONDecoder().decode(TestRequestPayload.self, from: body)
        let duration = req?.duration_seconds ?? 10

        DispatchQueue.main.async {
            AppState.shared.startTestMode(durationSeconds: duration)
        }

        let json = "{\"status\": \"success\", \"message\": \"Test mode started\", \"duration_seconds\": \(duration)}".data(using: .utf8)!
        return (200, "application/json", json)
    }

    private func handlePostAway(body: Data) -> (Int, String, Data) {
        let req = try? JSONDecoder().decode(AwayRequestPayload.self, from: body)

        DispatchQueue.main.async {
            if let isAway = req?.is_away_mode {
                AppState.shared.isAwayMode = isAway
            } else {
                AppState.shared.toggleAwayMode()
            }
        }

        let json = "{\"status\": \"success\", \"message\": \"Away mode toggled\"}".data(using: .utf8)!
        return (200, "application/json", json)
    }

    private func handleGetConfig() -> (Int, String, Data) {
        let payload: ConfigResponsePayload = DispatchQueue.main.sync {
            let app = AppState.shared
            return ConfigResponsePayload(
                default_sleep_hours: app.defaultSleepHours,
                sleep_window_start_hour: app.sleepWindowStartHour,
                sleep_window_end_hour: app.sleepWindowEndHour,
                auto_push_window_start_hour: app.autoPushWindowStartHour,
                auto_push_window_end_hour: app.autoPushWindowEndHour,
                inactivity_offset_minutes: app.inactivityOffsetMinutes,
                auto_detect_inactivity: app.autoDetectInactivityOffset,
                is_away_mode: app.isAwayMode
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = (try? encoder.encode(payload)) ?? Data()
        return (200, "application/json", data)
    }

    private func handlePostConfig(body: Data) -> (Int, String, Data) {
        guard let req = try? JSONDecoder().decode(ConfigUpdateRequestPayload.self, from: body) else {
            let errorJson = "{\"error\": \"Invalid JSON\"}".data(using: .utf8)!
            return (400, "application/json", errorJson)
        }

        DispatchQueue.main.async {
            let app = AppState.shared
            if let hours = req.default_sleep_hours { app.defaultSleepHours = hours }
            if let swStart = req.sleep_window_start_hour { app.sleepWindowStartHour = swStart }
            if let swEnd = req.sleep_window_end_hour { app.sleepWindowEndHour = swEnd }
            if let apStart = req.auto_push_window_start_hour { app.autoPushWindowStartHour = apStart }
            if let apEnd = req.auto_push_window_end_hour { app.autoPushWindowEndHour = apEnd }
            if let offset = req.inactivity_offset_minutes { app.inactivityOffsetMinutes = offset }
            if let autoDetect = req.auto_detect_inactivity { app.autoDetectInactivityOffset = autoDetect }
            if let away = req.is_away_mode { app.isAwayMode = away }
        }

        let json = "{\"status\": \"success\", \"message\": \"Configuration updated\"}".data(using: .utf8)!
        return (200, "application/json", json)
    }

    private func handleGetIndex() -> (Int, String, Data) {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <title>Wake Me Up — macOS Node</title>
            <style>
                body { font-family: -apple-system, sans-serif; background: #121212; color: #f0f0f0; text-align: center; padding: 40px; }
                .card { background: #1e1e1e; max-width: 500px; margin: 0 auto; padding: 24px; border-radius: 16px; box-shadow: 0 4px 20px rgba(0,0,0,0.5); }
                h1 { color: #ff9f0a; }
                button { background: #32d74b; color: #000; border: none; padding: 12px 24px; font-size: 16px; border-radius: 8px; cursor: pointer; margin: 8px; font-weight: bold; }
                button.stop { background: #ff453a; color: #fff; }
                pre { text-align: left; background: #000; padding: 12px; border-radius: 8px; overflow-x: auto; color: #30d158; }
            </style>
        </head>
        <body>
            <div class="card">
                <h1>Wake Me Up</h1>
                <p>Native macOS Server & Multi-Monitor Display Node</p>
                <div>
                    <button onclick="fetch('/api/test', {method:'POST'}).then(load)">Test Preview (10s)</button>
                    <button onclick="fetch('/api/sleep', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({duration_minutes:450})}).then(load)">Start 7.5h Sleep</button>
                    <button class="stop" onclick="fetch('/api/wake', {method:'POST'}).then(load)">Stop / Wake</button>
                </div>
                <h3>Current Status</h3>
                <pre id="status">Loading...</pre>
            </div>
            <script>
                function load() {
                    fetch('/api/status').then(r => r.json()).then(data => {
                        document.getElementById('status').innerText = JSON.stringify(data, null, 2);
                    });
                }
                load();
                setInterval(load, 2000);
            </script>
        </body>
        </html>
        """
        return (200, "text/html", Data(html.utf8))
    }

    private func handleGetDisplays() -> (Int, String, Data) {
        let payload: DisplaysResponsePayload = DispatchQueue.main.sync {
            let displays = WindowManager.shared.getConnectedDisplays()
            return DisplaysResponsePayload(displays: displays)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = (try? encoder.encode(payload)) ?? Data()
        return (200, "application/json", data)
    }

    private func handlePostMessage(body: Data) -> (Int, String, Data) {
        guard let req = try? JSONDecoder().decode(PostMessageRequestPayload.self, from: body) else {
            let errorJson = "{\"error\": \"Invalid request payload. Expected { text, target_display_id?, duration_seconds? }\"}".data(using: .utf8)!
            return (400, "application/json", errorJson)
        }

        let trimmedText = req.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            let errorJson = "{\"error\": \"Message text cannot be empty\"}".data(using: .utf8)!
            return (400, "application/json", errorJson)
        }

        let activeMsg: ActiveMessageDTO = DispatchQueue.main.sync {
            WindowManager.shared.showMessage(
                text: trimmedText,
                targetDisplayId: req.target_display_id ?? "all",
                durationSeconds: req.duration_seconds
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = (try? encoder.encode(activeMsg)) ?? Data()
        return (200, "application/json", data)
    }

    private func handlePostDismissMessage(body: Data) -> (Int, String, Data) {
        let req = try? JSONDecoder().decode(DismissMessageRequestPayload.self, from: body)
        let target = req?.target_display_id ?? "all"

        DispatchQueue.main.sync {
            WindowManager.shared.dismissMessage(targetDisplayId: target)
        }

        let json = "{\"status\": \"success\", \"message\": \"Message dismissed on target: \(target)\"}".data(using: .utf8)!
        return (200, "application/json", json)
    }

    private func handleGetMessageStatus() -> (Int, String, Data) {
        let payload: MessageStatusResponsePayload = DispatchQueue.main.sync {
            let active = WindowManager.shared.getActiveMessagesList()
            return MessageStatusResponsePayload(active_messages: active)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = (try? encoder.encode(payload)) ?? Data()
        return (200, "application/json", data)
    }

    private func sendHTTPResponse(_ response: (statusCode: Int, contentType: String, body: Data), on connection: NWConnection) {
        let statusText = response.statusCode == 200 ? "OK" : (response.statusCode == 404 ? "Not Found" : "Error")
        var header = "HTTP/1.1 \(response.statusCode) \(statusText)\r\n"
        header += "Content-Type: \(response.contentType)\r\n"
        header += "Content-Length: \(response.body.count)\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
        header += "Access-Control-Allow-Headers: Content-Type\r\n"
        header += "Connection: close\r\n\r\n"

        var fullData = Data(header.utf8)
        fullData.append(response.body)

        connection.send(content: fullData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
