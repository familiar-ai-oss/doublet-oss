import AVFoundation
import CoreMedia
import Speech
import Synchronization

// Hearing and speaking, on the device: Apple's SpeechAnalyzer for what you say, Apple's voices for what Claude says.
// Both work in audio buffers, so the app plays and records through one audio engine.

/// An audio buffer handed from one thread to another: made on one side, then only read on the other.
public struct PCM: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer
    public init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

// MARK: hearing

public enum RecognizerError: LocalizedError, Equatable {
    case unsupportedLanguage(String)
    case noAudioFormat

    public var errorDescription: String? {
        switch self {
        case .unsupportedLanguage(let l): "This device can't recognize speech in \(Locale.current.localizedString(forIdentifier: l) ?? l) on its own."
        case .noAudioFormat: "Speech recognition can't take audio on this device."
        }
    }
}

/// How the recognizer trades speed for accuracy. Accurate waits a little longer before guessing, and guesses better;
/// Fast shows words sooner. Both mark each word with its time in the audio, so results merge by time.
public enum SpeechPreset: String, Sendable, CaseIterable {
    case accurate, fast

    /// The new transcriber's options for this preset.
    public var transcriber: SpeechTranscriber.Preset {
        SpeechTranscriber.Preset(transcriptionOptions: [], reportingOptions: self == .fast ? [.volatileResults, .fastResults] : [.volatileResults],
                                 attributeOptions: [.audioTimeRange])
    }

    /// The dictation transcriber's (the fallback): long dictation with punctuation, guesses as you go, word times.
    public var dictation: DictationTranscriber.Preset {
        var p = DictationTranscriber.Preset.progressiveLongDictation
        p.attributeOptions.insert(.audioTimeRange)
        if self == .fast { p.reportingOptions.insert(.frequentFinalization) }
        return p
    }
}

/// Something that takes microphone audio: the recognizer, or a test's stand-in.
public protocol AudioSink: AnyObject, Sendable {
    func feed(_ buffer: AVAudioPCMBuffer)
}

/// Apple's on-device speech recognition (SpeechAnalyzer): the transcriber behind Notes and Voice Memos where this
/// device and language have it, else the dictation one. It runs on the device's Neural Engine, and no audio leaves it.
/// Feed it audio in any format, from one thread at a time; read what's been said from `heard`. Times are seconds of
/// audio fed since it started.
public final class Recognizer: AudioSink, @unchecked Sendable {
    public enum Model: String, Sendable { case transcriber, dictation }

    public typealias Heard = DuetKit.Heard

    public let model: Model
    public let locale: Locale
    /// What's been said, as it's recognized. Ends after `finish()` or `cancel()`.
    public let heard: AsyncStream<Heard>
    private let analyzer: SpeechAnalyzer
    private let converter: AnalyzerInputConverter
    private let inputs: AsyncStream<AnalyzerInput>.Continuation
    private let reading: Task<Void, Never>
    /// Frames fed so far, at the rate they came in: the clock the timestamps (and so the results' times) run on.
    private let fed = Mutex<(frames: Double, rate: Double)>((0, 0))

    private init(model: Model, locale: Locale, heard: AsyncStream<Heard>, analyzer: SpeechAnalyzer, converter: AnalyzerInputConverter,
                 inputs: AsyncStream<AnalyzerInput>.Continuation, reading: Task<Void, Never>) {
        self.model = model; self.locale = locale; self.heard = heard; self.analyzer = analyzer
        self.converter = converter; self.inputs = inputs; self.reading = reading
    }

