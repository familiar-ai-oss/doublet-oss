import AVFoundation
import DuetKit
import Observation
import OSLog
import Synchronization
#if os(iOS)
import AudioToolbox
#else
import AppKit
#endif

/// Voice settings, shared by Settings (through @AppStorage) and the voice controller.
enum VoiceSettings {
    static let language = "voice.language"
    static let voice = "voice.voice"
    static let rate = "voice.rate"
    static let pause = "voice.pause"
    static let speakReplies = "voice.speakReplies"
    static let talkOver = "voice.talkOver"
    static let readFull = "voice.readFull"
    /// Apple Intelligence tidies what you say (fillers, self-corrections, punctuation), the way Advanced Dictation does.
    static let cleanUp = "voice.cleanUp"
    /// The recognizer's preset: "accurate" (the default) or "fast".
    static let preset = "voice.preset"

    static let defaultRate = 0.52
    static let defaultPause = 1.2
}

enum VoiceError: LocalizedError {
    case noMicrophone, microphoneDenied

    var errorDescription: String? {
        switch self {
        case .noMicrophone: "There's no microphone to listen with."
        case .microphoneDenied: "Doublet isn't allowed to use the microphone. Turn it on in Settings › Privacy & Security › Microphone."
        }
    }
}

// MARK: audio

/// The microphone and the speaker on one audio engine. In Talk mode the engine's voice processing cancels echo: it
/// hears what the engine plays, so Duet doesn't transcribe its own voice and you can talk over it.
@MainActor
final class AudioRig {
    enum Purpose: Equatable, Sendable { case dictate, talk, read }

    let purpose: Purpose
    let echoCancelling: Bool
    private let engine: AVAudioEngine
    private let player: AVAudioPlayerNode
    private var tapped = false

    /// What the player plays: Apple's voices are converted to it.
    nonisolated static var playFormat: AVAudioFormat { AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)! }

    /// The engine stopped under us: another device took the audio route (headphones, a call), or iOS interrupted.
    var onLost: (() -> Void)?
    private var watchers: [NSObjectProtocol] = []

    private init(_ purpose: Purpose, _ built: Built) {
        self.purpose = purpose
        engine = built.engine
        player = built.player
        echoCancelling = built.echo
        let center = NotificationCenter.default
        // The engine stops itself when the hardware's format changes; a change it rides out leaves it running.
        watchers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: built.engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self, !self.engine.isRunning { self.onLost?() } }
        })
        #if os(iOS)
        watchers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
            MainActor.assumeIsolated { if began { self?.onLost?() } }
        })
        #endif
    }

    /// Sets up the audio session and starts the engine. Both can take a moment (voice processing most of all), so
    /// they happen off the main thread.
    static func start(_ purpose: Purpose) async throws -> AudioRig {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        switch purpose {
        case .read: try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        case .dictate: try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        case .talk: try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        }
        _ = try await session.activate(options: [])
        #endif
        let built = try await Task.detached(priority: .userInitiated) { try build(purpose) }.value
        return AudioRig(purpose, built)
    }

    private struct Built: Sendable {
        let engine: AVAudioEngine
        let player: AVAudioPlayerNode
        let echo: Bool
    }

    private nonisolated static func build(_ purpose: Purpose) throws -> Built {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        // The player joins the graph before voice processing starts.
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        var echo = false
        // Reading aloud never touches the microphone.
        if purpose != .read {
            let input = engine.inputNode
            #if !targetEnvironment(simulator)
            // (The simulator's audio server deadlocks setting voice processing up.)
            if purpose == .talk {
                do {
                    try input.setVoiceProcessingEnabled(true)
                    echo = true
                    // Other apps' audio stays as loud as it can.
                    input.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: true, duckingLevel: .min)
                } catch {
                    echo = false
                }
            }
            #endif
            let format = input.outputFormat(forBus: 0)
            guard format.channelCount > 0, format.sampleRate > 0 else { throw VoiceError.noMicrophone }
        }
        engine.prepare()
        try engine.start()
        return Built(engine: engine, player: player, echo: echo)
    }

    /// Hands every microphone buffer to `take`, on the audio thread.
    func tap(_ take: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        untap()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw VoiceError.noMicrophone }
        input.installTap(onBus: 0, bufferSize: 2048, format: format, block: Self.block(take))
        tapped = true
    }

    func untap() {
        guard tapped else { return }
        engine.inputNode.removeTap(onBus: 0)
        tapped = false
    }

    /// Plays a buffer (in `playFormat`) after the ones before it; `done` runs, on the audio thread, once it's heard.
    func play(_ buffer: AVAudioPCMBuffer, done: @escaping @Sendable () -> Void) {
        if !engine.isRunning { try? engine.start() }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack, completionHandler: Self.completion(done))
        if !player.isPlaying { player.play() }
    }

    /// Drops whatever is still to be played.
    func silence() { player.stop() }

    /// Stops the engine and lets other apps' audio back, off the main thread; returns once that's done, so a rig
    /// started next can't be cut off by this one.
    func close() async {
        for w in watchers { NotificationCenter.default.removeObserver(w) }
        watchers = []
        onLost = nil
        untap()
        let engine = self.engine, player = self.player, echo = echoCancelling
        await Task.detached(priority: .userInitiated) {
            player.stop()
            engine.stop()
            if echo { try? engine.inputNode.setVoiceProcessingEnabled(false) }
            #if os(iOS)
            _ = try? await AVAudioSession.sharedInstance().deactivate(options: .notifyOthersOnDeactivation)
            #endif
        }.value
    }

    // Made outside the main actor: the engine calls them on its own threads.
    private nonisolated static func block(_ take: @escaping @Sendable (AVAudioPCMBuffer) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in take(buffer) }
    }

    private nonisolated static func completion(_ done: @escaping @Sendable () -> Void) -> AVAudioPlayerNodeCompletionHandler {
        { _ in done() }
    }
}

