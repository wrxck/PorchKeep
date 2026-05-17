import Foundation
import Combine

// EufyBridge: spawns the bundled eufy-security-ws child process, talks to it over
// a local WebSocket, normalises events for the rest of the app, and exposes
// livestream control + an async stream of incoming video/audio buffers.
//
// Authentication: when the eufy cloud demands a 2FA verify code or captcha, the
// bridge publishes an auth challenge that the setup wizard resolves by calling
// submitVerifyCode / submitCaptcha.

@MainActor
final class EufyBridge: ObservableObject {

    enum State: String { case disconnected, connecting, authenticating, ready, error }

    struct AuthChallenge: Equatable {
        enum Kind: Equatable { case verifyCode; case captcha(id: String, imageBase64: String) }
        let kind: Kind
    }

    @Published private(set) var state: State = .disconnected
    @Published var lastError: String? = nil
    @Published var authChallenge: AuthChallenge? = nil
    @Published var discoveredDevices: [DiscoveredDevice] = []
    @Published private(set) var schemaVersion: Int = 0
    @Published private(set) var serverVersion: String = ""

    struct DiscoveredDevice: Identifiable, Hashable {
        var id: String { serialNumber }
        let serialNumber: String
        let name: String
        let model: String?
    }

    struct StreamFrame {
        enum Kind { case video; case audio }
        let kind: Kind
        let codec: String?
        let data: Data
    }

    // Public AsyncStream of normalised doorbell events.
    let events: AsyncStream<DoorbellEvent>
    private let eventsContinuation: AsyncStream<DoorbellEvent>.Continuation

    // Stream of livestream buffers (video first, then audio if available).
    private var liveContinuations: [String: AsyncStream<StreamFrame>.Continuation] = [:]
    private var videoFrameCount: Int = 0
    private var videoByteCount: Int = 0

    // Pending command messageId -> continuation (for results).
    private var pendingResults: [String: CheckedContinuation<[String: Any], Error>] = [:]

    private let logger: AppLogger
    private let keychain: KeychainStore
    private let settings: SettingsStore

    private var bridgeProcess: Process?
    private var bridgeStdoutPipe: Pipe?
    private var bridgeStderrPipe: Pipe?

    private var ws: URLSessionWebSocketTask?
    private var session: URLSession?
    private var reconnectAttempts: Int = 0
    private var reconnectTask: Task<Void, Never>?
    private var stopping: Bool = false
    private var hasReapedOrphans: Bool = false
    private var intentionalChildKill: Bool = false
    private var rateLimited: Bool = false

    init(logger: AppLogger, keychain: KeychainStore, settings: SettingsStore) {
        self.logger = logger
        self.keychain = keychain
        self.settings = settings
        var continuation: AsyncStream<DoorbellEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.eventsContinuation = continuation
    }

    // MARK: - Lifecycle

    func start() async {
        stopping = false
        rateLimited = false
        guard state == .disconnected || state == .error else { return }
        guard let username = keychain.username, let password = keychain.password else {
            logger.error("Bridge.start: missing credentials in Keychain")
            state = .error
            lastError = "Missing credentials. Run setup."
            return
        }
        state = .connecting
        lastError = nil

        do {
            // Reuse a healthy bridge child across WebSocket reconnects: respawning
            // it would force a fresh eufy login (and a fresh captcha) every time.
            if bridgeProcess?.isRunning != true {
                try writeBridgeConfig(username: username, password: password)
                if !hasReapedOrphans {
                    // Done once per app run: reap a bridge orphaned by a
                    // previous app process. We never pkill our own child.
                    await killStaleBridges()
                    hasReapedOrphans = true
                }
                try startBridgeProcess()
            }
            try await connectWithRetry()
        } catch {
            logger.error("Bridge.start failed: \(error)")
            state = .error
            lastError = error.localizedDescription
            scheduleReconnect()
        }
    }

    func stop() async {
        stopping = true
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempts = 0
        ws?.cancel(with: .goingAway, reason: nil)
        ws = nil
        session?.invalidateAndCancel()
        session = nil
        if let p = bridgeProcess, p.isRunning {
            intentionalChildKill = true
            p.terminate()
            await waitForExit(p, timeout: 3.0)
        }
        bridgeProcess = nil
        bridgeStdoutPipe = nil
        bridgeStderrPipe = nil
        state = .disconnected
    }

