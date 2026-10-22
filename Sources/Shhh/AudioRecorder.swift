import AudioToolbox
import AVFoundation

/// Records a microphone as 16 kHz mono Float32, the format the speech model expects.
///
/// Every Core Audio / AVAudioEngine call runs on a background queue behind a watchdog. If the
/// audio system hangs (it can, when a device drops out mid-handshake), recording fails with a
/// beep instead of freezing the app, and the next recording starts on a fresh queue.
@MainActor
final class AudioRecorder {
    /// Called on the audio thread with a 0...1 loudness value, for the waveform.
    var onLevel: (@Sendable (Float) -> Void)?

    private var queue = AudioRecorder.makeQueue()

    /// One recording, returned by `start` and handed back to `stop` or `cancel`.
    final class Recording {
        let input: AudioInput
        fileprivate let session: RecordingSession
        fileprivate let queue: DispatchQueue

        fileprivate init(input: AudioInput, session: RecordingSession, queue: DispatchQueue) {
            self.input = input
            self.session = session
            self.queue = queue
        }
    }

    /// Picks the microphone and starts recording. `preferredUID` nil means Automatic.
    func start(preferredUID: String?, timeout: TimeInterval = 2.5) async throws -> Recording {
        let session = RecordingSession(onLevel: onLevel)
        let queue = self.queue
        do {
            let input = try await runWithWatchdog(on: queue, timeout: timeout) {
                try session.start(preferredUID: preferredUID, queue: queue)
            }
            return Recording(input: input, session: session, queue: queue)
        } catch WatchdogError.timedOut {
            // That queue is stuck inside Core Audio. Abandon it; if the call ever returns,
            // the queued stop cleans up the engine it started.
            self.queue = Self.makeQueue()
            queue.async { session.stop() }
            throw WatchdogError.timedOut
        }
    }

    /// Some microphones deliver audio late: the iPhone's (Continuity) starts about 3 s behind but
    /// then sends everything. Keep listening until the audio covers how long the key was held,
    /// unless the microphone has stopped for good.
    /// Any other microphone that started late (AirPods take up to a second to switch to their headset
    /// mode) won't send what it missed: waiting for it only kept recording after the key was let go,
    /// and the request waited that long. Those get just the last buffers still on their way.
    func stop(_ recording: Recording, covering duration: TimeInterval, timeout: TimeInterval = 4) async -> [Float] {
        let session = recording.session
        let catchesUp = recording.input.kind == .iPhone
        let target = catchesUp ? duration - 0.25 : min(duration - 0.25, session.capturedSeconds + 0.08)
        let deadline = Date().addingTimeInterval(catchesUp ? timeout : 0.3)
        while session.capturedSeconds < target, !session.hasFailed, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        let samples = session.samples
        recording.queue.async { session.stop() } // never wait on the audio system from here
        return samples
    }

    /// For hands-free listening (the notepad): the recording keeps going while what it has heard so
    /// far is read in pieces. How many seconds are waiting, the last few (to find a pause), and
    /// taking them all.
    func pendingSeconds(_ recording: Recording) -> Double { recording.session.capturedSeconds }
    func tail(_ recording: Recording, seconds: Double) -> [Float] { recording.session.tail(Int(seconds * 16_000)) }
    /// What it has heard from sample `start` on (the noise filter reads the recording as it's made).
    func samples(_ recording: Recording, from start: Int) -> [Float] { recording.session.samples(from: start) }
    func take(_ recording: Recording) -> [Float] { recording.session.take() }
    func hasFailed(_ recording: Recording) -> Bool { recording.session.hasFailed }

    /// Stops and throws away the recording.
    func cancel(_ recording: Recording) {
        recording.queue.async { recording.session.stop() }
    }

    private static func makeQueue() -> DispatchQueue {
        DispatchQueue(label: "shhh.audio", qos: .userInteractive)
    }

    enum RecorderError: LocalizedError {
        case noMicrophone
        var errorDescription: String? { "No microphone available" }
    }
}

