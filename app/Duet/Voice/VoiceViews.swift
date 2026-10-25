import AVFoundation
import DuetKit
import SwiftUI

/// Dictation into a text field: what you say is typed, live, after what's already there. Typing yourself stops it.
struct MicButton: View {
    @Environment(AppModel.self) private var model
    let field: String
    @Binding var text: String

    var body: some View {
        let voice = model.voice
        let on = voice.isDictating(field)
        Button(on ? "Stop Dictating" : "Dictate", systemImage: on ? "mic.fill" : "mic") {
            if on {
                Task { await voice.stopDictation() }
            } else {
                Task { await voice.startDictation(field, into: text) { text = $0 } }
            }
        }
        .labelStyle(.iconOnly)
        .foregroundStyle(on ? AnyShapeStyle(.stateFailed) : AnyShapeStyle(.secondary))
        .symbolEffect(.pulse, options: .repeating, isActive: on)
        .contentTransition(.symbolEffect(.replace))
        .help(on ? "Stop dictating" : "Dictate: Apple's on-device speech recognition types what you say")
        // Typing while dictating: what you say next goes after what you typed.
        .onChange(of: text) { _, now in voice.fieldChanged(field, to: now) }
        .accessibilityIdentifier("dictate-\(field)")
    }
}

/// Starts Talk mode: say something, pause, hear the answer, carry on.
struct TalkButton: View {
    @Environment(AppModel.self) private var model
    let target: VoiceController.Target
    var big = false

    var body: some View {
        Button("Talk", systemImage: "waveform.circle.fill") {
            Task { await model.voice.startTalk(target) }
        }
        .labelStyle(.iconOnly)
        .font(big ? .largeTitle : .title)
        .help("Talk mode: say what you want, pause, and hear the reply (⌘⇧T)")
        .accessibilityIdentifier("talk")
    }
}