    /// Synchronous best-effort teardown for app termination — NSApplication's
    /// `applicationWillTerminate` cannot await, and a surviving bridge child
    /// would orphan and hold the port.
    func shutdownNow() {
        stopping = true
        reconnectTask?.cancel()
        ws?.cancel(with: .goingAway, reason: nil)
        if let p = bridgeProcess, p.isRunning {
            intentionalChildKill = true
            p.terminate()
        }
        bridgeProcess = nil
    }

    private func waitForExit(_ p: Process, timeout: Double) async {
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Kill any eufy-security-ws server process left over from a previous run.
    private func killStaleBridges() async {
        let serverPath = resolveBridgeEntry().path
        guard FileManager.default.fileExists(atPath: serverPath) else { return }
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-f", serverPath]
        pkill.standardOutput = FileHandle.nullDevice
        pkill.standardError = FileHandle.nullDevice
        do {
            try pkill.run()
            pkill.waitUntilExit()
            if pkill.terminationStatus == 0 {
                logger.warn("Reaped a stale bridge process holding the port; waiting for the socket to free")
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        } catch {
            logger.warn("killStaleBridges failed: \(error)")
        }
    }

    /// eufy's cloud temporarily blocks an IP after too many login attempts.
    /// When that happens we must stop retrying entirely — every further attempt
    /// extends the block. The user has to wait it out, then retry manually.
    private func handleRateLimited() {
        guard !rateLimited else { return }
        rateLimited = true
        stopping = true
        logger.error("eufy cloud rate-limited this IP — halting all retries")
        lastError = "eufy temporarily blocked this IP after too many sign-in attempts. Quit PorchKeep, wait ~1 hour, then try again."
        state = .error
        authChallenge = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        ws?.cancel(with: .goingAway, reason: nil)
        ws = nil
        session?.invalidateAndCancel()
        session = nil
        if let p = bridgeProcess, p.isRunning {
            intentionalChildKill = true
            p.terminate()
        }
        bridgeProcess = nil
    }

    /// Single point for all connection failures — coalesces into one pending
    /// reconnect so a burst of errors can't spawn a storm of retry chains.
    private func connectionFailed(_ reason: String) {
        guard !stopping else { return }
        logger.error("Bridge connection lost: \(reason)")
        state = .error
        lastError = reason
        ws?.cancel(with: .abnormalClosure, reason: nil)
        ws = nil
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard !stopping else { return }
        reconnectTask?.cancel()
        reconnectAttempts += 1
        let delay = min(30.0, pow(2.0, Double(min(reconnectAttempts, 5))))
        logger.warn("Bridge reconnect in \(Int(delay))s (attempt \(reconnectAttempts))")
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            await self.start()
        }
    }

    // MARK: - Bridge child process

    private func bundledResource(_ name: String) -> URL {
        // In dev (swift run), we look in the Sources/.. Resources dir.
        // In the .app bundle, Bundle.main.resourceURL is Contents/Resources.
        if let res = Bundle.main.resourceURL {
            let candidate = res.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        // Walk up from the executable to find Resources/ alongside Sources/.
        let exec = Bundle.main.bundleURL
        let projectResources = exec.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources").appendingPathComponent(name)
        return projectResources
    }

    private func resolveNodeBinary() -> URL {
        let bundled = bundledResource("bridge/node/bin/node")
        if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        // Fallback: Homebrew / system node.
        for path in ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"] {
            if FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return URL(fileURLWithPath: "/usr/bin/env")
    }

    private func resolveBridgeEntry() -> URL {
        // Default install layout:
        //   Resources/bridge/node_modules/eufy-security-ws/dist/bin/server.js
        let bundled = bundledResource("bridge/node_modules/eufy-security-ws/dist/bin/server.js")
        return bundled
    }

    private func writeBridgeConfig(username: String, password: String) throws {
        let dataDir = settings.bridgeDataDir
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let configURL = dataDir.appendingPathComponent("config.json")
        let config: [String: Any] = [
            "username": username,
            "password": password,
            "country": settings.country,
            "language": "en",
            "trustedDeviceName": "PorchKeep",
            "persistentDir": dataDir.path,
            "p2pConnectionSetup": 0,
            "pollingIntervalMinutes": 10,
            "eventDurationSeconds": 10,
            "acceptInvitations": true,
            // Node 22 removed RSA_PKCS1_PADDING for private decryption; this
            // makes eufy-security-client use its own PKCS1 implementation to
            // decrypt the P2P livestream key.
            "enableEmbeddedPKCS1Support": true
        ]
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted])
        try data.write(to: configURL, options: .atomic)
        logger.info("Bridge config written: \(configURL.path)")
    }

