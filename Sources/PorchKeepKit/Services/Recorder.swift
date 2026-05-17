import Foundation
import Combine

// Recorder spawns ffmpeg, pipes elementary-stream H.264 (and best-effort audio)
// data from the EufyBridge, writes a .mp4 and thumbnail into the archive, then
// records a JSON sidecar so the archive can survive iCloud offloading.

@MainActor
final class Recorder: ObservableObject {

    @Published private(set) var isRecording: Bool = false
    @Published private(set) var lastCaptureStart: Date? = nil

    private let logger: AppLogger
    private let archive: ArchiveStore
    private let settings: SettingsStore
    private let backup: BackupCoordinator

    private var currentSerial: String?
    private var lastCaptureEndedAt: Date?

    init(logger: AppLogger, archive: ArchiveStore, settings: SettingsStore, backup: BackupCoordinator) {
        self.logger = logger
        self.archive = archive
        self.settings = settings
        self.backup = backup
    }

    func captureEvent(_ event: DoorbellEvent, bridge: EufyBridge) async {
        guard !isRecording else {
            logger.debug("Recorder already busy, skipping new event")
            return
        }
        // Cooldown: don't start a fresh clip immediately after the last one —
        // a single long motion would otherwise spawn back-to-back recordings.
        if let last = lastCaptureEndedAt {
            let gap = Date().timeIntervalSince(last)
            let cooldown = TimeInterval(settings.captureCooldownSeconds)
            if gap < cooldown {
                logger.info("Recorder cooldown active (\(Int(cooldown - gap))s left) — skipping \(event.type.rawValue)")
                return
            }
        }
        isRecording = true
        lastCaptureStart = event.timestamp
        currentSerial = event.serialNumber
        defer {
            isRecording = false
            currentSerial = nil
        }

        let stem = filenameStem(for: event)
        let clipsDir = settings.clipsDir
        do {
            try FileManager.default.createDirectory(at: clipsDir, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create clips dir: \(error)")
            return
        }
        let mp4URL = clipsDir.appendingPathComponent(stem + ".mp4")
        let thumbURL = clipsDir.appendingPathComponent(stem + ".jpg")
        let sidecarURL = clipsDir.appendingPathComponent(stem + ".json")

        // Open livestream and spawn ffmpeg.
        let frames: AsyncStream<EufyBridge.StreamFrame>
        do {
            frames = try bridge.startLivestream(serial: event.serialNumber)
        } catch {
            logger.error("Livestream start failed: \(error)")
            return
        }

        let started = Date()
        let proc = Process()
        let ffmpeg = FFmpeg.binaryURL()
        proc.executableURL = ffmpeg
        proc.arguments = [
            "-loglevel", "error",
            "-fflags", "+genpts+discardcorrupt",
            // Declare an input framerate so the raw H.264 demuxer assigns
            // clean monotonic timestamps (see LiveStreamer for the rationale).
            "-r", String(settings.streamFrameRate),
            "-f", "h264",
            "-i", "pipe:0",
            "-c:v", "copy",
            "-movflags", "+faststart",
            "-an",
            "-y",
            mp4URL.path
        ]
        let inputPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inputPipe
        proc.standardError = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            if !chunk.isEmpty, let s = String(data: chunk, encoding: .utf8) {
                self?.logger.writeRaw(.debug, "[ffmpeg] " + s.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        do {
            try proc.run()
        } catch {
            logger.error("ffmpeg launch failed: \(error)")
            await bridge.stopLivestream(serial: event.serialNumber)
            return
        }
        logger.info("Recording event \(event.type.rawValue) -> \(mp4URL.lastPathComponent)")

        var videoCodec: String?
        var audioCodec: String?
        let maxClipSeconds = settings.maxClipSeconds
        let deadline = Date().addingTimeInterval(TimeInterval(maxClipSeconds))

        let writeHandle = inputPipe.fileHandleForWriting
        var pipeOpen = true

        let writeBuffer: (Data) -> Bool = { data in
            guard pipeOpen else { return false }
            do {
                try writeHandle.write(contentsOf: data)
                return true
            } catch {
                pipeOpen = false
                return false
            }
        }

        // Pull frames until the stream ends or the pipe breaks.
        let captureTask = Task {
            for await frame in frames {
                if frame.kind == .video {
                    if videoCodec == nil { videoCodec = frame.codec }
                    if !writeBuffer(frame.data) { break }
                } else {
                    if audioCodec == nil { audioCodec = frame.codec }
                    // Audio path is best-effort; the ffmpeg invocation above
                    // ignores audio for simplicity. A future revision can
                    // remux through a second pipe or a tee muxer.
                }
            }
        }
        // Enforce the max clip length even if frames stop arriving (the
        // doorbell can go quiet without ever ending the stream).
        let deadlineTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(maxClipSeconds) * 1_000_000_000)
            return !Task.isCancelled
        }
        var deadlineHit = false
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await captureTask.value; return false }
            group.addTask { (await deadlineTask.value) == true }
            if let first = await group.next() {
                deadlineHit = first
            }
            captureTask.cancel()
            deadlineTask.cancel()
        }