    /// Starts recognizing a language, first downloading Apple's model for it if this device doesn't have it yet.
    /// `vocabulary`: words to listen for that a general model might mishear, such as names in the project (both
    /// transcribers take them).
    public static func start(locale: Locale = .current, vocabulary: [String] = [], preset: SpeechPreset = .accurate,
                             downloading: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Recognizer {
        let (module, model, matched) = try await module(for: locale, preset: preset)
        try await install(module, locale: matched, downloading: downloading)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else { throw RecognizerError.noAudioFormat }
        // Lingering: the model stays loaded a while after a stop, so the next session starts at once.
        let analyzer = SpeechAnalyzer(modules: [module], options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering))
        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = Array(vocabulary.prefix(100))
            try? await analyzer.setContext(context)
        }
        try await analyzer.prepareToAnalyze(in: format)
        let (input, inputs) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let (heard, out) = AsyncStream.makeStream(of: Heard.self)
        let reading = read(module, into: out)
        try await analyzer.start(inputSequence: input)
        return Recognizer(model: model, locale: matched, heard: heard, analyzer: analyzer, converter: AnalyzerInputConverter(analyzerFormat: format),
                          inputs: inputs, reading: reading)
    }

    /// Audio to recognize, in whatever format it was recorded. Each buffer is stamped with where it falls in the
    /// stream, so results carry times `settle()` can finalize through.
    public func feed(_ buffer: AVAudioPCMBuffer) {
        let rate = buffer.format.sampleRate
        guard rate > 0, buffer.frameLength > 0 else { return }
        let start = fed.withLock { f -> Double in
            // A new rate (another microphone): the clock carries on in the new rate's frames.
            if f.rate != rate { f.frames = f.rate > 0 ? f.frames / f.rate * rate : 0; f.rate = rate }
            defer { f.frames += Double(buffer.frameLength) }
            return f.frames
        }
        let time = AVAudioTime(sampleTime: AVAudioFramePosition(start), atRate: rate)
        guard let converted = try? converter.convert(buffer, at: time) else { return }
        for input in converted { inputs.yield(input) }
    }

    /// Seconds of audio fed so far.
    public var heardThrough: Double { fed.withLock { $0.rate > 0 ? $0.frames / $0.rate : 0 } }

    /// Settles everything heard so far: the guess becomes final now, rather than when the recognizer gets round to it.
    /// It keeps listening. Returns within `limit` whatever happens: only what the analyzer has taken in is finalized,
    /// and only if some of it is still a guess, because asked to finalize past its input, or with nothing left to
    /// finalize, the analyzer can wait indefinitely for audio (it finishes once more audio comes, as it does from a
    /// microphone). Returns the time everything is final through, or nil if it didn't settle in time. A guess that
    /// didn't change may get no final result, so promote the transcript through this time.
    @discardableResult
    public func settle(within limit: Duration = .milliseconds(500)) async -> Double? {
        if let rest = try? converter.flush() { for input in rest { inputs.yield(input) } }
        guard let range = await analyzer.volatileRange, range.end.isNumeric, range.duration.isNumeric, range.duration.seconds > 0.02 else {
            return heardThrough
        }
        let fed = CMTime(seconds: heardThrough, preferredTimescale: 48_000)
        let through = CMTimeMinimum(range.end, fed)
        guard through > range.start else { return through.seconds }
        let analyzer = self.analyzer
        let done = Flag()
        Task { _ = try? await analyzer.finalize(through: through); done.set() }
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if done.isSet { return through.seconds }
            try? await Task.sleep(for: .milliseconds(15))
        }
        return done.isSet ? through.seconds : nil
    }

    /// Stops listening: what was still a guess is settled, then `heard` ends.
    public func finish() async {
        if let rest = try? converter.flush() { for input in rest { inputs.yield(input) } }
        inputs.finish()
        do { try await analyzer.finalizeAndFinishThroughEndOfInput() } catch { await analyzer.cancelAndFinishNow() }
        await reading.value
    }

    /// Stops at once, dropping what wasn't settled; returns once the recognizer has let go.
    public func cancel() async {
        inputs.finish()
        await analyzer.cancelAndFinishNow()
        reading.cancel()
        await reading.value
    }

    /// The languages this device can recognize on its own.
    public static func languages() async -> [Locale] {
        SpeechTranscriber.isAvailable ? await SpeechTranscriber.supportedLocales : await DictationTranscriber.supportedLocales
    }

    /// The new transcriber where this device and language have it (the model Notes and Voice Memos use), else the
    /// dictation one, which covers more devices and languages.
    static func module(for locale: Locale, preset: SpeechPreset) async throws -> (any SpeechModule, Model, Locale) {
        if SpeechTranscriber.isAvailable, let l = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            return (SpeechTranscriber(locale: l, preset: preset.transcriber), .transcriber, l)
        }
        if let l = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            return (DictationTranscriber(locale: l, preset: preset.dictation), .dictation, l)
        }
        throw RecognizerError.unsupportedLanguage(locale.identifier)
    }

    /// Reserves the language's model (so the system keeps it) and downloads it if it isn't on the device yet.
    private static func install(_ module: any SpeechModule, locale: Locale, downloading: @escaping @Sendable (Double) -> Void) async throws {
        _ = try? await AssetInventory.reserve(locale: locale)
        guard await AssetInventory.status(forModules: [module]) != .installed,
              let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else { return }
        let progress = Shared(request.progress)
        let watch = Task {
            while !Task.isCancelled {
                downloading(progress.value.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { watch.cancel() }
        try await request.downloadAndInstall()
        downloading(1)
    }

    private static func read(_ module: any SpeechModule, into out: AsyncStream<Heard>.Continuation) -> Task<Void, Never> {
        Task {
            defer { out.finish() }
            do {
                if let t = module as? SpeechTranscriber {
                    for try await r in t.results { out.yield(heard(r.text, isFinal: r.isFinal, range: r.range, final: r.resultsFinalizationTime)) }
                } else if let d = module as? DictationTranscriber {
                    for try await r in d.results { out.yield(heard(r.text, isFinal: r.isFinal, range: r.range, final: r.resultsFinalizationTime)) }
                }
            } catch {}
        }
    }

    /// A result as words with their times (each run of the text marked with the audio it came from).
    static func heard(_ text: AttributedString, isFinal: Bool, range: CMTimeRange, final: CMTime) -> Heard {
        var runs: [Heard.Run] = []
        for run in text.runs {
            let words = String(text[run.range].characters)
            guard !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if let r = run.audioTimeRange, r.start.isNumeric, r.duration.isNumeric {
                runs.append(Heard.Run(words.trimmingCharacters(in: .whitespacesAndNewlines), r.start.seconds, (r.start + r.duration).seconds))
            }
        }
        // Words without times: the result's range for all of them.
        if runs.isEmpty, range.start.isNumeric, range.duration.isNumeric, !text.characters.isEmpty {
            runs = [Heard.Run(String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines), range.start.seconds, range.end.seconds)]
        }
        return Heard(text: String(text.characters), isFinal: isFinal, runs: runs, finalThrough: final.isNumeric ? final.seconds : nil)
    }
}

// MARK: taking audio in

/// Between the microphone and the recognizer. The microphone starts first, and what it hears while the recognizer
/// loads is kept (the last `keep` seconds), then handed over, so your first words aren't lost. It also tells when audio
/// first flows, which is when listening has really started.
public final class AudioIntake: Sendable {
    private struct State {
        var sink: (any AudioSink)?
        var backlog: [(pcm: PCM, at: Double, seconds: Double)] = []
        var clock = 0.0
        var paused = false
        var flowed = false
        var onAudio: (@Sendable () -> Void)?
    }

    public let keep: Double
    private let state = Mutex(State())

    public init(keep: Double = 4) { self.keep = keep }

    /// Called once, from the audio thread, when the first buffer arrives.
    public func onFirstAudio(_ f: @escaping @Sendable () -> Void) { state.withLock { $0.onAudio = f } }

    /// A buffer from the microphone (on the audio thread).
    public func take(_ buffer: AVAudioPCMBuffer) {
        let rate = buffer.format.sampleRate
        guard rate > 0, buffer.frameLength > 0 else { return }
        let seconds = Double(buffer.frameLength) / rate
        let first: (@Sendable () -> Void)? = state.withLock { s in
            guard !s.paused else { return nil }
            defer { s.clock += seconds }
            if let sink = s.sink {
                sink.feed(buffer)
            } else if let copy = Self.copy(buffer) {
                s.backlog.append((PCM(copy), s.clock, seconds))
                var total = s.backlog.reduce(0) { $0 + $1.seconds }
                while total > keep, let oldest = s.backlog.first { total -= oldest.seconds; s.backlog.removeFirst() }
            }
            guard !s.flowed else { return nil }
            s.flowed = true
            return s.onAudio
        }
        first?()
    }

    /// Audio goes to `sink` from now on, after what was kept for it.
    public func attach(_ sink: any AudioSink) {
        state.withLock { s in
            for b in s.backlog { sink.feed(b.pcm.buffer) }
            s.backlog = []
            s.sink = sink
        }
    }

    /// Audio is kept again, for the next sink.
    public func detach() { state.withLock { $0.sink = nil; $0.backlog = [] } }

    /// While paused (Duet speaking, with no echo cancelling), audio is dropped.
    public func pause(_ on: Bool) { state.withLock { $0.paused = on; if on { $0.backlog = [] } } }

    /// Drops kept audio from before `time` (seconds since the intake started).
    public func discard(before time: Double) { state.withLock { s in s.backlog.removeAll { $0.at + $0.seconds <= time } } }

    /// Seconds of audio taken so far.
    public var now: Double { state.withLock { $0.clock } }
    public var backlogSeconds: Double { state.withLock { $0.backlog.reduce(0) { $0 + $1.seconds } } }
    public var hasFlowed: Bool { state.withLock { $0.flowed } }

    /// A buffer of our own: the engine reuses its tap's.
    static func copy(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let c = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: b.frameLength) else { return nil }
        c.frameLength = b.frameLength
        let src = UnsafeMutableAudioBufferListPointer(b.mutableAudioBufferList), dst = UnsafeMutableAudioBufferListPointer(c.mutableAudioBufferList)
        for (s, d) in zip(src, dst) {
            guard let from = s.mData, let to = d.mData else { continue }
            memcpy(to, from, Int(min(s.mDataByteSize, d.mDataByteSize)))
        }
        return c
    }
}