/// Talk mode, in place of the composer: the microphone's level, what you're saying, then what Claude is doing and
/// saying, with the buttons that fit the moment.
struct TalkPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.density) private var density

    var body: some View {
        let v = model.voice
        VStack(alignment: .leading, spacing: 8) {
            if let p = v.problem { ProblemLine(text: p) { v.clearProblem() } }
            HStack(alignment: .center, spacing: 12) {
                TalkOrb(meter: v.meter, phase: v.phase)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(v)).font(.subheadline.weight(.semibold)).lineLimit(1)
                    detail(v).font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .animation(.snappy, value: v.phase)
                controls(v)
            }
        }
        .padding(.horizontal, density == .compact ? 12 : 16).padding(.vertical, 10)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("talk-panel")
        // The microphone listens only while you can see this.
        .onAppear { model.voice.panel(visible: true) }
        .onDisappear { model.voice.panel(visible: false) }
    }

    private func title(_ v: VoiceController) -> String {
        switch v.phase {
        case .starting: v.preparing ?? "Getting the microphone ready"
        case .listening: v.transcript.isEmpty ? "Listening" : "Hearing you"
        case .working: v.workingLabel
        case .speaking: v.canTalkOver ? "Speaking · talk to interrupt" : "Speaking"
        case .paused: "Paused"
        }
    }

    @ViewBuilder
    private func detail(_ v: VoiceController) -> some View {
        switch v.phase {
        case .listening where !v.transcript.isEmpty:
            // All of what you've said, scrolled to the newest words.
            PinnedText(transcript: v.transcript, lines: density == .compact ? 3 : 4)
        case .listening:
            Text("Say what you want, then pause to send.").foregroundStyle(.secondary)
        case .speaking:
            Text(v.caption ?? "").foregroundStyle(.secondary).lineLimit(density == .compact ? 2 : 3)
        case .working:
            Text("Tap the microphone to add something.").foregroundStyle(.secondary)
        case .paused:
            Text("The microphone is off.").foregroundStyle(.secondary)
        case .starting:
            Text("Doublet listens with Apple's on-device speech recognition.").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func controls(_ v: VoiceController) -> some View {
        HStack(spacing: 12) {
            switch v.phase {
            case .listening:
                if !v.transcript.isEmpty {
                    Button("Send Now", systemImage: "arrow.up.circle.fill") { v.sendNow() }
                        .keyboardShortcut(.return, modifiers: .command)
                }
                Button("Pause", systemImage: "pause.circle") { v.pause() }
            case .working:
                Button("Talk Now", systemImage: "mic.circle") { v.talkNow() }
                if v.target == .conversation, model.store.leadStatus.busy {
                    Button("Stop Claude", systemImage: "stop.circle.fill") { model.send(.interrupt) }
                        .foregroundStyle(.stateFailed)
                }
            case .speaking:
                Button("Skip", systemImage: "forward.end.circle") { v.skipSpeech() }
            case .paused:
                Button("Resume", systemImage: "mic.circle.fill") { v.talkNow() }
            case .starting:
                EmptyView()
            }
            Button("End Talk Mode", systemImage: "xmark.circle.fill") { v.end() }
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
        }
        .labelStyle(.iconOnly)
        .font(.title2)
        .buttonStyle(.borderless)
    }
}

/// What you're saying, as it's heard: sentences Apple Intelligence has tidied, the words the recognizer has settled
/// on, and its guess at the rest, fainter (it can still change). It keeps to a few lines and stays scrolled to the
/// newest words, so a long thought is all there and the end of it is in view.
struct PinnedText: View {
    let transcript: LiveTranscript
    var lines = 4

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                Text(styled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .id("end")
            }
            .frame(maxHeight: CGFloat(lines) * 21)
            .fixedSize(horizontal: false, vertical: true)
            .defaultScrollAnchor(.bottom)
            .onChange(of: transcript.raw) { proxy.scrollTo("end", anchor: .bottom) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(transcript.text)
    }

    static func styled(_ t: LiveTranscript) -> AttributedString {
        var out = AttributedString()
        for (i, part) in t.parts.enumerated() {
            var piece = AttributedString((i == 0 || part.text.first.map { ",.!?;:".contains($0) } == true ? "" : " ") + part.text)
            switch part.style {
            case .tidied: piece.foregroundColor = .primary
            case .settled: piece.foregroundColor = .primary.opacity(0.85)
            case .guess: piece.foregroundColor = .secondary
            }
            out.append(piece)
        }
        return out
    }

    private var styled: AttributedString { Self.styled(transcript) }
}

/// Under a field you're dictating into: what's being heard (the field shows it too, but the guess is plain there), the
/// model still downloading, and, once a sentence is tidied, Undo for the words exactly as you said them.
struct DictationLive: View {
    @Environment(AppModel.self) private var model
    let field: String

    var body: some View {
        let v = model.voice
        let on = v.isDictating(field)
        let undo = v.undoableField == field
        if on || undo {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if on, let preparing = v.preparing {
                    Label(preparing, systemImage: "arrow.down.circle").foregroundStyle(.secondary)
                } else if on, !v.transcript.isEmpty {
                    PinnedText(transcript: v.transcript, lines: 2)
                } else if on {
                    Label("Listening", systemImage: "waveform").foregroundStyle(.secondary)
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                } else {
                    Label("Tidied by Apple Intelligence", systemImage: "apple.intelligence").foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                if undo {
                    Button("Undo Tidy", systemImage: "arrow.uturn.backward") { v.undoTidy(field) }
                        .buttonStyle(.borderless).labelStyle(.titleAndIcon)
                        .help("Put back exactly what you said")
                        .accessibilityIdentifier("undo-tidy-\(field)")
                }
            }
            .font(.caption)
            .transition(.opacity)
            .accessibilityIdentifier("dictation-live-\(field)")
        }
    }
}

/// Who's talking, at a glance: a circle that swells with your voice while Duet listens, ripples while it speaks, and
/// spins while Claude works.
struct TalkOrb: View {
    let meter: Meter
    let phase: VoiceController.Phase

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: phase != .listening)) { _ in
            let level = phase == .listening ? CGFloat(meter.level) : 0
            ZStack {
                Circle().fill(tint.opacity(0.18)).scaleEffect(1 + level * 0.55)
                Circle().fill(tint.gradient).frame(width: 30, height: 30)
                if phase == .working || phase == .starting {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .symbolEffect(.variableColor.iterative, options: .repeating, isActive: phase == .speaking)
                }
            }
            .frame(width: 44, height: 44)
            .animation(.easeOut(duration: 0.08), value: level)
        }
        .accessibilityHidden(true)
    }

    private var tint: Color {
        switch phase {
        case .listening: .stateWorking
        case .speaking: .purple
        case .working, .starting: .gray
        case .paused: .secondary
        }
    }

    private var symbol: String {
        switch phase {
        case .listening, .starting, .working: "mic.fill"
        case .speaking: "waveform"
        case .paused: "mic.slash.fill"
        }
    }
}

/// A voice problem, with a way to dismiss it.
struct ProblemLine: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Label(text, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.stateFailed)
            Spacer(minLength: 0)
            Button("Dismiss", systemImage: "xmark", action: dismiss).labelStyle(.iconOnly).font(.caption).buttonStyle(.borderless)
        }
    }
}

/// Reads a reply aloud, or stops reading it.
struct ReadAloudButton: View {
    @Environment(AppModel.self) private var model
    let id: String
    let text: () -> String