        if deadlineHit {
            logger.info("Reached max clip length (\(maxClipSeconds)s), stopping")
        }
        // Always stop the livestream — leaving it open keeps the doorbell
        // awake and blocks the next recording.
        await bridge.stopLivestream(serial: event.serialNumber)

        if pipeOpen {
            try? writeHandle.close()
        }
        await waitForExit(proc, timeout: 10)
        errPipe.fileHandleForReading.readabilityHandler = nil

        let duration = Date().timeIntervalSince(started)

        // Confirm the output exists and has bytes; otherwise abandon.
        let attrs = try? FileManager.default.attributesOfItem(atPath: mp4URL.path)
        let size = (attrs?[.size] as? Int64) ?? 0
        if size < 1024 {
            logger.warn("Discarding short/empty clip (\(size) bytes)")
            try? FileManager.default.removeItem(at: mp4URL)
            return
        }

        // Thumbnail.
        await extractThumbnail(from: mp4URL, to: thumbURL)

        // Sidecar.
        let sidecar = EventSidecar(
            type: event.type,
            serialNumber: event.serialNumber,
            startedAt: started,
            durationSeconds: duration,
            fileSize: size,
            videoCodec: videoCodec,
            audioCodec: audioCodec,
            stem: stem
        )
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(sidecar)
            try data.write(to: sidecarURL, options: .atomic)
        } catch {
            logger.error("Sidecar write failed: \(error)")
        }

        archive.refresh()
        lastCaptureEndedAt = Date()
        logger.info("Archived clip \(stem) (\(size) bytes, \(String(format: "%.1f", duration))s)")

        // Mirror into the secondary backup folder, if configured.
        backup.mirror(stem: stem)
        backup.refresh(events: archive.events)
    }

    private func extractThumbnail(from clip: URL, to thumb: URL) async {
        let proc = Process()
        proc.executableURL = FFmpeg.binaryURL()
        proc.arguments = [
            "-loglevel", "error",
            "-i", clip.path,
            "-vframes", "1",
            "-q:v", "3",
            "-y",
            thumb.path
        ]
        do {
            try proc.run()
            await waitForExit(proc, timeout: 15)
        } catch {
            logger.warn("Thumbnail extraction failed: \(error)")
        }
    }

    /// Awaits a child process without blocking the main actor; terminates it
    /// if it overruns the timeout.
    private func waitForExit(_ proc: Process, timeout: Double) async {
        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if proc.isRunning {
            logger.warn("ffmpeg overran \(Int(timeout))s — terminating")
            proc.terminate()
        }
    }

    func filenameStem(for event: DoorbellEvent) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ts = f.string(from: event.timestamp)
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        return "event_\(ts)_\(event.type.rawValue)"
    }
}

enum FFmpeg {
    static func binaryURL() -> URL {
        if let res = Bundle.main.resourceURL {
            let candidate = res.appendingPathComponent("ffmpeg")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        // Dev fallback: Resources dir alongside Sources/.
        let exec = Bundle.main.bundleURL
        let dev = exec.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources").appendingPathComponent("ffmpeg")
        if FileManager.default.fileExists(atPath: dev.path) { return dev }
        for path in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"] {
            if FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return URL(fileURLWithPath: "/usr/local/bin/ffmpeg")
    }
}
