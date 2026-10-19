import FluidAudio
import Foundation

/// The user's voice, so hands-free listening ("Hey Joe") hears them and not the room. Learned with
/// nothing to set up: every recording made by holding a key is them, and adds to a voiceprint (the
/// running mean of CAM++ speaker embeddings, kept in Voiceprint.json in Joe's folder, on this Mac).
///
/// With a voiceprint, a hands-free recording ends when *they* stop talking (not when the room goes
/// quiet), and before it's transcribed the stretches in other voices are cut out.
actor VoicePrint {
    static let shared = VoicePrint()

    /// Cosine similarity at or above which a 1.5-second stretch counts as theirs. Measured with
    /// CAM++: whole sentences in one voice score ~0.95 against each other, 1.5 s snippets ~0.82–0.9,
    /// other voices ~0.4–0.55. So it's set from how well their own recordings match (whole
    /// recordings, ~0.3 above what snippets score), within 0.55…0.72; 0.62 until that's known.
    var threshold: Float {
        guard let selfScore = stored?.selfScore else { return 0.62 }
        return min(0.72, max(0.55, selfScore - 0.3))
    }
    /// Recordings learned before the voiceprint is used.
    static let minimumSamples = 3

    private struct Stored: Codable {
        var mean: [Float]
        var count: Int
        /// How well a new recording of theirs matches the voiceprint, on average.
        var selfScore: Float?
    }

    private static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Shhh/Voiceprint.json")
    private var stored: Stored? = (try? Data(contentsOf: VoicePrint.url)).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
    private var embedder: CampPlusEmbedder?
    private var loading: Task<CampPlusEmbedder?, Never>?

    /// How many recordings it has learned from (shown in Settings).
    var learned: Int { stored?.count ?? 0 }
    var isReady: Bool { learned >= Self.minimumSamples }

    /// Forgets the voiceprint (Settings → Reset).
    func reset() {
        stored = nil
        try? FileManager.default.removeItem(at: Self.url)
    }

    /// The model, downloaded the first time (a few MB) and then loaded from disk.
    private func model() async -> CampPlusEmbedder? {
        if let embedder { return embedder }
        if loading == nil { loading = Task { try? await CampPlusEmbedder.load() } }
        embedder = await loading?.value
        if embedder == nil { loading = nil } // offline: try again next time
        return embedder
    }

    func embed(_ samples: [Float]) async -> [Float]? {
        guard samples.count >= 16_000, let model = await model() else { return nil }
        return try? await model.embed(audio: samples)
    }

    /// A recording they made by holding the key: theirs for certain. Two seconds or more of speech.
    func learn(_ samples: [Float]) async {
        let speech = Self.voiced(samples)
        guard speech.count >= 32_000, let embedding = await embed(speech) else { return }
        var next = stored ?? Stored(mean: [Float](repeating: 0, count: embedding.count), count: 0)
        guard next.mean.count == embedding.count else { return }
        if next.count >= 1 {
            let score = zip(next.mean, embedding).reduce(0) { $0 + $1.0 * $1.1 }
            next.selfScore = next.selfScore.map { $0 * 0.8 + score * 0.2 } ?? score
        }
        // A running mean that keeps adapting (a cold, a new microphone): older recordings fade after 40.
        let weight = Float(min(next.count, 40))
        next.mean = Self.normalized(zip(next.mean, embedding).map { ($0 * weight + $1) / (weight + 1) })
        next.count += 1
        stored = next
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(next).write(to: Self.url, options: .atomic)
    }

    /// How much a stretch of audio sounds like them (−1…1), or nil without a voiceprint.
    func similarity(_ samples: [Float]) async -> Float? {
        guard isReady, let embedding = await embed(samples) else { return nil }
        return score(embedding)
    }

    /// Whether a stretch of audio is them.
    func isOwnVoice(_ samples: [Float]) async -> Bool? {
        await similarity(samples).map { $0 >= threshold }
    }

    /// How much an embedding sounds like them, or nil without a voiceprint.
    func score(_ embedding: [Float]) -> Float? {
        guard isReady, let mean = stored?.mean, mean.count == embedding.count else { return nil }
        return zip(mean, embedding).reduce(0) { $0 + $1.0 * $1.1 }
    }

    /// Only the parts in their voice: half-second slots, each kept when a 1.5-second window around
    /// it sounds like them. Nil without a voiceprint (keep everything); empty if none of it was them.
    func keepOwnVoice(_ samples: [Float]) async -> [Float]? {
        guard isReady else { return nil }
        let slot = 8_000, window = 3 // slots of 0.5 s, judged three at a time
        let slots = samples.count / slot
        guard slots >= window else { return (await isOwnVoice(samples)).map { $0 ? samples : [] } }
        var own = [Bool](repeating: false, count: slots)
        var start = 0
        while start + window <= slots {
            let piece = Array(samples[(start * slot)..<((start + window) * slot)])
            if Self.rms(piece) > 0.004, let score = await similarity(piece), score >= threshold {
                for index in start..<(start + window) { own[index] = true }
            }
            start += 1
        }
        var kept: [Float] = []
        for index in 0..<slots where own[index] { kept += samples[(index * slot)..<((index + 1) * slot)] }
        if own.last == true { kept += samples[(slots * slot)...] } // the tail end
        return kept
    }

    // MARK: - Helpers

    /// The louder parts of a recording (speech), without the silence around and between it.
    private static func voiced(_ samples: [Float]) -> [Float] {
        let frame = 1_600 // 0.1 s
        guard samples.count > frame * 4 else { return samples }
        let frames = stride(from: 0, to: samples.count - frame, by: frame).map { Array(samples[$0..<($0 + frame)]) }
        let levels = frames.map(rms)
        let floor = levels.sorted()[levels.count / 5] // the quiet fifth: the room
        return frames.enumerated().filter { levels[$0.offset] > max(floor * 2.5, 0.004) }.flatMap(\.element)
    }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
    }

    private static func normalized(_ vector: [Float]) -> [Float] {
        let norm = max(sqrt(vector.reduce(0) { $0 + $1 * $1 }), 1e-9)
        return vector.map { $0 / norm }
    }
}

