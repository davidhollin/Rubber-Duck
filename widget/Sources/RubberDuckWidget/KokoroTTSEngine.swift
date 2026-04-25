// Kokoro TTS Engine — Neural TTS via Python sidecar.
//
// Conforms to TTSBackend. Sends text to the Kokoro HTTP server,
// receives WAV audio, plays via AVAudioEngine. Routes to Teensy
// output device when available.

import AVFoundation
import CoreAudio
import Foundation
import Translation

@MainActor
class KokoroTTSEngine {
    let gate = TTSGate()

    /// CoreAudio device name for output routing (e.g. "Teensy MIDI_Audio").
    var outputDeviceName: String?

    /// Master volume (0.0-1.0).
    var volume: Float = DuckConfig.volume

    /// Whether TTS is currently muting the mic.
    var isMuted: Bool { gate.muted }

    /// Serial transport for ESP32 streaming. When set, audio streams over
    /// serial binary protocol instead of playing through AVAudioEngine.
    weak var serialTransport: SerialTransport?

    private weak var kokoroManager: KokoroManager?
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var streamingTask: Task<Void, Never>?
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

        let lang = DuckConfig.kokoroLangCode
        let voice = DuckConfig.kokoroVoice
        let needsTranslation = DuckConfig.kokoroLanguage == .japanese

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            do {
                // Translate to Japanese if needed (Apple on-device Translation)
                var ttsText = cleaned
                if needsTranslation {
                    do {
                        let session = TranslationSession(
                            installedSource: Locale.Language(identifier: "en"),
                            target: Locale.Language(identifier: "ja")
                        )
                        let result = try await session.translate(cleaned)
                        ttsText = result.targetText
                        DuckLog.log("[kokoro-tts] Translated: \(ttsText)")
                    } catch {
                        DuckLog.log("[kokoro-tts] Translation failed, using original: \(error)")
                    }
                }

                // Build request
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.timeoutInterval = 30
                let body = try JSONSerialization.data(withJSONObject: [
                    "text": ttsText,
                    "speed": speed,
                    "voice": voice,
                    "lang": lang,
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
        streamingTask?.cancel()
        streamingTask = nil
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

        do {
            let audioFile = try AVAudioFile(forReading: tmpURL)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: audioFile.processingFormat,
                frameCapacity: AVAudioFrameCount(audioFile.length)
            ) else {
                DuckLog.log("[kokoro-tts] Failed to create PCM buffer")
                try? FileManager.default.removeItem(at: tmpURL)
                finishSession(utteranceID, result: .failed)
                return
            }
            try audioFile.read(into: buffer)
            try? FileManager.default.removeItem(at: tmpURL)

            if isCancelledSync(utteranceID) {
                finishSession(utteranceID, result: .cancelled(stopReason ?? .replaced))
                return
            }

            // Choose playback path: serial (ESP32 speaker) or local (AVAudioEngine)
            if let transport = serialTransport, transport.isConnected {
                streamToSerial(buffer, transport: transport, utteranceID: utteranceID)
            } else {
                playLocally(buffer, utteranceID: utteranceID)
            }

        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            DuckLog.log("[kokoro-tts] Audio playback error: \(error)")
            finishSession(utteranceID, result: .failed)
        }
    }

    // MARK: - Local Playback (AVAudioEngine)

    private func playLocally(_ buffer: AVAudioPCMBuffer, utteranceID: UUID) {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
        engine.mainMixerNode.outputVolume = volume

        // Route to Teensy device if available
        if outputDeviceName != nil,
           let device = AudioDeviceDiscovery.findDuckDevice() {
            var deviceID = device.deviceID
            if let au = engine.outputNode.audioUnit {
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

        do {
            try engine.start()
        } catch {
            DuckLog.log("[kokoro-tts] AVAudioEngine start failed: \(error)")
            finishSession(utteranceID, result: .failed)
            return
        }

        self.audioEngine = engine
        self.playerNode = player

        player.scheduleBuffer(buffer) { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.activeSessionID == utteranceID else { return }
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
    }

    // MARK: - Serial Playback (ESP32 speaker)

    private func streamToSerial(_ buffer: AVAudioPCMBuffer, transport: SerialTransport, utteranceID: UUID) {
        let samples = Self.resampleTo16kMono(buffer, volume: volume)
        guard !samples.isEmpty else {
            DuckLog.log("[kokoro-tts] Resample produced no samples")
            finishSession(utteranceID, result: .failed)
            return
        }

        let engine = self
        streamingTask = Task.detached {
            // Enter audio mode on ESP32
            transport.enterAudioMode()
            transport.sendCommand("A,16000,16,1")

            let targetRate: Double = 16000
            let startTime = ContinuousClock.now
            var totalSent = 0
            let chunkSize = 512  // 512 samples = 1024 bytes, matches firmware

            for offset in stride(from: 0, to: samples.count, by: chunkSize) {
                if Task.isCancelled { break }

                let end = min(offset + chunkSize, samples.count)
                let chunk = samples[offset..<end]

                // Encode Int16 samples to little-endian bytes
                var payload = [UInt8]()
                payload.reserveCapacity(chunk.count * 2)
                for sample in chunk {
                    payload.append(UInt8(truncatingIfNeeded: sample))
                    payload.append(UInt8(truncatingIfNeeded: sample >> 8))
                }

                transport.writeFrame(tag: 0x01, payload: payload)
                totalSent += chunk.count

                // Pace to real-time
                let targetElapsed = Double(totalSent) / targetRate
                let actualElapsed = (ContinuousClock.now - startTime).seconds
                let sleepTime = targetElapsed - actualElapsed
                if sleepTime > 0.001 {
                    try? await Task.sleep(nanoseconds: UInt64(sleepTime * 1_000_000_000))
                }
            }

            DuckLog.log("[kokoro-tts] Streamed \(totalSent) samples to ESP32")

            // End audio mode
            let endPayload = Array("A,0\n".utf8)
            transport.writeFrame(tag: 0x02, payload: endPayload)
            transport.exitAudioMode()

            // Let ESP32 ring buffer drain
            try? await Task.sleep(nanoseconds: 300_000_000)

            await engine.finishSession(utteranceID, result: .finished)
        }
    }

    /// Resample an AVAudioPCMBuffer to 16kHz 16-bit mono Int16 samples.
    private nonisolated static func resampleTo16kMono(_ buffer: AVAudioPCMBuffer, volume: Float) -> [Int16] {
        let format = buffer.format
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return [] }

        let srcRate = format.sampleRate
        let channels = Int(format.channelCount)

        // Read source samples as Float32
        var srcSamples = [Float]()
        srcSamples.reserveCapacity(frameCount)

        if let floatData = buffer.floatChannelData {
            for i in 0..<frameCount {
                var sum: Float = 0
                for ch in 0..<channels {
                    sum += floatData[ch][i]
                }
                srcSamples.append(sum / Float(channels))
            }
        } else if let int16Data = buffer.int16ChannelData {
            for i in 0..<frameCount {
                var sum: Float = 0
                for ch in 0..<channels {
                    sum += Float(int16Data[ch][i]) / 32768.0
                }
                srcSamples.append(sum / Float(channels))
            }
        } else {
            return []
        }

        // Resample to 16kHz using linear interpolation
        let targetRate: Double = 16000
        let ratio = srcRate / targetRate
        let outputCount = Int(Double(frameCount) / ratio)

        var output = [Int16]()
        output.reserveCapacity(outputCount)

        for i in 0..<outputCount {
            let srcIdx = Double(i) * ratio
            let idx0 = Int(srcIdx)
            let frac = Float(srcIdx - Double(idx0))

            let s0 = idx0 < srcSamples.count ? srcSamples[idx0] : 0
            let s1 = (idx0 + 1) < srcSamples.count ? srcSamples[idx0 + 1] : s0
            let interpolated = s0 + frac * (s1 - s0)

            // Kokoro output is already well-normalized, lighter boost than AVSpeechSynthesizer
            let boosted = interpolated * 1.5 * volume
            let clamped = max(-1.0, min(1.0, boosted))
            output.append(Int16(clamped * 32767.0))
        }

        return output
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

// MARK: - ContinuousClock duration extension

private extension Duration {
    var seconds: Double {
        let (s, a) = components
        return Double(s) + Double(a) / 1_000_000_000_000_000_000
    }
}