/// Set once, from any thread.
private final class Flag: Sendable {
    private let value = Mutex(false)
    func set() { value.withLock { $0 = true } }
    var isSet: Bool { value.withLock { $0 } }
}

/// A thread-safe Foundation object (NSProgress) carried into a task.
private struct Shared<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

// MARK: speaking

/// Apple's voices, as audio: each piece of text becomes buffers as it's synthesized, so it can play through the same
/// engine as the microphone, whose echo canceller then knows not to hear it.
@MainActor
public final class Synthesizer {
    private let synth = AVSpeechSynthesizer()
    private var open: [AsyncStream<PCM>.Continuation] = []

    public init() {}

    /// Speaks text into buffers, which arrive as they're made; the stream ends with the text.
    public func speak(_ text: String, voice: AVSpeechSynthesisVoice?, rate: Float = AVSpeechUtteranceDefaultSpeechRate) -> AsyncStream<PCM> {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = rate
        let (stream, out) = AsyncStream.makeStream(of: PCM.self)
        if open.count > 64 { open.removeFirst(open.count - 64) }
        open.append(out)
        synth.write(utterance, toBufferCallback: Self.collect(into: out))
        return stream
    }

    /// Stops speaking: every stream ends, and what wasn't synthesized yet never is.
    public func stop() {
        synth.stopSpeaking(at: .immediate)
        for out in open { out.finish() }
        open.removeAll()
    }