    private func startBridgeProcess() throws {
        let node = resolveNodeBinary()
        let server = resolveBridgeEntry()
        guard FileManager.default.fileExists(atPath: server.path) else {
            throw NSError(domain: "PorchKeep", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bundled eufy-security-ws not found at \(server.path). Run scripts/install-bridge.sh."])
        }
        let configURL = settings.bridgeDataDir.appendingPathComponent("config.json")
        let proc = Process()
        proc.executableURL = node
        proc.arguments = [
            server.path,
            "--config", configURL.path,
            "--port", String(settings.bridgePort),
            "--host", "127.0.0.1"
        ]
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.terminationHandler = { [weak self] p in
            guard let self else { return }
            Task { @MainActor in
                if self.intentionalChildKill {
                    self.intentionalChildKill = false
                    self.logger.info("Bridge child terminated (intentional)")
                    return
                }
                self.logger.warn("Bridge child exited unexpectedly code=\(p.terminationStatus)")
                self.connectionFailed("bridge process exited")
            }
        }
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let self else { return }
            let chunk = h.availableData
            if chunk.isEmpty { return }
            if let s = String(data: chunk, encoding: .utf8) {
                self.logger.writeRaw(.debug, "[bridge.out] " + s.trimmingCharacters(in: .whitespacesAndNewlines))
                let lower = s.lowercased()
                if lower.contains("request limit") || lower.contains("too many request") {
                    Task { @MainActor in self.handleRateLimited() }
                }
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let self else { return }
            let chunk = h.availableData
            if chunk.isEmpty { return }
            if let s = String(data: chunk, encoding: .utf8) {
                self.logger.writeRaw(.debug, "[bridge.err] " + s.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        try proc.run()
        self.bridgeProcess = proc
        self.bridgeStdoutPipe = outPipe
        self.bridgeStderrPipe = errPipe
        logger.info("Bridge child started: \(node.path) \(server.path)")
    }

    // MARK: - WebSocket

    /// Connects the WebSocket, retrying until the bridge child has bound its
    /// port. The bundled bridge needs ~1–2s to start; a single fixed sleep is
    /// unreliable, so the first received frame doubles as a readiness probe.
    private func connectWithRetry() async throws {
        let url = URL(string: "ws://127.0.0.1:\(settings.bridgePort)")!
        logger.info("Bridge WebSocket connecting: \(url)")
        var lastError: Error?
        for attempt in 1...24 {
            if stopping { return }
            let session = URLSession(configuration: .default)
            let task = session.webSocketTask(with: url)
            task.resume()
            do {
                let message = try await receiveFirst(task, seconds: 4)
                self.session = session
                self.ws = task
                self.reconnectAttempts = 0
                logger.info("Bridge WebSocket connected (attempt \(attempt))")
                handleWebSocketMessage(message)
                readLoop()
                return
            } catch {
                lastError = error
                task.cancel(with: .abnormalClosure, reason: nil)
                session.invalidateAndCancel()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        throw lastError ?? NSError(domain: "EufyBridge", code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Bridge did not become reachable"])
    }

    /// Receives the first WebSocket frame, or throws if none arrives in time.
    private func receiveFirst(_ task: URLSessionWebSocketTask, seconds: Double) async throws -> URLSessionWebSocketTask.Message {
        try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask { try await task.receive() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw NSError(domain: "EufyBridge", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: "handshake timeout"])
            }
            guard let result = try await group.next() else {
                throw NSError(domain: "EufyBridge", code: 5)
            }
            group.cancelAll()
            return result
        }
    }

    private func handleWebSocketMessage(_ message: URLSessionWebSocketTask.Message) {
        var text: String? = nil
        switch message {
        case .string(let s): text = s
        case .data(let d): text = String(data: d, encoding: .utf8)
        @unknown default: break
        }
        guard let text,
              let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        dispatch(obj)
    }

    private func readLoop() {
        guard let ws else { return }
        ws.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                Task { @MainActor in
                    self.connectionFailed("websocket: \(err.localizedDescription)")
                }
            case .success(let message):
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.handleWebSocketMessage(message)
                    self.readLoop()
                }
            }
        }
    }

    private func dispatch(_ msg: [String: Any]) {
        let type = msg["type"] as? String ?? ""
        switch type {
        case "version":
            handleVersion(msg)
        case "result":
            handleResult(msg)
        case "event":
            if let inner = msg["event"] as? [String: Any] {
                let src = inner["source"] as? String ?? "?"
                let evName = inner["event"] as? String ?? "?"
                if evName != "livestream video data" && evName != "livestream audio data" {
                    logger.debug("WS event: \(src)/\(evName)")
                }
                handleEvent(inner)
            }
        default:
            logger.debug("WS message type=\(type)")
        }
    }

    private func handleVersion(_ msg: [String: Any]) {
        let maxSchema = (msg["maxSchemaVersion"] as? Int) ?? 21
        let server = (msg["serverVersion"] as? String) ?? "?"
        self.schemaVersion = maxSchema
        self.serverVersion = server
        logger.info("Bridge online server=\(server) schema≤\(maxSchema)")
        Task {
            do {
                _ = try await sendCommand(["command": "set_api_schema", "schemaVersion": min(maxSchema, 21)])
                _ = try await sendCommand(["command": "start_listening"])
                self.state = .authenticating
                _ = try await sendCommand(["command": "driver.connect"])
            } catch {
                logger.error("Handshake failed: \(error)")
                state = .error
                lastError = error.localizedDescription
            }
        }
    }

    private func handleResult(_ msg: [String: Any]) {
        guard let id = msg["messageId"] as? String,
              let cont = pendingResults.removeValue(forKey: id) else { return }
        let success = (msg["success"] as? Bool) ?? false
        if success {
            let result = (msg["result"] as? [String: Any]) ?? [:]
            cont.resume(returning: result)
        } else {
            let code = (msg["errorCode"] as? String) ?? "unknown"
            let m = (msg["message"] as? String) ?? code
            cont.resume(throwing: NSError(domain: "EufyBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: m]))
        }
    }

    private func handleEvent(_ ev: [String: Any]) {
        let source = ev["source"] as? String ?? ""
        let name = ev["event"] as? String ?? ""

        // Harvest the doorbell serial from any event that carries one. Some
        // bridge / firmware combinations never populate the start_listening
        // snapshot, but they DO emit station/device events with a serialNumber
        // (e.g. "station connected"). This is our reliable discovery path.
        if let serial = ev["serialNumber"] as? String, !serial.isEmpty {
            addDiscovered(DiscoveredDevice(serialNumber: serial, name: serial, model: nil))
        }

        // Driver-level auth challenges and lifecycle.
        if source == "driver" {
            switch name {
            case "verify code":
                authChallenge = AuthChallenge(kind: .verifyCode)
                logger.info("Auth: verify code requested")
            case "captcha request":
                let captchaId = (ev["captchaId"] as? String) ?? ""
                let img = (ev["captcha"] as? String) ?? ""
                authChallenge = AuthChallenge(kind: .captcha(id: captchaId, imageBase64: img))
                logger.info("Auth: captcha requested")
            case "connected":
                state = .ready
                reconnectAttempts = 0
                logger.info("Driver connected to Eufy Cloud")
                Task { try? await refreshDevices() }
            case "disconnected":
                state = .disconnected
                logger.warn("Driver disconnected from Eufy Cloud")
                scheduleReconnect()
            case "connection error":
                state = .error
                lastError = (ev["error"] as? String) ?? "connection error"
                logger.error("Driver connection error: \(self.lastError ?? "")")
            default:
                break
            }
            return
        }

        // Some bridge versions report device/station discovery at driver scope
        // and others omit the source — handle "device added" wherever it lands.
        if name == "device added" || name == "station added" {
            handleDeviceAdded(ev)
            return
        }

        // Device-level events (the ones we record).
        if source == "device" {
            let serial = (ev["serialNumber"] as? String) ?? ""
            let stateOn = (ev["state"] as? Bool) ?? true
            switch name {
            case "motion detected":
                emit(.init(type: .motion, serialNumber: serial, timestamp: Date(), isStart: stateOn))
            case "person detected":
                emit(.init(type: .person, serialNumber: serial, timestamp: Date(), isStart: stateOn))
            case "rings":
                emit(.init(type: .ring, serialNumber: serial, timestamp: Date(), isStart: stateOn))
            case "stranger person detected":
                emit(.init(type: .stranger, serialNumber: serial, timestamp: Date(), isStart: stateOn))
            case "livestream started":
                logger.info("Livestream started serial=\(serial)")
                videoFrameCount = 0
                videoByteCount = 0
            case "livestream stopped":
                logger.info("Livestream stopped serial=\(serial) — \(videoFrameCount) video frame(s), \(videoByteCount) bytes")
                liveContinuations[serial]?.finish()
                liveContinuations.removeValue(forKey: serial)
            case "livestream video data":
                if let frame = parseStreamFrame(ev, kind: .video) {
                    videoFrameCount += 1
                    videoByteCount += frame.data.count
                    if videoFrameCount == 1 {
                        let meta = (ev["metadata"] as? [String: Any]) ?? [:]
                        logger.info("First video frame: codec=\(frame.codec ?? "?") bytes=\(frame.data.count) metadata=\(compactJSON(meta))")
                    } else if videoFrameCount % 90 == 0 {
                        logger.debug("video frames=\(videoFrameCount) total=\(videoByteCount)B")
                    }
                    liveContinuations[serial]?.yield(frame)
                } else {
                    logger.warn("livestream video data: buffer parse failed, eventKeys=\(Array(ev.keys))")
                }
            case "livestream audio data":
                if let frame = parseStreamFrame(ev, kind: .audio) {
                    liveContinuations[serial]?.yield(frame)
                }
            default:
                break
            }
            return
        }
    }

    private func emit(_ event: DoorbellEvent) {
        eventsContinuation.yield(event)
    }

    // MARK: - Devices

    /// Parses a device record from either a flat dict (`serialNumber` at top
    /// level) or one nesting a `properties` sub-object — both shapes appear
    /// across eufy-security-ws schema versions.
    func parseDevice(_ d: [String: Any]) -> DiscoveredDevice? {
        let props = d["properties"] as? [String: Any]
        let sn = (d["serialNumber"] as? String)
            ?? (props?["serialNumber"] as? String)
        guard let sn, !sn.isEmpty else { return nil }
        let name = (d["name"] as? String)
            ?? (props?["name"] as? String)
            ?? sn
        let model = (d["model"] as? String) ?? (props?["model"] as? String)
        return DiscoveredDevice(serialNumber: sn, name: name, model: model)
    }

    private func addDiscovered(_ dev: DiscoveredDevice) {
        guard !discoveredDevices.contains(where: { $0.serialNumber == dev.serialNumber }) else { return }
        discoveredDevices.append(dev)
        logger.info("Discovered device: \(dev.name) (\(dev.serialNumber))")
        if settings.knownDeviceSerial.isEmpty {
            settings.knownDeviceSerial = dev.serialNumber
            settings.knownDeviceName = dev.name
        }
    }

    private func handleDeviceAdded(_ ev: [String: Any]) {
        // The device payload may be the event dict itself, or nested.
        let payload = (ev["device"] as? [String: Any])
            ?? (ev["station"] as? [String: Any])
            ?? ev
        if let dev = parseDevice(payload) {
            addDiscovered(dev)
        } else {
            logger.debug("device added: could not parse, keys=\(Array(payload.keys))")
        }
    }

    /// Re-snapshots devices via `start_listening`, after forcing the driver to
    /// reload its cloud data. The driver populates devices asynchronously, so
    /// this retries for a while. A standalone doorbell may surface only as a
    /// station, so stations are used as a fallback selectable.
    func refreshDevices() async throws {
        // Force the driver to (re)pull stations & devices from the eufy cloud.
        _ = try? await sendCommand(["command": "driver.poll_refresh"])

        for attempt in 1...4 {
            let result = try await sendCommand(["command": "start_listening"])
            let state = (result["state"] as? [String: Any]) ?? result
            let devices = (state["devices"] as? [[String: Any]]) ?? []
            let stations = (state["stations"] as? [[String: Any]]) ?? []
            logger.debug("start_listening #\(attempt): devices=\(devices.count) stations=\(stations.count)")
            for d in devices { if let dev = parseDevice(d) { addDiscovered(dev) } }
            for s in stations { if let dev = parseDevice(s) { addDiscovered(dev) } }
            if !discoveredDevices.isEmpty {
                logger.info("Device discovery via snapshot: \(discoveredDevices.count) device(s)")
                return
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        // Not fatal: the snapshot is often empty and devices are instead
        // harvested from incoming station/device events as they arrive.
        logger.info("start_listening snapshot empty — relying on event-harvested serials")
    }

    private func compactJSON(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return "\(obj)" }
        return s.count > 1500 ? String(s.prefix(1500)) + "…" : s
    }

    // MARK: - Auth replies

    func submitVerifyCode(_ code: String) async throws {
        _ = try await sendCommand(["command": "driver.set_verify_code", "verifyCode": code])
        authChallenge = nil
    }

    func submitCaptcha(_ value: String, captchaId: String) async throws {
        _ = try await sendCommand([
            "command": "driver.set_captcha",
            "captchaId": captchaId,
            "captcha": value
        ])
        authChallenge = nil
    }

    // MARK: - Livestream

    func startLivestream(serial: String) throws -> AsyncStream<StreamFrame> {
        // Replace any existing continuation.
        liveContinuations[serial]?.finish()
        var continuation: AsyncStream<StreamFrame>.Continuation!
        let stream = AsyncStream<StreamFrame> { continuation = $0 }
        liveContinuations[serial] = continuation
        Task {
            do {
                _ = try await sendCommand(["command": "device.start_livestream", "serialNumber": serial])
            } catch {
                logger.error("start_livestream failed: \(error)")
                continuation.finish()
                liveContinuations.removeValue(forKey: serial)
            }
        }
        return stream
    }

    func stopLivestream(serial: String) async {
        do {
            _ = try await sendCommand(["command": "device.stop_livestream", "serialNumber": serial])
        } catch {
            logger.warn("stop_livestream error: \(error)")
        }
        liveContinuations[serial]?.finish()
        liveContinuations.removeValue(forKey: serial)
    }

    // MARK: - Stream buffer parsing

    func parseStreamFrame(_ ev: [String: Any], kind: StreamFrame.Kind) -> StreamFrame? {
        let codec = codecName((ev["metadata"] as? [String: Any]), kind: kind)
        guard let bufferAny = ev["buffer"] else { return nil }
        if let b64 = bufferAny as? String, let d = Data(base64Encoded: b64) {
            return StreamFrame(kind: kind, codec: codec, data: d)
        }
        if let obj = bufferAny as? [String: Any] {
            if let dataB64 = obj["data"] as? String, let d = Data(base64Encoded: dataB64) {
                return StreamFrame(kind: kind, codec: codec, data: d)
            }
            if let arr = obj["data"] as? [Int] {
                let bytes = arr.map { UInt8(truncatingIfNeeded: $0) }
                return StreamFrame(kind: kind, codec: codec, data: Data(bytes))
            }
        }
        if let arr = bufferAny as? [Int] {
            let bytes = arr.map { UInt8(truncatingIfNeeded: $0) }
            return StreamFrame(kind: kind, codec: codec, data: Data(bytes))
        }
        return nil
    }

    /// eufy reports the codec as a number (VideoCodec enum: H264=0, H265=1) or
    /// occasionally a string. Normalise to "h264" / "h265" / "aac".
    func codecName(_ metadata: [String: Any]?, kind: StreamFrame.Kind) -> String? {
        guard let m = metadata else { return nil }
        let key = kind == .video ? "videoCodec" : "audioCodec"
        if let s = m[key] as? String { return s.lowercased() }
        if let n = m[key] as? Int {
            if kind == .video { return n == 1 ? "h265" : "h264" }
            return "aac"
        }
        return nil
    }

    // MARK: - Command dispatch

    @discardableResult
    private func sendCommand(_ body: [String: Any]) async throws -> [String: Any] {
        var payload = body
        let id = UUID().uuidString
        payload["messageId"] = id
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let ws else {
            throw NSError(domain: "EufyBridge", code: 2, userInfo: [NSLocalizedDescriptionKey: "WebSocket not connected"])
        }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: Any], Error>) in
            self.pendingResults[id] = cont
            ws.send(.data(data)) { err in
                if let err = err {
                    Task { @MainActor in
                        if let c = self.pendingResults.removeValue(forKey: id) {
                            c.resume(throwing: err)
                        }
                    }
                }
            }
        }
    }
}
