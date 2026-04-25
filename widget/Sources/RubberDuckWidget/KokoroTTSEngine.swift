// Kokoro TTS Engine — Neural TTS via Python sidecar.
//
// Conforms to TTSBackend. Sends text to the Kokoro HTTP server,
// receives WAV audio, plays via AVAudioEngine. Routes to Teensy
// output device when available.

import AVFoundation
import CoreAudio
import Foundation

@MainActor
class KokoroTTSEngine {
    let gate = TTSGate()

    /// CoreAudio device name for output routing (e.g. "Teensy MIDI_Audio").
    var outputDeviceName: String?

    /// Master volume (0.0-1.0).
    var volume: Float = DuckConfig.volume

    /// Whether TTS is currently muting the mic.
    var isMuted: Bool { gate.muted }

    private weak var kokoroManager: KokoroManager?
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var activeSessionID: UUID?
    private var activeCompletion: TTSPlaybackCompletion?
    private var stopReason: TTSStopReason?

    init(manager: KokoroManager) {
        self.kokoroManager = manager
    }

    // MARK: - Text Preprocessing (shared with TTSEngine)

    private func stripMarkdown(_ text: String) -> String {
        var cleaned = text
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "#", with: "")
        cleaned = String(cleaned.unicodeScalars.filter { scalar in
            scalar.properties.isEmoji == false || scalar.value < 0x80
        })
        return cleaned
    }

    private static let pronunciations: [(word: String, phoneme: String)] = [
        ("Ahab", "Ayhab"),
        ("Claude", "Klawd"),
    ]

    private func applyPronunciations(_ text: String) -> String {
        var result = text
        for entry in Self.pronunciations {
            result = result.replacingOccurrences(of: entry.word, with: entry.phoneme, options: .caseInsensitive)
        }
        return result
    }

    // MARK: - TTSBackend

    func play(_ text: String, utteranceID: UUID, skipChirpWait: Bool = false,
              completion: @escaping TTSPlaybackCompletion) {
        guard !text.isEmpty else { return }

        guard let manager = kokoroManager, manager.status.isUsable,
              let baseURL = manager.baseURL else {
            // Kokoro not ready — signal failure so SpeechService can use speech bubble
            DuckLog.log("[kokoro-tts] Not ready, signaling failure")
            completion(utteranceID, .failed)
            return
        }

        DuckLog.log("[kokoro-tts] \(text)")

        let cleaned = applyPronunciations(stripMarkdown(text))
        gate.muted = true
        activeSessionID = utteranceID
        activeCompletion = completion
        stopReason = nil

        let url = baseURL.appendingPathComponent("tts")
        let speed = DuckConfig.kokoroSpeed

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            do {
                // Build request
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.timeoutInterval = 30
                let body = try JSONSerialization.data(withJSONObject: [
                    "text": cleaned,
                    "speed": speed,
                ] as [String: Any])
                request.httpBody = body

                // Check if cancelled before network call
                if await self.isCancelled(utteranceID) {
                    await self.finishSession(utteranceID, result: .cancelled(.replaced))
                    return
                }

                // Fetch WAV from sidecar
                let (data, response) = try await URLSession.shared.data(for: request)

                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    DuckLog.log("[kokoro-tts] Server returned non-200")
                    await self.finishSession(utteranceID, result: .failed)
                    return
                }

                if await self.isCancelled(utteranceID) {
                    await self.finishSession(utteranceID, result: .cancelled(.replaced))
                    return
                }

                // Decode WAV and play
                await self.playWAVData(data, utteranceID: utteranceID)

            } catch {
                DuckLog.log("[kokoro-tts] Request failed: \(error)")
                await self.finishSession(utteranceID, result: .failed)
            }
        }
    }

    func stopPlayback(reason: TTSStopReason) {
        guard activeSessionID != nil else { return }
        stopReason = reason
        playerNode?.stop()
        audioEngine?.stop()
        if let id = activeSessionID {
            finishSession(id, result: .cancelled(reason))
        }
    }

    // MARK: - Audio Playback

    private func playWAVData(_ data: Data, utteranceID: UUID) {
        // Write WAV to temp file so AVAudioFile can read it
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("duck-kokoro-\(utteranceID.uuidString).wav")
        do {
            try data.write(to: tmpURL)
        } catch {
            DuckLog.log("[kokoro-tts] Failed to write temp WAV: \(error)")
            finishSession(utteranceID, result: .failed)
            return
        }

        defer {
            try? FileManager.default.removeItem(at: tmpURL)
        }

        do {
            let audioFile = try AVAudioFile(forReading: tmpURL)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: audioFile.processingFormat,
                frameCapacity: AVAudioFrameCount(audioFile.length)
            ) else {
                DuckLog.log("[kokoro-tts] Failed to create PCM buffer")
                finishSession(utteranceID, result: .failed)
                return
            }
            try audioFile.read(into: buffer)

            if isCancelledSync(utteranceID) {
                finishSession(utteranceID, result: .cancelled(stopReason ?? .replaced))
                return
            }

            // Set up AVAudioEngine
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
            engine.mainMixerNode.outputVolume = volume

            // Route to Teensy device if available
            if outputDeviceName != nil,
               let device = AudioDeviceDiscovery.findDuckDevice() {
                var deviceID = device.deviceID
                let outputNode = engine.outputNode
                if let au = outputNode.audioUnit {
                    AudioUnitSetProperty(
                        au,
                        kAudioOutputUnitProperty_CurrentDevice,
                        kAudioUnitScope_Global,
                        0,
                        &deviceID,
                        UInt32(MemoryLayout<AudioDeviceID>.size)
                    )
                    DuckLog.log("[kokoro-tts] Routing to device: \(device.name)")
                }
            }

            try engine.start()

            self.audioEngine = engine
            self.playerNode = player

            // Schedule buffer and wait for completion
            player.scheduleBuffer(buffer) { [weak self] in
                // Completion fires on audio render thread
                DispatchQueue.main.async {
                    guard let self, self.activeSessionID == utteranceID else { return }
                    // Small delay after playback (matches TTSEngine behavior)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        if self.activeSessionID == utteranceID {
                            self.audioEngine?.stop()
                            self.audioEngine = nil
                            self.playerNode = nil
                            let result: TTSPlaybackResult = self.stopReason.map { .cancelled($0) } ?? .finished
                            self.finishSession(utteranceID, result: result)
                        }
                    }
                }
            }
            player.play()

        } catch {
            DuckLog.log("[kokoro-tts] Audio playback error: \(error)")
            finishSession(utteranceID, result: .failed)
        }
    }

    // MARK: - Session Management

    private func finishSession(_ sessionID: UUID, result: TTSPlaybackResult) {
        guard activeSessionID == sessionID else { return }
        let completion = activeCompletion
        activeSessionID = nil
        activeCompletion = nil
        stopReason = nil
        gate.muted = false
        completion?(sessionID, result)
    }

    private func isCancelled(_ sessionID: UUID) async -> Bool {
        await MainActor.run { stopReason != nil || activeSessionID != sessionID }
    }

    private func isCancelledSync(_ sessionID: UUID) -> Bool {
        stopReason != nil || activeSessionID != sessionID
    }
}