/// The microphone's loudness, measured on the audio thread and read by the meter as it draws.
final class Meter: Sendable {
    private let value = Mutex<Float>(0)

    func take(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += samples[i] * samples[i] }
        let db = 20 * log10(max((sum / Float(n)).squareRoot(), 1e-6))
        // -55 dB is quiet, -10 dB loud; it rises at once and falls back slowly.
        let level = max(0, min(1, (db + 55) / 45))
        value.withLock { $0 = max(level, $0 * 0.8) }
    }

    func reset() { value.withLock { $0 = 0 } }

    var level: Float { value.withLock { $0 } }
}

/// Speaks through the rig: sentences are synthesized one after another and played as their audio arrives.
@MainActor
final class Speaker {
    private let synth = Synthesizer()
    private var queue: [String] = []
    private var running: Task<Void, Never>?
    private var unplayed = 0
    private var generation = 0
    /// What's been said since the last stop (synthesis runs ahead of what's heard), to tell Duet's own voice from yours.
    private(set) var recent = ""
    var onDone: (() -> Void)?

    var isSpeaking: Bool { running != nil || unplayed > 0 }

    func say(_ sentences: [String], on rig: AudioRig, voice: AVSpeechSynthesisVoice?, rate: Float) {
        guard !sentences.isEmpty else { return }
        queue += sentences
        guard running == nil else { return }
        let gen = generation
        running = Task { [weak self] in
            while let self, gen == self.generation, !self.queue.isEmpty {
                let sentence = self.queue.removeFirst()
                self.recent = Array((self.recent + " " + sentence).split(separator: " ").suffix(400)).joined(separator: " ")
                let converter = PCMConverter(to: AudioRig.playFormat)
                for await pcm in self.synth.speak(sentence, voice: voice, rate: rate) {
                    guard gen == self.generation else { break }
                    if let b = converter.convert(pcm.buffer) { self.schedule(b, on: rig, gen) }
                }
                if gen == self.generation, let tail = converter.flush() { self.schedule(tail, on: rig, gen) }
            }
            guard let self, gen == self.generation else { return }
            self.running = nil
            self.finishIfDone()
        }
    }

    func stop(_ rig: AudioRig?) {
        generation += 1
        recent = ""
        queue.removeAll()
        running?.cancel()
        running = nil
        synth.stop()
        rig?.silence()
        unplayed = 0
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, on rig: AudioRig, _ gen: Int) {
        unplayed += 1
        rig.play(buffer) { [weak self] in Task { @MainActor in self?.played(gen) } }
    }

    private func played(_ gen: Int) {
        guard gen == generation else { return }
        unplayed = max(0, unplayed - 1)
        finishIfDone()
    }

    private func finishIfDone() {
        guard running == nil, unplayed == 0 else { return }
        onDone?()
    }
}

// MARK: voice

/// Voice for the whole app, one use at a time: dictation into a message, Talk mode with Claude or in a side chat, and
/// replies read aloud. Apple's on-device recognizer hears you (SpeechAnalyzer: the model Notes and Voice Memos use,
/// on the Neural Engine, nothing sent anywhere); Apple's voices speak, through the same audio engine.
@MainActor
@Observable
final class VoiceController {
    enum Mode: Equatable {
        case off
        case dictating(field: String)
        case talking
        case reading(id: String)
    }

