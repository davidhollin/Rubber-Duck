// Kokoro Manager — Python sidecar process lifecycle.
//
// Spawns a lightweight HTTP server (kokoro-server/serve.py) that wraps
// Kokoro TTS. Monitors health, auto-restarts on crash, reports status
// to the UI. The widget is the sole owner — start on launch, stop on quit.

import Foundation

enum KokoroStatus: Equatable {
    case notConfigured   // Python/venv not found
    case starting        // Process spawned, waiting for health
    case downloading     // Model downloading (first run)
    case loading         // Model loading into memory
    case ready           // Accepting /tts requests
    case error(String)   // Something went wrong

    var label: String {
        switch self {
        case .notConfigured: return "Not configured"
        case .starting:      return "Starting..."
        case .downloading:   return "Downloading model..."
        case .loading:       return "Loading voice..."
        case .ready:         return "Ready"
        case .error(let msg): return "Error: \(msg)"
        }
    }

    var isUsable: Bool { self == .ready }
}

@MainActor
class KokoroManager: ObservableObject {
    @Published private(set) var status: KokoroStatus = .starting
    @Published private(set) var port: Int?

    private var process: Process?
    private var healthTimer: Timer?
    private var restartCount = 0
    private let maxRestarts = 3
    private let log = DuckLog.self

    /// The base URL for the sidecar, or nil if not ready.
    var baseURL: URL? {
        guard let port else { return nil }
        return URL(string: "http://127.0.0.1:\(port)")
    }

    // MARK: - Lifecycle

    func start() {
        let venvPath = DuckConfig.kokoroVenvPath
        let pythonPath = "\(venvPath)/bin/python3"

        guard FileManager.default.isExecutableFile(atPath: pythonPath) else {
            log.log("[kokoro] Python not found at \(pythonPath)")
            status = .notConfigured
            return
        }

        // Find serve.py — check bundle resources first, then relative to app
        guard let scriptPath = findServeScript() else {
            log.log("[kokoro] serve.py not found")
            status = .error("serve.py not found")
            return
        }

        // Clean stale port file
        try? FileManager.default.removeItem(at: DuckConfig.kokoroPortFile)

        status = .starting
        restartCount = 0
        spawnProcess(python: pythonPath, script: scriptPath)
    }

    func stop() {
        healthTimer?.invalidate()
        healthTimer = nil
        terminateProcess()
        try? FileManager.default.removeItem(at: DuckConfig.kokoroPortFile)
        port = nil
    }

    // MARK: - Process Management

    private func spawnProcess(python: String, script: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = [script]
        proc.environment = ProcessInfo.processInfo.environment.merging([
            "DUCK_KOKORO_PORT_FILE": DuckConfig.kokoroPortFile.path,
            "KOKORO_VOICE": DuckConfig.kokoroVoice,
            "KOKORO_SPEED": String(DuckConfig.kokoroSpeed),
        ], uniquingKeysWith: { _, new in new })

        // Capture stderr for logging
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = FileHandle.nullDevice

        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            DuckLog.log("[kokoro-py] \(line.trimmingCharacters(in: .whitespacesAndNewlines))")
            // Detect download status from Kokoro/HuggingFace output
            if line.contains("Downloading") || line.contains("download") {
                Task { @MainActor [weak self] in
                    if self?.status != .ready {
                        self?.status = .downloading
                    }
                }
            }
        }

        // Watch for unexpected exits
        proc.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                guard let self, self.process === proc else { return }
                self.log.log("[kokoro] Process exited with status \(proc.terminationStatus)")
                self.process = nil
                self.port = nil

                if self.restartCount < self.maxRestarts {
                    self.restartCount += 1
                    let delay = Double(self.restartCount) * 2.0
                    self.log.log("[kokoro] Restarting in \(delay)s (attempt \(self.restartCount))")
                    self.status = .starting
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        guard let self else { return }
                        let venvPath = DuckConfig.kokoroVenvPath
                        let pythonPath = "\(venvPath)/bin/python3"
                        if let script = self.findServeScript() {
                            self.spawnProcess(python: pythonPath, script: script)
                        }
                    }
                } else {
                    self.status = .error("Crashed too many times")
                }
            }
        }

        do {
            try proc.run()
            self.process = proc
            log.log("[kokoro] Spawned PID \(proc.processIdentifier)")
            startHealthPolling()
        } catch {
            log.log("[kokoro] Failed to spawn: \(error)")
            status = .error("Failed to start: \(error.localizedDescription)")
        }
    }

    private func terminateProcess() {
        guard let proc = process, proc.isRunning else {
            process = nil
            return
        }
        proc.terminationHandler = nil // prevent restart
        proc.terminate()
        // Give it a moment, then force kill
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
            if proc.isRunning {
                proc.interrupt()
            }
        }
        process = nil
    }

    // MARK: - Health Polling

    private func startHealthPolling() {
        healthTimer?.invalidate()
        // Poll every 1s until ready, then every 10s
        healthTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            Task { @MainActor [weak self] in
                await self?.checkHealth(timer: timer)
            }
        }
    }

    private func checkHealth(timer: Timer) async {
        // First, discover the port from the port file
        if port == nil {
            if let portStr = try? String(contentsOf: DuckConfig.kokoroPortFile, encoding: .utf8),
               let p = Int(portStr.trimmingCharacters(in: .whitespacesAndNewlines)) {
                port = p
                log.log("[kokoro] Discovered port \(p)")
            } else {
                return // Still waiting for port file
            }
        }

        guard let url = baseURL?.appendingPathComponent("health") else { return }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let s = json["status"] as? String else { return }

            switch s {
            case "ready":
                if status != .ready {
                    log.log("[kokoro] Status: ready")
                    status = .ready
                    restartCount = 0
                    // Slow down polling now that we're ready
                    timer.invalidate()
                    healthTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] t in
                        Task { @MainActor [weak self] in
                            await self?.checkHealth(timer: t)
                        }
                    }
                }
            case "loading":
                if status != .loading && status != .downloading {
                    status = .loading
                }
            case "downloading":
                status = .downloading
            case "error":
                let msg = json["message"] as? String ?? "Unknown error"
                status = .error(msg)
            default:
                break
            }
        } catch {
            // Connection refused is normal while the server is starting up
            if status == .ready {
                log.log("[kokoro] Lost connection to sidecar")
                status = .starting
            }
        }
    }

    // MARK: - Script Discovery

    private func findServeScript() -> String? {
        // 1. Bundle resources (distributed app)
        if let resourcePath = Bundle.main.resourcePath {
            let bundled = (resourcePath as NSString).appendingPathComponent("kokoro-server/serve.py")
            if FileManager.default.fileExists(atPath: bundled) { return bundled }
        }

        // 2. Relative to app bundle (dev: widget/.build/release/RubberDuckWidget.app)
        var candidate = Bundle.main.bundleURL
        for _ in 0..<10 {
            candidate = candidate.deletingLastPathComponent()
            let script = candidate.appendingPathComponent("kokoro-server/serve.py")
            if FileManager.default.fileExists(atPath: script.path) { return script.path }
            // Also check widget/ subdirectory
            let widgetScript = candidate.appendingPathComponent("widget/kokoro-server/serve.py")
            if FileManager.default.fileExists(atPath: widgetScript.path) { return widgetScript.path }
        }

        return nil
    }
}
