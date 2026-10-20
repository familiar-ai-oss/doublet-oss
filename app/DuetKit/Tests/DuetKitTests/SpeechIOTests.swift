import AVFoundation
import Synchronization
import Testing
@testable import DuetKit

@Test func theConverterResamplesToThePlayersFormat() throws {
    // Apple's voices come as 16-bit audio at their own rate; the player takes 48 kHz floats.
    let voice = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 22_050, channels: 1, interleaved: true))
    let second = try #require(AVAudioPCMBuffer(pcmFormat: voice, frameCapacity: 22_050))
    second.frameLength = 22_050
    let converter = PCMConverter(to: try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)))
    let out = try #require(converter.convert(second))
    #expect(out.format.sampleRate == 48_000 && out.format.commonFormat == .pcmFormatFloat32)
    // The resampler keeps its last few milliseconds until the stream ends.
    let tail = converter.flush()?.frameLength ?? 0
    #expect(abs(Int(out.frameLength + tail) - 48_000) < 100, "a second: \(out.frameLength) + \(tail) frames")
    // The same format passes through untouched.
    #expect(converter.convert(out) === out)
}

@Test func voicesComeBestFirstWithoutNoveltyOnes() {
    let voices = Synthesizer.voices(language: "en-US")
    #expect(!voices.isEmpty, "this Mac has English voices")
    #expect(voices.allSatisfy { !$0.voiceTraits.contains(.isNoveltyVoice) })
    #expect(zip(voices, voices.dropFirst()).allSatisfy { $0.quality.rawValue >= $1.quality.rawValue })
    #expect(Synthesizer.voice(id: "no.such.voice", language: "en-US") != nil, "a voice that's gone falls back to the best one")
}

@Test func presetsMarkWordTimesAndFastGuessesSooner() {
    #expect(SpeechPreset.accurate.transcriber.attributeOptions.contains(.audioTimeRange))
    #expect(SpeechPreset.accurate.transcriber.reportingOptions == [.volatileResults])
    #expect(SpeechPreset.fast.transcriber.reportingOptions.contains(.fastResults))
    #expect(SpeechPreset.accurate.dictation.attributeOptions.contains(.audioTimeRange))
    #expect(SpeechPreset.accurate.dictation.transcriptionOptions.contains(.punctuation), "the dictation fallback keeps punctuation")
    #expect(SpeechPreset.accurate.dictation.reportingOptions.contains(.volatileResults))
}

private final class Collect: AudioSink, @unchecked Sendable {
    var frames: [AVAudioFrameCount] = []
    func feed(_ buffer: AVAudioPCMBuffer) { frames.append(buffer.frameLength) }
}

@Test func theIntakeKeepsTheLastFourSecondsUntilTheRecognizerIsReady() throws {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
    func second(_ value: Float) -> AVAudioPCMBuffer {
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        b.frameLength = 16_000
        for i in 0..<16_000 { b.floatChannelData![0][i] = value }
        return b
    }
    let intake = AudioIntake(keep: 4)
    let flowed = Mutex(0)
    intake.onFirstAudio { flowed.withLock { $0 += 1 } }
    for i in 0..<6 { intake.take(second(Float(i))) }
    #expect(flowed.withLock { $0 } == 1, "told once, when audio first flows")
    #expect(intake.backlogSeconds == 4, "the last four seconds")
    let sink = Collect()
    intake.attach(sink)
    #expect(sink.frames.count == 4)
    intake.take(second(9))
    #expect(sink.frames.count == 5, "then straight through")
    intake.pause(true)
    intake.take(second(9))
    #expect(sink.frames.count == 5, "dropped while paused")
    intake.detach()
    intake.pause(false)
    intake.take(second(1))
    intake.discard(before: intake.now)
    #expect(intake.backlogSeconds == 0)
}

@Test func theIntakeCopiesBuffersItKeeps() throws {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
    let b = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
    b.frameLength = 160
    b.floatChannelData![0][5] = 0.5
    let c = try #require(AudioIntake.copy(b))
    b.floatChannelData![0][5] = 0
    #expect(c.floatChannelData![0][5] == 0.5 && c.frameLength == 160)
}

/// The whole pipeline without a microphone: Apple's voice says a sentence, and Apple's recognizer hears it.
@MainActor
@Test(.timeLimit(.minutes(1))) func speechRoundTripsOnTheDevice() async throws {
    let t0 = Date()
    let recognizer: Recognizer
    do {
        recognizer = try await Recognizer.start(locale: Locale(identifier: "en-US"), vocabulary: ["Duet", "qwen"])
    } catch {
        // No model for English on this machine and no way to download one: nothing to test here.
        print("on-device speech recognition unavailable: \(error)")
        return
    }
    let listening = Task {
        var heard = LiveTranscript()
        for await h in recognizer.heard {
            heard.apply(h)
        }
        heard.end()
        return heard
    }
    let sentence = "Please ask the small worker to rename the helper function."
    var buffers = 0
    // The synthesizer must outlive its speech: freed, it stops.
    let synthesizer = Synthesizer()
    for await pcm in synthesizer.speak(sentence, voice: Synthesizer.voice(id: nil, language: "en-US")) {
        recognizer.feed(pcm.buffer)
        buffers += 1
    }
    #expect(buffers > 0, "the voice produced audio")
    // Settling finalizes what's been heard without stopping.
    // A microphone keeps sending audio after you stop talking: quiet, while the recognizer settles.
    let quiet = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let room = Task { @MainActor in
        for _ in 0..<60 where !Task.isCancelled {
            let b = AVAudioPCMBuffer(pcmFormat: quiet, frameCapacity: 2_400)!
            b.frameLength = 2_400
            recognizer.feed(b)
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
    let settleStart = ContinuousClock.now
    let settled = await recognizer.settle(within: .seconds(2))
    room.cancel()
    print("  settled through \(settled.map { String(format: "%.2f s", $0) } ?? "nothing") in \(ContinuousClock.now - settleStart)")
    #expect(settled != nil, "with audio still coming, settling finishes")
    #expect(recognizer.heardThrough > 1, "about \(recognizer.heardThrough) s fed")
    await recognizer.finish()
    let heard = await listening.value
    print(String(format: "  heard in %.1f s (%@, %@): %@", Date().timeIntervalSince(t0), recognizer.model.rawValue, recognizer.locale.identifier, heard.text))
    #expect(heard.guess.isEmpty, "finishing settles every guess")
    for word in ["small", "worker", "rename", "function"] { #expect(heard.text.lowercased().contains(word), "heard: \(heard.text)") }
}