    /// Made outside the main actor: the synthesizer calls it on its own thread.
    private nonisolated static func collect(into out: AsyncStream<PCM>.Continuation) -> AVSpeechSynthesizer.BufferCallback {
        { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else { out.finish(); return }
            out.yield(PCM(pcm))
        }
    }

    /// The voices worth offering for a language, best first: premium, then enhanced, then the rest; no novelty voices.
    public nonisolated static func voices(language: String) -> [AVSpeechSynthesisVoice] {
        let lang = language.replacingOccurrences(of: "_", with: "-").lowercased()
        let all = AVSpeechSynthesisVoice.speechVoices().filter { !$0.voiceTraits.contains(.isNoveltyVoice) }
        var matching = all.filter { $0.language.lowercased() == lang }
        if matching.isEmpty { matching = all.filter { $0.language.lowercased().hasPrefix(String(lang.prefix(2))) } }
        let preferred = AVSpeechSynthesisVoice(language: language)?.identifier
        return matching.sorted {
            if $0.quality != $1.quality { return $0.quality.rawValue > $1.quality.rawValue }
            if ($0.identifier == preferred) != ($1.identifier == preferred) { return $0.identifier == preferred }
            return $0.name < $1.name
        }
    }

    /// The voice to use: the one chosen in Settings if it's still installed, else the best for the language.
    public nonisolated static func voice(id: String?, language: String) -> AVSpeechSynthesisVoice? {
        if let id, !id.isEmpty, let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        return voices(language: language).first ?? AVSpeechSynthesisVoice(language: language)
    }
}

// MARK: converting

/// Converts audio buffers to one format, keeping its state from buffer to buffer so resampling has no seams.
public final class PCMConverter {
    public let format: AVAudioFormat
    private var converter: AVAudioConverter?

    public init(to format: AVAudioFormat) { self.format = format }

    public func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if input.format == format { return input }
        if converter?.inputFormat != input.format { converter = AVAudioConverter(from: input.format, to: format) }
        guard let converter, input.frameLength > 0 else { return nil }
        let ratio = format.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var given = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return input
        }
        return status == .error || out.frameLength == 0 ? nil : out
    }

    /// What's still inside the resampler, at the end of a stream (a sentence's last few milliseconds). The next
    /// buffer starts afresh.
    public func flush() -> AVAudioPCMBuffer? {
        guard let converter, let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else { return nil }
        var error: NSError?
        _ = converter.convert(to: out, error: &error) { _, status in
            status.pointee = .endOfStream
            return nil
        }
        converter.reset()
        return out.frameLength > 0 ? out : nil
    }
}