/// One recording: an engine, its converter and the captured samples.
/// `start`, `stop` and the stall checks run on the recorder's queue; `samples`, `capturedSeconds` and
/// `hasFailed` are thread-safe.
private final class RecordingSession: @unchecked Sendable {
    private let onLevel: (@Sendable (Float) -> Void)?
    private let lock = NSLock()
    private var buffer: [Float] = []
    private var failed = false
    private var lastAudioAt: Date?
    private var engine: AVAudioEngine?
    private var deviceID: AudioDeviceID = 0
    private var healthCheck: DispatchSourceTimer?
    private var restarts = 0
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    init(onLevel: (@Sendable (Float) -> Void)?) {
        self.onLevel = onLevel
    }

    var samples: [Float] {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }

    var capturedSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(buffer.count) / targetFormat.sampleRate
    }

    /// For long recordings: the last `count` samples, without taking them.
    func tail(_ count: Int) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return Array(buffer.suffix(count))
    }

    func samples(from start: Int) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return start < buffer.count ? Array(buffer[start...]) : []
    }

    /// For long recordings: everything captured so far, cleared from the buffer so it doesn't grow
    /// for as long as the recording goes on.
    func take() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let taken = buffer
        buffer.removeAll(keepingCapacity: true)
        return taken
    }

    /// True once the microphone has stopped and couldn't be restarted.
    var hasFailed: Bool {
        lock.lock(); defer { lock.unlock() }
        return failed
    }

    func start(preferredUID: String?, queue: DispatchQueue) throws -> AudioInput {
        guard let input = AudioDevices.resolve(preferredUID: preferredUID) else {
            throw AudioRecorder.RecorderError.noMicrophone
        }
        deviceID = input.id
        do {
            try startEngine()
        } catch {
            stopEngine()
            throw error
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in self?.restartIfStalled() }
        timer.resume()
        healthCheck = timer
        return input
    }

    func stop() {
        healthCheck?.cancel()
        healthCheck = nil
        stopEngine()
    }

    /// Builds an engine on the chosen microphone, taps it in its current format and starts it.
    private func startEngine() throws {
        let engine = AVAudioEngine()
        self.engine = engine
        let node = engine.inputNode
        var deviceID = self.deviceID
        if let unit = node.audioUnit {
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else { throw AudioRecorder.RecorderError.noMicrophone }
        }
        // Tap in the microphone's own format (after switching devices the node's output format
        // can be stale and the engine refuses to start). Converted to 16 kHz per buffer below.
        let format = node.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioRecorder.RecorderError.noMicrophone }
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    private func stopEngine() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    /// The audio setup can change under a recording: AirPods switch to their headset mode when
    /// the microphone opens, a microphone changes format or is unplugged. macOS then stops the
    /// engine, or leaves it running but silent. Either way, carry on with a new engine (the old
    /// one can't be reused: it keeps reporting the old format). Audio captured so far is kept.
    private func restartIfStalled() {
        guard let engine else { return }
        lock.lock(); let lastAudio = lastAudioAt; lock.unlock()
        // No audio yet isn't a stall: the iPhone's microphone starts seconds late.
        let silent = lastAudio.map { Date().timeIntervalSince($0) > 1 } ?? false
        guard !engine.isRunning || silent else { return }
        stopEngine()
        lock.lock(); lastAudioAt = nil; lock.unlock() // the new engine gets the same grace
        restarts += 1
        do {
            guard restarts <= 5 else { throw AudioRecorder.RecorderError.noMicrophone } // keeps failing: give up
            try startEngine()
        } catch {
            stop()
            lock.lock(); failed = true; lock.unlock()
        }
    }

    private func process(_ pcm: AVAudioPCMBuffer) {
        if let channel = pcm.floatChannelData?[0], pcm.frameLength > 0 {
            var sum: Float = 0
            for i in 0..<Int(pcm.frameLength) { sum += channel[i] * channel[i] }
            onLevel?(min(1, sqrt(sum / Float(pcm.frameLength)) * 12))
        }

        if converter == nil || converter?.inputFormat != pcm.format {
            converter = AVAudioConverter(from: pcm.format, to: targetFormat)
        }
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / pcm.format.sampleRate
        let capacity = AVAudioFrameCount(Double(pcm.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return pcm
        }
        guard error == nil, let data = output.floatChannelData?[0] else { return }
        lock.lock()
        buffer.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(output.frameLength)))
        lastAudioAt = Date()
        lock.unlock()
    }
}