    var body: some View {
        let reading = model.voice.isReading(id)
        Button(reading ? "Stop Reading" : "Read Aloud", systemImage: reading ? "stop.circle" : "speaker.wave.2") {
            if reading { model.voice.end() } else { Task { await model.voice.read(text(), id: id) } }
        }
        .help(reading ? "Stop reading" : "Read this reply aloud (code and tables stay on screen)")
    }
}

/// Voice in Settings: the language you speak, the voice that reads replies, and how Talk mode takes turns.
struct VoiceSettingsSection: View {
    @Environment(AppModel.self) private var model
    @AppStorage(VoiceSettings.language) private var language = ""
    @AppStorage(VoiceSettings.voice) private var voiceID = ""
    @AppStorage(VoiceSettings.rate) private var rate = VoiceSettings.defaultRate
    @AppStorage(VoiceSettings.pause) private var pause = VoiceSettings.defaultPause
    @AppStorage(VoiceSettings.speakReplies) private var speakReplies = true
    @AppStorage(VoiceSettings.talkOver) private var talkOver = true
    @AppStorage(VoiceSettings.readFull) private var readFull = false
    @AppStorage(VoiceSettings.cleanUp) private var cleanUp = true
    @AppStorage(VoiceSettings.preset) private var preset = SpeechPreset.accurate.rawValue
    @State private var languages: [Locale] = []
    /// The installed voices for the spoken language, best first: listed off the main thread, because asking for them
    /// waits on the speech service (seconds when it's starting up, and for ever on a simulator where it's down).
    @State private var voices: [(id: String, name: String)] = []

    private var spoken: String { language.isEmpty ? Locale.current.identifier : language }

    var body: some View {
        Section {
            Picker("Language", selection: $language) {
                Text("System (\(name(Locale.current.identifier)))").tag("")
                ForEach(languages, id: \.identifier) { Text(name($0.identifier)).tag($0.identifier) }
            }
            Picker("Voice", selection: $voiceID) {
                Text("Best installed").tag("")
                ForEach(voices, id: \.id) { Text($0.name).tag($0.id) }
                // The chosen voice keeps its place while the list loads.
                if !voiceID.isEmpty, !voices.contains(where: { $0.id == voiceID }) { Text("Chosen voice").tag(voiceID) }
            }
            LabeledContent("Speaking rate") {
                Slider(value: $rate, in: 0.42...0.62) { Text("Speaking rate") } minimumValueLabel: {
                    Image(systemName: "tortoise")
                } maximumValueLabel: {
                    Image(systemName: "hare")
                }
            }
            Picker("Recognition", selection: $preset) {
                Text("Accurate").tag(SpeechPreset.accurate.rawValue)
                Text("Fast").tag(SpeechPreset.fast.rawValue)
            }
            Toggle("Clean up what I say", isOn: $cleanUp)
                .onChange(of: cleanUp) { _, on in if on { Task { await OnDevice.polisher.reset() } } }
            Picker("Send after a pause of", selection: $pause) {
                Text("0.8 seconds").tag(0.8)
                Text("1.2 seconds").tag(1.2)
                Text("2 seconds").tag(2.0)
                Text("3 seconds").tag(3.0)
            }
            Toggle("Read replies aloud in Talk mode", isOn: $speakReplies)
            Toggle("Read long replies in full", isOn: $readFull)
                .disabled(!speakReplies)
            Toggle("Talk over Doublet to interrupt it", isOn: $talkOver)
            Button("Hear the Voice", systemImage: "speaker.wave.2") {
                Task { await model.voice.read("This is how Claude's replies sound. Code and tables stay on screen.", id: "sample") }
            }
        } header: {
            Text("Voice")
        } footer: {
            Text("Doublet hears you with Apple's on-device speech recognition, the model Notes and Voice Memos use, so your voice never leaves this device. Accurate waits a moment longer before showing words; Fast shows them sooner. With Clean up on, Apple Intelligence tidies each sentence on this device the way Advanced Dictation does: fillers and repeated words go, a correction (\"the lexer, no wait, the parser\") is applied, and names, paths and numbers stay exactly as said. Undo puts back your words as you said them. In Talk mode a pause sends what you said, a little later after \"and\" or \"um\". A long reply is read up to about 70 words, and the rest stays on screen. For a more natural voice, download an Enhanced or Premium one in Settings › Accessibility › Spoken Content › Voices.")
        }
        .task { languages = await Recognizer.languages().sorted { name($0.identifier) < name($1.identifier) } }
        .task(id: spoken) {
            let lang = spoken
            voices = await Task.detached(priority: .utility) {
                Synthesizer.voices(language: lang).map { v in
                    (v.identifier, v.quality == .premium ? "\(v.name) (Premium)" : v.quality == .enhanced ? "\(v.name) (Enhanced)" : v.name)
                }
            }.value
        }
    }

    private func name(_ id: String) -> String { Locale.current.localizedString(forIdentifier: id) ?? id }
}