    /// Where Talk mode is, while it's on: your turn, Claude's, or Duet speaking Claude's reply.
    enum Phase: Equatable { case starting, listening, working, speaking, paused }

    /// Who Talk mode talks with: Claude, or a side chat (`key` names the side chat window or sheet that started it).
    enum Target: Equatable {
        case conversation
        case side(key: String, chatId: String?, about: SideAbout?, model: String?)
    }

    private(set) var mode: Mode = .off
    private(set) var phase: Phase = .starting
    private(set) var target: Target = .conversation
    /// What you're saying now.
    private(set) var transcript = LiveTranscript()
    /// What's being set up, when that takes a moment (the first time a language's model downloads).
    private(set) var preparing: String?
    private(set) var problem: String?
    /// What Duet is saying, as a caption.
    private(set) var caption: String?
    /// Whether Duet can be talked over: the echo canceller is on.
    private(set) var canTalkOver = false
    let meter = Meter()

    @ObservationIgnored weak var model: AppModel? {
        // Tidying waits while the app's other Apple Intelligence work has the model.
        didSet { Task { [weak model] in await OnDevice.polisher.busyWhen { model?.apple.isBusy ?? false } } }
    }
    @ObservationIgnored private var rig: AudioRig?
    /// One recognizer for the whole session (a dictation, or Talk mode from start to end), held while Duet speaks.
    @ObservationIgnored private var recognizer: Recognizer?
    /// The microphone's audio on its way to the recognizer, kept while it loads.
    @ObservationIgnored private var intake: AudioIntake?
    /// Audio is dropped, not heard: Claude's turn, paused, or Duet speaking without echo cancelling.
    @ObservationIgnored private var muted = false
    /// Counts sessions, so a tidy that comes back after its session ended goes to the right place, or nowhere.
    @ObservationIgnored private var session = 0
    /// Listening has really started: audio is reaching the recognizer (the start chime waits for this).
    @ObservationIgnored private var flowing = false
    @ObservationIgnored private var cued = false
    /// Your turn is being settled before it's sent.
    @ObservationIgnored private var ending = false
    @ObservationIgnored private var hearing: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: AppIdentity.bundleID, category: "voice")
    @ObservationIgnored private var clock: Task<Void, Never>?
    @ObservationIgnored private let speaker = Speaker()
    @ObservationIgnored private var lastHeard = Date.distantPast
    /// Talk mode speaks replies in turns after this one; how many of each turn's messages it has spoken.
    @ObservationIgnored private var afterTurn = 0
    @ObservationIgnored private var spoken: [Int: Int] = [:]
    /// A side chat's answers already spoken.
    @ObservationIgnored private var sideSpoken = 0
    /// The last thing sent, until its turn shows up.
    @ObservationIgnored private var awaiting: String?
    @ObservationIgnored private var sentAt: Date?
    /// Speech that arrived while you were talking: said once you've finished.
    @ObservationIgnored private var held: [String] = []
    /// The Talk panel is out of sight: the microphone doesn't listen until it's back.
    @ObservationIgnored private var hidden = false
    @ObservationIgnored private var pausedByHiding = false

    init() {
        speaker.onDone = { [weak self] in self?.speechDone() }
    }

    // MARK: settings

    private var defaults: UserDefaults { .standard }
    var language: String { defaults.string(forKey: VoiceSettings.language).flatMap { $0.isEmpty ? nil : $0 } ?? Locale.current.identifier }
    private var rate: Float { Float(defaults.object(forKey: VoiceSettings.rate) as? Double ?? VoiceSettings.defaultRate) }
    private var pauseLength: Double { defaults.object(forKey: VoiceSettings.pause) as? Double ?? VoiceSettings.defaultPause }
    private var speakReplies: Bool { defaults.object(forKey: VoiceSettings.speakReplies) as? Bool ?? true }
    private var talkOver: Bool { defaults.object(forKey: VoiceSettings.talkOver) as? Bool ?? true }
    private var readFull: Bool { defaults.object(forKey: VoiceSettings.readFull) as? Bool ?? false }
    private var voice: AVSpeechSynthesisVoice? { Synthesizer.voice(id: defaults.string(forKey: VoiceSettings.voice), language: language) }
    private var cleanUp: Bool { defaults.object(forKey: VoiceSettings.cleanUp) as? Bool ?? true }
    private var preset: SpeechPreset { SpeechPreset(rawValue: defaults.string(forKey: VoiceSettings.preset) ?? "") ?? .accurate }

    /// Names a general model might mishear: Duet's own, the workers', the project folder's, and the files Claude
    /// touched lately.
    private var vocabulary: [String] {
        var words = ["Claude", "Doublet"] + (model?.store.workers.map(\.id) ?? [])
        if let cwd = model?.store.leadCwd, let folder = cwd.split(separator: "/").last { words.append(String(folder)) }
        words += recentFiles()
        var seen = Set<String>()
        return words.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// The names of files the last few turns read or edited ("fleet.ts", and "fleet" as it's said).
    private func recentFiles() -> [String] {
        guard let turns = model?.store.turns.suffix(4) else { return [] }
        var out: [String] = []
        for turn in turns.reversed() {
            for item in turn.items {
                guard case .tool(_, _, let input) = item,
                      let r = input.range(of: #""(file_path|notebook_path|path)"\s*:\s*"[^"]+""#, options: .regularExpression) else { continue }
                let path = input[r].split(separator: "\"").dropLast().last.map(String.init) ?? ""
                guard let name = path.split(separator: "/").last.map(String.init), !name.isEmpty else { continue }
                out.append(name)
                if let stem = name.split(separator: ".").first, stem.count >= 3 { out.append(String(stem)) }
            }
        }
        return Array(out.prefix(30))
    }

    // MARK: dictation

    func isDictating(_ field: String) -> Bool { mode == .dictating(field: field) }

    var isDictating: Bool { if case .dictating = mode { true } else { false } }

    /// What dictation last put in its field, to notice when you type there instead.
    private(set) var dictated: String?
    @ObservationIgnored private var dictationBase = ""
    @ObservationIgnored private var dictationApply: ((String) -> Void)?

    /// A dictation just stopped: for a few seconds, tidies still on their way go into its field (unless you've
    /// changed it since), and Undo puts back what you said word for word.
    struct Afterwards {
        let field: String
        let session: Int
        let base: String
        let apply: (String) -> Void
        var transcript: LiveTranscript
        var written: String
        var until: Date
    }
    @ObservationIgnored private var afterwards: Afterwards?
    /// The field whose dictation was tidied and can be undone (shown as Undo under it).
    private(set) var undoableField: String?

    /// Types what you say into a field, live, after what's already in it (`text`); `apply` sets the field.
    func startDictation(_ field: String, into text: String, apply: @escaping (String) -> Void) async {
        ProblemReports.note("dictation start")
        await stop()
        problem = nil
        guard await microphoneAllowed() else { return }
        mode = .dictating(field: field)
        dictationBase = text
        dictationApply = apply
        dictated = text
        prewarmTidying()
        do {
            let rig = try await AudioRig.start(.dictate)
            // Stopped while the audio was starting.
            guard mode == .dictating(field: field) else { await rig.close(); return }
            self.rig = rig
            rig.onLost = { [weak self] in self?.lost() }
            try await openSession()
        } catch {
            fail(error)
        }
    }

    /// Stops dictating: what was still a guess is settled and goes in the field, and the last sentence is tidied.
    func stopDictation() async {
        guard case .dictating(let field) = mode else { return }
        rig?.untap()
        intake?.detach()
        let rec = recognizer
        recognizer = nil
        await rec?.finish()
        await hearing?.value
        // Everything heard is settled now, and goes in the field.
        transcript.end()
        applyField()
        cue(.stop)
        polishPending(all: true)
        if let apply = dictationApply {
            afterwards = Afterwards(field: field, session: session, base: dictationBase, apply: apply, transcript: transcript,
                                    written: dictated ?? "", until: Date().addingTimeInterval(3))
            undoableField = transcript.isTidied ? field : nil
            expireAfterwards()
        }
        await stop()
    }

    /// You typed in the field. While dictating, what you say next goes after what's there now; just after, the
    /// field is yours again (no late tidy overwrites it).
    func fieldChanged(_ field: String, to text: String) {
        if isDictating(field) {
            guard text != dictated else { return }
            dictationBase = text
            dictated = text
            transcript.reset(after: transcript.lastHeard)
            return
        }
        if let a = afterwards, a.field == field, text != a.written {
            afterwards = nil
            undoableField = nil
        }
    }

    /// You typed in the field: dictation stops and leaves the field as you made it.
    func abandonDictation() {
        guard case .dictating = mode else { return }
        dictationApply = nil
        end()
    }

    /// Puts back exactly what you said, in place of Apple Intelligence's tidy.
    func undoTidy(_ field: String) {
        if isDictating(field) {
            transcript.showsTidy = false
            applyField()
        } else if var a = afterwards, a.field == field {
            a.transcript.showsTidy = false
            a.written = LiveTranscript.join(a.base, a.transcript.text)
            a.apply(a.written)
            afterwards = a
        }
        undoableField = nil
    }

    private func expireAfterwards() {
        let s = session
        Task { [weak self] in
            while let self, let a = self.afterwards, a.session == s {
                let left = a.until.timeIntervalSinceNow
                if left <= 0 { self.afterwards = nil; self.undoableField = nil; return }
                try? await Task.sleep(for: .seconds(left))
            }
        }
    }

    private func applyField() {
        guard case .dictating = mode, let apply = dictationApply else { return }
        let text = LiveTranscript.join(dictationBase, transcript.text)
        guard text != dictated else { return }
        dictated = text
        apply(text)
    }

    // MARK: Talk mode

    var isTalking: Bool { mode == .talking }

    func isTalking(in key: String) -> Bool {
        guard mode == .talking, case .side(let k, _, _, _) = target else { return false }
        return k == key
    }

    var isTalkingWithClaude: Bool { mode == .talking && target == .conversation }

    /// The side chat Talk mode started, once it has an id.
    var sideChatId: String? {
        if case .side(_, let id, _, _) = target { id } else { nil }
    }

    func startTalk(_ target: Target) async {
        ProblemReports.note("talk start")
        await stop()
        problem = nil
        guard await microphoneAllowed() else { return }
        self.target = target
        mode = .talking
        phase = .starting
        // Replies from now on are spoken.
        afterTurn = model?.store.turns.last?.id ?? 0
        spoken = [:]
        sideSpoken = sideAnswers().count
        awaiting = nil
        held = []
        hidden = false
        pausedByHiding = false
        prewarmTidying()
        do {
            let rig = try await AudioRig.start(.talk)
            guard mode == .talking else { await rig.close(); return }
            self.rig = rig
            rig.onLost = { [weak self] in self?.lost() }
            canTalkOver = rig.echoCancelling
            try await openSession()
            // Ended while the recognizer was starting.
            guard mode == .talking else { return }
            startClock()
        } catch {
            fail(error)
        }
    }

    /// Sends what you've said without waiting for a pause.
    func sendNow() {
        guard mode == .talking, phase == .listening, !transcript.isEmpty else { return }
        finishTurn()
    }

    /// Stops Duet speaking (Claude's reply stays on screen).
    func skipSpeech() {
        guard mode == .talking, phase == .speaking else { return }
        speaker.stop(rig)
        caption = nil
        held = []
        afterSpeech()
    }

    /// Your turn now, even while Claude works: what you say goes to Claude when it's free.
    func talkNow() {
        guard mode == .talking, phase == .working || phase == .paused else { return }
        resumeListening(after: 0)
    }

    func pause() {
        guard mode == .talking, phase == .listening else { return }
        mute()
        transcript.reset(after: transcript.lastHeard)
        phase = .paused
        pausedByHiding = false
    }

    /// The Talk panel came into view or went out of it. The microphone only listens while you can see the panel;
    /// a reply being read carries on, and listening picks up again when the panel is back.
    func panel(visible: Bool) {
        guard mode == .talking else { return }
        hidden = !visible
        if !visible, phase == .listening {
            mute()
            transcript.reset(after: transcript.lastHeard)
            phase = .paused
            pausedByHiding = true
        } else if visible, pausedByHiding, phase == .paused {
            pausedByHiding = false
            resumeListening(after: 0)
        }
    }

    // MARK: reading aloud

    func isReading(_ id: String) -> Bool { mode == .reading(id: id) }

    func read(_ markdown: String, id: String) async {
        await stop()
        problem = nil
        let sentences = Speakable.sentences(Speakable.text(markdown))
        guard !sentences.isEmpty else { return }
        do {
            mode = .reading(id: id)
            let rig = try await AudioRig.start(.read)
            guard mode == .reading(id: id) else { await rig.close(); return }
            self.rig = rig
            rig.onLost = { [weak self] in self?.lost() }
            speaker.say(sentences, on: rig, voice: voice, rate: rate)
        } catch {
            fail(error)
        }
    }

    // MARK: stopping

    /// Ends whatever voice is doing.
    func stop() async {
        clock?.cancel()
        clock = nil
        speaker.stop(rig)
        let rec = closeSession()
        let closing = rig
        rig = nil
        // Off at once, so nothing started meanwhile carries on; then the audio winds down.
        mode = .off
        phase = .starting
        caption = nil
        preparing = nil
        transcript.reset()
        meter.reset()
        held = []
        awaiting = nil
        sentAt = nil
        dictationApply = nil
        dictated = nil
        ending = false
        // The recognizer lets go before the audio does, so the next session can't trip over it.
        await rec?.cancel()
        await closing?.close()
    }

    func end() { Task { await stop() } }

    // MARK: listening

    /// Starts hearing you for this session: the microphone first (what it hears is kept), then the recognizer, which
    /// takes what was kept. The start chime plays once audio is flowing and the recognizer has it.
    private func openSession() async throws {
        guard let rig else { return }
        session += 1
        transcript.reset()
        lastHeard = Date()
        flowing = false
        cued = false
        muted = false
        let intake = AudioIntake()
        self.intake = intake
        let meter = self.meter
        let s = session
        intake.onFirstAudio { [weak self] in Task { @MainActor in if self?.session == s { self?.flowing = true; self?.ready() } } }
        try rig.tap { buffer in
            meter.take(buffer)
            intake.take(buffer)
        }
        let name = Locale.current.localizedString(forIdentifier: language) ?? language
        let started = Date()
        let rec = try await Recognizer.start(locale: Locale(identifier: language), vocabulary: vocabulary, preset: preset) { [weak self] progress in
            Task { @MainActor in
                self?.preparing = progress < 1 ? "Downloading Apple's speech model for \(name) (\(Int(progress * 100))%)" : nil
            }
        }
        preparing = nil
        // Stopped while the model was loading.
        guard self.rig === rig, session == s, mode != .off else { await rec.cancel(); return }
        log.info("recognizer \(rec.model.rawValue, privacy: .public) \(self.preset.rawValue, privacy: .public) ready in \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s, \(intake.backlogSeconds, format: .fixed(precision: 1))s kept")
        recognizer = rec
        intake.attach(rec)
        hearing = Task { [weak self] in
            for await h in rec.heard { self?.heard(h, from: rec) }
        }
        ready()
    }

    /// Audio flows and the recognizer has it: listening, with the chime.
    private func ready() {
        guard flowing, recognizer != nil, !cued, preparing == nil else { return }
        cued = true
        if mode == .talking, phase == .starting { phase = .listening }
        if mode != .off { cue(.start) }
    }

    /// Ends the session's listening; returns the recognizer for the caller to wait on as it lets go.
    private func closeSession() -> Recognizer? {
        rig?.untap()
        intake?.detach()
        intake = nil
        let rec = recognizer
        recognizer = nil
        hearing?.cancel()
        hearing = nil
        meter.reset()
        return rec
    }

    /// Stops taking audio, keeping the recognizer (Claude's turn, paused, or Duet speaking).
    private func mute() {
        muted = true
        intake?.pause(true)
        meter.reset()
    }

    /// Takes audio again, from now: what was heard before is dropped.
    private func unmute() {
        transcript.reset(after: max(transcript.lastHeard, recognizer?.heardThrough ?? 0))
        lastHeard = Date()
        muted = false
        intake?.pause(false)
    }

    private func heard(_ h: Recognizer.Heard, from rec: Recognizer) {
        guard rec === recognizer || mode == .off || recognizer == nil else { return }
        if h.isFinal, let end = h.runs.last?.end {
            log.debug("final \(h.text.count) chars, \(rec.heardThrough - end, format: .fixed(precision: 2))s behind the audio")
        }
        let before = transcript.raw
        transcript.apply(h)
        if transcript.raw != before { lastHeard = Date() }
        applyField()
        polishPending()
        // Talking over Duet stops it; its own voice coming back doesn't.
        if mode == .talking, phase == .speaking, BargeIn.isYou(transcript.raw, saying: speaker.recent) {
            speaker.stop(rig)
            caption = nil
            phase = .listening
            lastHeard = Date()
        }
    }

    // MARK: tidying

    private func prewarmTidying() {
        guard cleanUp else { return }
        Task { await OnDevice.polisher.prewarm(Polish.voiceInstructions) }
    }

    /// Settled sentences go to Apple Intelligence to be tidied, one at a time; each comes back into the transcript
    /// (and the field) if it's still there, or is dropped.
    private func polishPending(all: Bool = false) {
        guard cleanUp else { return }
        let vocabulary = self.vocabulary
        for sentence in transcript.untidied(all: all) {
            transcript.asking(sentence)
            let before = transcript.before(sentence), s = session
            Task { [weak self] in
                let started = Date()
                let outcome = await OnDevice.polisher.polishSpeech(sentence, before: before, vocabulary: vocabulary)
                self?.tidied(sentence, outcome, session: s, took: Date().timeIntervalSince(started))
            }
        }
    }

    private func tidied(_ sentence: String, _ outcome: DictationPolisher.Outcome, session s: Int, took: TimeInterval) {
        log.info("tidy \(String(describing: outcome), privacy: .private) in \(took, format: .fixed(precision: 2))s")
        guard let tidy = outcome.text else { return }
        if s == session, mode != .off {
            transcript.tidy(sentence, as: tidy)
            applyField()
            if case .dictating(let field) = mode, transcript.isTidied { undoableField = field }
        } else if var a = afterwards, a.session == s, Date() < a.until {
            a.transcript.tidy(sentence, as: tidy)
            guard a.transcript.showsTidy else { return }
            a.written = LiveTranscript.join(a.base, a.transcript.text)
            a.apply(a.written)
            // A little longer to undo it.
            a.until = max(a.until, Date().addingTimeInterval(3))
            afterwards = a
            undoableField = a.field
        }
    }

    /// Ends your turn after a pause.
    private func startClock() {
        clock?.cancel()
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                guard let self else { return }
                if self.mode == .talking, self.phase == .listening, self.recognizer != nil, !self.muted, !self.ending,
                   TurnTimer(pause: self.pauseLength).isOver(self.transcript.raw, quietFor: Date().timeIntervalSince(self.lastHeard)) {
                    self.finishTurn()
                }
                self.checkSent()
            }
        }
    }

    /// Ends your turn: the recognizer settles what it has (at most half a second), then what's on screen is sent.
    private func finishTurn() {
        guard mode == .talking, phase == .listening, !transcript.isEmpty, !ending else { return }
        ending = true
        phase = .working
        let rec = recognizer, s = session
        Task { [weak self] in
            var through: Double?
            if let rec {
                through = await rec.settle(within: .milliseconds(500))
                // The finals come down the stream just after.
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard let self, self.session == s, self.mode == .talking, self.ending else { return }
            // Final through here even if no final came for it (an unchanged guess gets none).
            if let through { self.transcript.promote(through: through) }
            self.ending = false
            self.sendTurn()
        }
    }

    private func sendTurn() {
        let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { resumeListening(after: 0); return }
        mute()
        transcript.reset(after: transcript.lastHeard)
        awaiting = text
        sentAt = Date()
        cue(.sent)
        Task { await send(text) }
        // Claude's words that waited for you to finish.
        if !held.isEmpty {
            let waiting = held
            held = []
            say(waiting)
        }
    }

    /// What you said never showed up as a turn while Claude was free: the hub didn't take it. Your turn again.
    private func checkSent() {
        guard mode == .talking, phase == .working, awaiting != nil, let sentAt, Date().timeIntervalSince(sentAt) > 15,
              target == .conversation, model?.store.leadStatus.busy != true else { return }
        awaiting = nil
        self.sentAt = nil
        problem = "Claude didn't get that. Say it again, or check the connection."
        resumeListening(after: 0)
    }

    private func send(_ text: String) async {
        guard let model else { return }
        switch target {
        case .conversation:
            model.send(.prompt(text: text, voice: true))
        case .side(let key, let chatId, let about, let choice):
            do {
                let id = try await model.askSide(text, chatId: chatId, about: about, model: choice, voice: true)
                if case .side(key, _, _, _) = target { target = .side(key: key, chatId: id, about: about, model: choice) }
            } catch {
                problem = error.localizedDescription
                resumeListening(after: 0)
            }
        }
    }

    /// Back to your turn. After Duet has spoken, the microphone waits a moment for the room to go quiet, and starts
    /// afresh from then, so nothing it half-heard of Duet's voice carries over. The recognizer is the same one.
    private func resumeListening(after delay: Double) {
        guard mode == .talking else { return }
        mute()
        guard !hidden else {
            phase = .paused
            pausedByHiding = true
            return
        }
        phase = .listening
        let s = session
        Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard let self, self.session == s, self.mode == .talking, self.phase == .listening else { return }
            if self.recognizer == nil {
                do { try await self.openSession() } catch { self.fail(error) }
            } else {
                self.unmute()
            }
        }
    }

    // MARK: replies

    /// Speaks what Claude (or the side chat) says while Talk mode is on, and gives you the turn when it's done.
    func storeChanged(_ s: DuetStore) {
        guard mode == .talking else { return }
        var fresh: [String] = []
        let busy: Bool
        switch target {
        case .conversation:
            for turn in s.turns.reversed() {
                guard turn.id > afterTurn else { break }
                if turn.prompt == awaiting { awaiting = nil; sentAt = nil }
                let texts = turn.items.compactMap { item -> String? in if case .text(_, let t) = item { t } else { nil } }
                let done = spoken[turn.id, default: 0]
                if texts.count > done {
                    fresh.insert(contentsOf: texts[done...], at: 0)
                    spoken[turn.id] = texts.count
                }
            }
            busy = awaiting != nil || s.leadStatus.busy
        case .side:
            let answers = sideAnswers()
            if answers.count > sideSpoken {
                fresh = Array(answers[sideSpoken...])
                sideSpoken = answers.count
                awaiting = nil
            }
            busy = awaiting != nil || sideChat()?.isAnswering == true
        }
        // A long reply: its start, then "there's more on screen" (unless Settings asks for all of it).
        for text in fresh {
            let sentences = Speakable.sentences(Speakable.text(text))
            say(readFull ? sentences : Speakable.brief(sentences))
        }
        if phase == .working, !busy, !speaker.isSpeaking, !ending { resumeListening(after: 0) }
    }

    private func sideChat() -> SideChat? { sideChatId.flatMap { model?.store.sideChats[$0] } }

    private func sideAnswers() -> [String] { sideChat()?.messages.filter { !$0.isUser }.map(\.text) ?? [] }

    /// Status for the panel while Claude works.
    var workingLabel: String {
        switch target {
        case .conversation:
            guard let s = model?.store, s.leadStatus.busy else { return awaiting == nil ? "Claude is finishing" : "Sending to Claude" }
            return "Claude: \(s.leadStatus.label)"
        case .side:
            guard let chat = sideChat(), chat.isAnswering else { return "Asking" }
            return SideChatView.activity(chat.activity)
        }
    }

    private func say(_ sentences: [String]) {
        guard speakReplies, let rig, !sentences.isEmpty else { return }
        // You're mid-sentence: Duet waits for you to finish.
        if phase == .listening, !transcript.isEmpty {
            held += sentences
            return
        }
        speaker.say(sentences, on: rig, voice: voice, rate: rate)
        caption = [caption, sentences.joined(separator: " ")].compactMap { $0 }.joined(separator: " ")
        if phase != .speaking {
            phase = .speaking
            // With echo cancelling, keep listening so you can talk over Duet (while you can see the panel).
            if canTalkOver, talkOver, !hidden {
                if recognizer == nil { Task { [weak self] in try? await self?.openSession() } } else if muted { unmute() }
            } else {
                mute()
            }
        }
    }

    private func speechDone() {
        caption = nil
        switch mode {
        case .reading: Task { await stop() }
        case .talking where phase == .speaking: afterSpeech()
        default: break
        }
    }

    private func afterSpeech() {
        let working: Bool
        switch target {
        case .conversation: working = awaiting != nil || model?.store.leadStatus.busy == true
        case .side: working = awaiting != nil || sideChat()?.isAnswering == true
        }
        if working {
            mute()
            phase = .working
        } else {
            resumeListening(after: 0.5)
            cue(.start)
        }
    }

    // MARK: helpers

    /// The audio stopped under us. Talk mode starts again on the new route (what you were saying is lost); dictation
    /// and reading stop, and say why.
    private func lost() {
        switch mode {
        case .talking:
            let again = target
            Task {
                await stop()
                await startTalk(again)
            }
        case .dictating, .reading:
            problem = "The audio changed (headphones, or a call), so Doublet stopped listening."
            end()
        case .off:
            break
        }
    }

    private func microphoneAllowed() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied:
            problem = VoiceError.microphoneDenied.localizedDescription
            return false
        default:
            let ok = await AVAudioApplication.requestRecordPermission()
            if !ok { problem = VoiceError.microphoneDenied.localizedDescription }
            return ok
        }
    }

    private func fail(_ error: Error) {
        problem = error.localizedDescription
        Task { await stop() }
    }

    func clearProblem() { problem = nil }

    #if DEBUG
    /// Previews: Talk mode at one moment, without a microphone.
    func preview(_ phase: Phase, said: String = "", guess: String = "", caption: String? = nil) {
        mode = .talking
        self.phase = phase
        transcript.reset()
        if !said.isEmpty { transcript.apply(said, isFinal: true) }
        if !guess.isEmpty { transcript.apply(guess, isFinal: false) }
        self.caption = caption
        canTalkOver = true
    }
    #endif

    private enum Cue { case start, sent, stop }

    /// The system's own recording sounds: listening started, and your words went.
    private func cue(_ c: Cue) {
        #if os(iOS)
        AudioServicesPlaySystemSound(c == .start ? 1113 : 1114)
        #else
        NSSound(named: c == .start ? "Tink" : "Pop")?.play()
        #endif
    }
}
