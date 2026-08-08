import Foundation
import AVFoundation
import Observation

/// Lightweight synthesized SFX / soft ambient pad for training feedback.
@MainActor
@Observable
final class AudioFeedback {
    enum Cue {
        case orbTouch
        case cubeGrab
        case clap
        case slice
        case celebrate
        case taskAdvance
    }

    private let engine = AVAudioEngine()
    private let sfxNode = AVAudioPlayerNode()
    private let ambientNode = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var isReady = false
    private var ambientOn = false

    var isEnabled = true

    func prepare() {
        guard !isReady else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            // Continue — engine may still play without session tweaks in some runtimes.
        }

        let sampleRate: Double = 44_100
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }
        self.format = format

        engine.attach(sfxNode)
        engine.attach(ambientNode)
        engine.connect(sfxNode, to: engine.mainMixerNode, format: format)
        engine.connect(ambientNode, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.85

        do {
            try engine.start()
            sfxNode.play()
            isReady = true
        } catch {
            isReady = false
        }
    }

    func play(_ cue: Cue) {
        guard isEnabled else { return }
        prepare()
        guard isReady, let format else { return }

        let buffer: AVAudioPCMBuffer?
        switch cue {
        case .orbTouch:
            buffer = makeTone(format: format, frequency: 880, duration: 0.12, volume: 0.28, decay: true)
        case .cubeGrab:
            buffer = makeTone(format: format, frequency: 520, duration: 0.08, volume: 0.22, decay: true)
        case .clap:
            buffer = makeNoiseBurst(format: format, duration: 0.09, volume: 0.35)
        case .slice:
            buffer = makeWhoosh(format: format, duration: 0.18, volume: 0.3)
        case .celebrate:
            buffer = makeArpeggio(format: format, frequencies: [523.25, 659.25, 783.99, 1046.5], noteDuration: 0.11, volume: 0.32)
        case .taskAdvance:
            buffer = makeTone(format: format, frequency: 660, duration: 0.1, volume: 0.2, decay: true)
        }

        guard let buffer else { return }
        sfxNode.scheduleBuffer(buffer, completionHandler: nil)
        if !sfxNode.isPlaying { sfxNode.play() }
    }

    func startAmbient() {
        guard isEnabled else { return }
        prepare()
        guard isReady, let format, !ambientOn else { return }
        guard let loop = makeAmbientPad(format: format) else { return }
        ambientOn = true
        ambientNode.volume = 0.12
        ambientNode.scheduleBuffer(loop, at: nil, options: [.loops], completionHandler: nil)
        if !ambientNode.isPlaying { ambientNode.play() }
    }

    func stopAmbient() {
        guard ambientOn else { return }
        ambientNode.stop()
        ambientOn = false
    }

    // MARK: - Synthesis

    private func makeTone(
        format: AVAudioFormat,
        frequency: Double,
        duration: Double,
        volume: Float,
        decay: Bool
    ) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount
        guard let data = buffer.floatChannelData?[0] else { return nil }

        let twoPi = 2.0 * Double.pi
        for i in 0..<Int(frameCount) {
            let t = Double(i) / sampleRate
            let envelope: Float = decay ? Float(max(0, 1 - t / duration)) : 1
            let sample = Float(sin(twoPi * frequency * t)) * volume * envelope * envelope
            data[i] = sample
        }
        return buffer
    }

    private func makeNoiseBurst(format: AVAudioFormat, duration: Double, volume: Float) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount
        guard let data = buffer.floatChannelData?[0] else { return nil }

        var previous: Float = 0
        for i in 0..<Int(frameCount) {
            let t = Double(i) / sampleRate
            let envelope = Float(max(0, 1 - t / duration))
            let white = Float.random(in: -1...1)
            // Simple low-pass for a softer clap/thud.
            let filtered = previous * 0.65 + white * 0.35
            previous = filtered
            data[i] = filtered * volume * envelope * envelope
        }
        return buffer
    }

    private func makeWhoosh(format: AVAudioFormat, duration: Double, volume: Float) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount
        guard let data = buffer.floatChannelData?[0] else { return nil }

        let twoPi = 2.0 * Double.pi
        for i in 0..<Int(frameCount) {
            let t = Double(i) / sampleRate
            let progress = t / duration
            let freq = 420.0 + 900.0 * progress
            let envelope = Float(sin(Double.pi * progress))
            let noise = Float.random(in: -0.35...0.35)
            let tone = Float(sin(twoPi * freq * t))
            data[i] = (tone * 0.65 + noise) * volume * envelope
        }
        return buffer
    }

    private func makeArpeggio(
        format: AVAudioFormat,
        frequencies: [Double],
        noteDuration: Double,
        volume: Float
    ) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        let totalDuration = noteDuration * Double(frequencies.count)
        let frameCount = AVAudioFrameCount(sampleRate * totalDuration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount
        guard let data = buffer.floatChannelData?[0] else { return nil }

        let twoPi = 2.0 * Double.pi
        let noteFrames = Int(sampleRate * noteDuration)
        for i in 0..<Int(frameCount) {
            let noteIndex = min(frequencies.count - 1, i / max(noteFrames, 1))
            let local = i % max(noteFrames, 1)
            let t = Double(local) / sampleRate
            let envelope = Float(max(0, 1 - t / noteDuration))
            let freq = frequencies[noteIndex]
            data[i] = Float(sin(twoPi * freq * t)) * volume * envelope * envelope
        }
        return buffer
    }

    private func makeAmbientPad(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        let duration = 4.0
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount
        guard let data = buffer.floatChannelData?[0] else { return nil }

        let twoPi = 2.0 * Double.pi
        let tones: [(Double, Float)] = [(174.61, 0.35), (220.0, 0.28), (261.63, 0.22)]
        for i in 0..<Int(frameCount) {
            let t = Double(i) / sampleRate
            var sample: Float = 0
            for (freq, weight) in tones {
                sample += Float(sin(twoPi * freq * t)) * weight
            }
            // Slow amplitude breathe so the loop feels less static.
            let breathe = 0.75 + 0.25 * Float(sin(twoPi * (t / duration)))
            data[i] = sample * 0.08 * breathe
        }
        return buffer
    }
}
