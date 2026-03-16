//
//  TowerToneGenerator.swift
//  AXD Installation
//
//  Created by Codex on 03/15/2026.
//

import Foundation
import AVFoundation

enum TowerToneGenerator {
    static func makeGeneratedTowerLoopBuffer(sampleRate: Double = 48_000, duration: Double = 2.28) -> AVAudioPCMBuffer {
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: sampleRate,
                                   channels: 1,
                                   interleaved: false)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channel = buffer.floatChannelData?[0] else {
            fatalError("[audio] failed to allocate generated tower buffer")
        }
        buffer.frameLength = frameCount

        let sr = Float(sampleRate)
        let twoPi = Float.pi * 2.0
        var maxAbs: Float = 0.0001

        for i in 0..<Int(frameCount) {
            let time = Float(i) / sr
            let sample = towerCoreSample(time: time, twoPi: twoPi)

            channel[i] = sample
            maxAbs = max(maxAbs, abs(sample))
        }

        applyEdgeFade(to: channel, frameCount: frameCount, sampleRate: sr)
        normalize(channel: channel, frameCount: frameCount, maxAbs: maxAbs)
        return buffer
    }

    static func makeGeneratedMuffledTowerLoopBuffer(sampleRate: Double = 48_000, duration: Double = 2.28) -> AVAudioPCMBuffer {
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: sampleRate,
                                   channels: 1,
                                   interleaved: false)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channel = buffer.floatChannelData?[0] else {
            fatalError("[audio] failed to allocate generated muffled tower buffer")
        }
        buffer.frameLength = frameCount

        let sr = Float(sampleRate)
        let twoPi = Float.pi * 2.0
        var lowPass: Float = 0
        var rustleLP: Float = 0
        var delayLine = [Float](repeating: 0, count: 97)
        var delayIndex = 0
        var maxAbs: Float = 0.0001

        for i in 0..<Int(frameCount) {
            let time = Float(i) / sr
            let core = towerCoreSample(time: time, twoPi: twoPi)
            let downshiftedCore = towerCoreSample(time: time, twoPi: twoPi, carrierScale: 0.74)
            let pulseEnv = towerPulseEnvelope(time: time)

            // Keep the same timbre fingerprint, then add "web interference".
            let flutter = 1.0
                + sin(twoPi * 5.2 * time) * 0.08
                + sin(twoPi * 8.7 * time + 0.4) * 0.03
            let roughnessAM = 1.0 + sin(twoPi * 41.0 * time + 0.1) * 0.022
            let cutoffWobble = 0.94 + sin(twoPi * 0.83 * time) * 0.08
            let lowPassAlpha = 0.035 * cutoffWobble
            let wrappedInput = downshiftedCore * 0.84 + core * 0.16
            lowPass += (wrappedInput - lowPass) * lowPassAlpha

            // Small internal reflections to create a cocoon-like "wrapped" cavity color.
            let delayed = delayLine[delayIndex]
            let cavity = lowPass * 0.84 + delayed * 0.16
            delayLine[delayIndex] = lowPass + delayed * 0.24
            delayIndex = (delayIndex + 1) % delayLine.count

            // Blend in a little dry signal so direction cues do not collapse.
            let wetDry = cavity * 0.90 + core * 0.10
            let driven = wetDry * 1.75
            let saturated = driven / (1.0 + abs(driven))
            let lowBody = sin(twoPi * 178.0 * time + 0.15) * 0.028 * (0.35 + pulseEnv * 0.65)

            let noiseSeed = sin(Float(i) * 12.9898 + 78.233) * 43_758.547
            let white = (noiseSeed - floor(noiseSeed)) * 2.0 - 1.0
            rustleLP += (white - rustleLP) * 0.075
            let rustle = rustleLP * (0.003 + 0.009 * pulseEnv)

            let buzz = sin(twoPi * 47.0 * time + 0.2) * 0.012
            let sample = (saturated + lowBody + buzz + rustle) * flutter * roughnessAM

            channel[i] = sample
            maxAbs = max(maxAbs, abs(sample))
        }

        applyEdgeFade(to: channel, frameCount: frameCount, sampleRate: sr)
        normalize(channel: channel, frameCount: frameCount, maxAbs: maxAbs, gain: 1.2)
        return buffer
    }

    private static func towerCoreSample(time: Float, twoPi: Float, carrierScale: Float = 1.0) -> Float {
        let carrierBaseA: Float = 730 * carrierScale
        let carrierBaseB: Float = 980 * carrierScale
        let subHumBase: Float = 94

        let pulseEnv = towerPulseEnvelope(time: time)

        let bodyA = sin(twoPi * carrierBaseA * time)
        let bodyB = sin(twoPi * carrierBaseB * time + 0.7) * 0.34
        let hum = sin(twoPi * subHumBase * time) * 0.03
        return (bodyA + bodyB) * pulseEnv * 0.62 + hum
    }

    private static func towerPulseEnvelope(time: Float) -> Float {
        let pulseCycle: Float = 0.38
        let pulseOn: Float = 0.27
        let pulsePos = time.truncatingRemainder(dividingBy: pulseCycle)
        if pulsePos < pulseOn {
            let phase = pulsePos / pulseOn
            return sin(phase * .pi)
        }
        return 0.0
    }

    private static func applyEdgeFade(to channel: UnsafeMutablePointer<Float>,
                                      frameCount: AVAudioFrameCount,
                                      sampleRate: Float) {
        let edgeSamples = min(Int(sampleRate * 0.006), Int(frameCount / 4))
        if edgeSamples > 1 {
            for i in 0..<edgeSamples {
                let t = Float(i) / Float(edgeSamples - 1)
                let fadeIn = t * t
                let fadeOut = (1.0 - t) * (1.0 - t)
                channel[i] *= fadeIn
                channel[Int(frameCount) - 1 - i] *= fadeOut
            }
        }
    }

    private static func normalize(channel: UnsafeMutablePointer<Float>,
                                  frameCount: AVAudioFrameCount,
                                  maxAbs: Float,
                                  gain: Float = 1.0) {
        let norm = min(0.85 / maxAbs, 1.0)
        for i in 0..<Int(frameCount) {
            channel[i] *= norm * gain
        }
    }
}