/// Who is speaking, through a recording of several people (a lecture, a meeting): each piece the
/// notepad transcribes is split where the voice changes, and each part labelled "You" (their
/// voiceprint), or "Speaker 1", "Speaker 2"… in order of first speaking, the same label each time
/// a voice comes back. Voices are matched by CAM++ embedding to each speaker's running mean.
actor SpeakerTracker {
    /// Similarity to a speaker's running mean for a 1.5 s stretch to count as them (other voices
    /// measured ~0.4–0.6 against each other).
    static let sameSpeaker: Float = 0.66
    private var speakers: [(label: String, mean: [Float], count: Int)] = []

    /// The piece in turns: who said each part, in order. Labels are "" if the model isn't there.
    func split(_ samples: [Float]) async -> [(label: String, samples: [Float])] {
        let slot = 8_000, window = 3 // judge 1.5 s at a time, in half-second steps
        let slots = samples.count / slot
        guard slots >= window else {
            guard let embedding = await VoicePrint.shared.embed(samples) else { return [("", samples)] }
            return [(await match(embedding) ?? add(embedding), samples)]
        }
        // Each window's voice; quiet windows have none.
        var embeddings: [[Float]?] = []
        for start in 0...(slots - window) {
            let piece = Array(samples[(start * slot)..<((start + window) * slot)])
            embeddings.append(VoicePrint.rms(piece) > 0.006 ? await VoicePrint.shared.embed(piece) : nil)
        }
        if embeddings.allSatisfy({ $0 == nil }) { return [("", samples)] }
        // In order: a known voice gets its label. A voice no one has yet is held as a candidate, and
        // becomes a new speaker only when it lasts (four windows, about 2.5 s): a window straddling
        // two people looks like a third. The candidate ends where the unknown voice itself changes.
        var labels = [String?](repeating: nil, count: embeddings.count)
        var pending: [Int] = []
        func pendingMean() -> [Float] {
            let vectors = pending.compactMap { embeddings[$0] }
            return vectors.dropFirst().reduce(vectors[0]) { zip($0, $1).map { $0 + $1 } }.map { $0 / Float(vectors.count) }
        }
        func flush() {
            if pending.count >= 4 {
                let label = add(pendingMean())
                for index in pending { labels[index] = label }
            }
            pending = []
        }
        for index in embeddings.indices {
            guard let embedding = embeddings[index] else { continue }
            if let known = await match(embedding) {
                flush()
                labels[index] = known
            } else {
                if !pending.isEmpty, Self.cosine(pendingMean(), embedding) < Self.sameSpeaker { flush() }
                pending.append(index)
            }
        }
        flush()
        // Each slot takes the window centred on it; a quiet or unsure one keeps the speaker before it.
        var slotLabels: [String] = []
        for index in 0..<slots {
            let found = labels[min(max(index - 1, 0), labels.count - 1)]
            slotLabels.append(found ?? slotLabels.last ?? labels.compactMap { $0 }.first ?? "")
        }
        // Turns, with blips under a second folded into the turn before.
        var turns: [(label: String, samples: [Float])] = []
        for index in 0..<slots {
            let part = Array(samples[(index * slot)..<(index == slots - 1 ? samples.count : (index + 1) * slot)])
            if let last = turns.last, last.label == slotLabels[index] { turns[turns.count - 1].samples += part }
            else { turns.append((slotLabels[index], part)) }
        }
        var merged: [(label: String, samples: [Float])] = []
        for turn in turns {
            if turn.samples.count < 16_000, !merged.isEmpty { merged[merged.count - 1].samples += turn.samples }
            else if let last = merged.last, last.label == turn.label { merged[merged.count - 1].samples += turn.samples }
            else { merged.append(turn) }
        }
        return merged
    }

    /// A voice heard before (they, or a speaker so far), its running mean nudged; nil if new.
    private func match(_ embedding: [Float]) async -> String? {
        if let own = await VoicePrint.shared.score(embedding), own >= (await VoicePrint.shared.threshold) { return "You" }
        let scores = speakers.map { speaker in zip(speaker.mean, embedding).reduce(Float(0)) { $0 + $1.0 * $1.1 } }
        guard let best = scores.indices.max(by: { scores[$0] < scores[$1] }), scores[best] >= Self.sameSpeaker else { return nil }
        let speaker = speakers[best]
        let weight = Float(min(speaker.count, 30))
        let mean = zip(speaker.mean, embedding).map { ($0 * weight + $1) / (weight + 1) }
        let norm = max(sqrt(mean.reduce(0) { $0 + $1 * $1 }), 1e-9)
        speakers[best] = (speaker.label, mean.map { $0 / norm }, speaker.count + 1)
        return speaker.label
    }

    private static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        let dot = zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        let norms = sqrt(a.reduce(0) { $0 + $1 * $1 }) * sqrt(b.reduce(0) { $0 + $1 * $1 })
        return dot / max(norms, 1e-9)
    }

    private func add(_ embedding: [Float]) -> String {
        let norm = max(sqrt(embedding.reduce(0) { $0 + $1 * $1 }), 1e-9)
        let label = "Speaker \(speakers.count + 1)"
        speakers.append((label, embedding.map { $0 / norm }, 1))
        return label
    }
}
