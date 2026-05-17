import Foundation

// LiveStreamer pulls H.264/H.265 frames from the bridge and remuxes them to a
// local HLS playlist that AVPlayer can consume.
//
// ffmpeg's input format depends on the doorbell's codec, which we only learn
// from the first video frame — so the stream is opened first, the first frame
// inspected, and ffmpeg spawned with the matching `-f h264` / `-f hevc`.

@MainActor
final class LiveStreamer: ObservableObject {

    @Published private(set) var playlistURL: URL? = nil
    @Published private(set) var isStreaming: Bool = false
    @Published var lastError: String? = nil

    private let logger: AppLogger
    private var ffmpegProcess: Process?
    private var streamTask: Task<Void, Never>?
    private var workDir: URL?
    private var idleTimer: Timer?
    private let httpServer: HLSServer

    init(logger: AppLogger) {
        self.logger = logger
        self.httpServer = HLSServer(logger: logger)
    }

    private var frameRate: Int = 15

    func start(serial: String, bridge: EufyBridge, idleTimeout: TimeInterval, frameRate: Int) async -> URL? {
        guard !isStreaming else { return playlistURL }
        self.frameRate = frameRate
        let dir = makeWorkDir()
        self.workDir = dir
        let playlist = dir.appendingPathComponent("live.m3u8")
        lastError = nil

        let frames: AsyncStream<EufyBridge.StreamFrame>
        do {
            frames = try bridge.startLivestream(serial: serial)
        } catch {
            logger.error("Live stream start failed: \(error)")
            lastError = error.localizedDescription
            return nil
        }

        isStreaming = true
        scheduleIdleTimeout(idleTimeout, serial: serial, bridge: bridge)

        streamTask = Task { @MainActor in
            await self.consumeFrames(frames, dir: dir, playlist: playlist)
        }

        // Wait for ffmpeg to produce a playable playlist (m3u8 + ≥2 segments,
        // so AVPlayer has a buffer to start from).
        for _ in 0..<230 {  // ~23s
            if !isStreaming { break }
            if FileManager.default.fileExists(atPath: playlist.path), segmentCount(in: dir) >= 2 {
                // AVPlayer needs HLS over HTTP, not file:// — serve the dir.
                guard let httpURL = await httpServer.start(directory: dir) else {
                    lastError = "Could not start local HLS server"
                    await stop(serial: serial, bridge: bridge)
                    return nil
                }
                self.playlistURL = httpURL
                logger.info("Live view ready, serving \(httpURL)")
                return httpURL
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if lastError == nil {
            lastError = "No video received — the doorbell may be asleep or unreachable."
        }
        // Tear down ffmpeg + the bridge livestream instead of leaking them
        // until the idle timer eventually fires.
        await stop(serial: serial, bridge: bridge)
        logger.error("Live view: playlist did not become playable in time")
        return nil
    }

    private func consumeFrames(_ frames: AsyncStream<EufyBridge.StreamFrame>, dir: URL, playlist: URL) async {
        var writeHandle: FileHandle?
        var pipeOpen = true
        var ffmpegUp = false
        var bytes = 0

        for await frame in frames {
            guard frame.kind == .video else { continue }
            if !ffmpegUp {
                ffmpegUp = true
                let codec = frame.codec ?? "h264"
                let inputFormat = (codec.contains("265") || codec.contains("hevc")) ? "hevc" : "h264"
                logger.info("Live view: codec=\(codec) → ffmpeg -f \(inputFormat)")
                writeHandle = spawnFFmpeg(inputFormat: inputFormat, dir: dir, playlist: playlist)
                if writeHandle == nil {
                    lastError = "Could not start ffmpeg"
                    break
                }
            }
            guard pipeOpen, let wh = writeHandle else { break }
            do {
                try wh.write(contentsOf: frame.data)
                bytes += frame.data.count
            } catch {
                pipeOpen = false
                break
            }
        }
        try? writeHandle?.close()
        logger.info("Live stream ended — \(bytes) bytes piped to ffmpeg")
        isStreaming = false
    }

    private func spawnFFmpeg(inputFormat: String, dir: URL, playlist: URL) -> FileHandle? {
        let proc = Process()
        proc.executableURL = FFmpeg.binaryURL()
        proc.arguments = [
            "-loglevel", "warning",
            "-fflags", "+genpts+discardcorrupt",
            // Raw H.264/H.265 elementary streams carry no timestamps. Declaring
            // an input framerate lets the demuxer assign clean, monotonic PTS
            // (wall-clock stamping produced non-monotonic DTS that AVPlayer
            // could not advance past — the stream froze on the first frame).
            "-r", String(frameRate),
            "-f", inputFormat,
            "-i", "pipe:0",
            "-c:v", "copy",
            "-an",
            "-f", "hls",
            "-hls_time", "2",
            "-hls_list_size", "8",
            "-hls_flags", "delete_segments+omit_endlist",
            "-hls_segment_filename", dir.appendingPathComponent("seg_%05d.ts").path,
            playlist.path
        ]
        let inputPipe = Pipe()
        proc.standardInput = inputPipe
        let errPipe = Pipe()
        proc.standardError = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            if !chunk.isEmpty, let s = String(data: chunk, encoding: .utf8) {
                self?.logger.writeRaw(.debug, "[ffmpeg.live] " + s.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        do {
            try proc.run()
        } catch {
            logger.error("ffmpeg live launch failed: \(error)")
            return nil
        }
        self.ffmpegProcess = proc
        return inputPipe.fileHandleForWriting
    }

    private func segmentCount(in dir: URL) -> Int {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return 0 }
        return items.filter { $0.hasSuffix(".ts") }.count
    }

    func resetIdleTimer(idleTimeout: TimeInterval, serial: String, bridge: EufyBridge) {
        scheduleIdleTimeout(idleTimeout, serial: serial, bridge: bridge)
    }

    private func scheduleIdleTimeout(_ seconds: TimeInterval, serial: String, bridge: EufyBridge) {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.logger.info("Live view idle timeout — stopping stream")
                await self.stop(serial: serial, bridge: bridge)
            }
        }
    }

    func stop(serial: String, bridge: EufyBridge) async {
        idleTimer?.invalidate()
        idleTimer = nil
        streamTask?.cancel()
        streamTask = nil
        httpServer.stop()
        await bridge.stopLivestream(serial: serial)
        if let p = ffmpegProcess, p.isRunning {
            p.terminate()
        }
        ffmpegProcess = nil
        isStreaming = false
        if let dir = workDir {
            try? FileManager.default.removeItem(at: dir)
        }
        workDir = nil
        playlistURL = nil
    }

    private func makeWorkDir() -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PorchKeep-live-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }
}
