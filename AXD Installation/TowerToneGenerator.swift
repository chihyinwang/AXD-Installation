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
        let carrierBaseA: Float = 730
        let carrierBaseB: Float = 980
        let subHumBase: Float = 94
        let pulseCycle: Float = 0.38
        let pulseOn: Float = 0.27
        var maxAbs: Float = 0.0001

        for i in 0..<Int(frameCount) {
            let time = Float(i) / sr

            let pulsePos = time.truncatingRemainder(dividingBy: pulseCycle)
            let pulseEnv: Float
            if pulsePos < pulseOn {
                let phase = pulsePos / pulseOn
                pulseEnv = sin(phase * .pi)
            } else {
                pulseEnv = 0.0
            }

            let amplitude = pulseEnv
            let bodyA = sin(twoPi * carrierBaseA * time)
            let bodyB = sin(twoPi * carrierBaseB * time + 0.7) * 0.34
            let hum = sin(twoPi * subHumBase * time) * 0.03
            let sample = (bodyA + bodyB) * amplitude * 0.62 + hum

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
        let carrierBaseA: Float = 390
        let carrierBaseB: Float = 520
        let subHumBase: Float = 82
        let pulseCycle: Float = 0.44
        let pulseOn: Float = 0.30
        var lowPass: Float = 0
        var maxAbs: Float = 0.0001

        for i in 0..<Int(frameCount) {
            let time = Float(i) / sr
            let pulsePos = time.truncatingRemainder(dividingBy: pulseCycle)
            let pulseEnv: Float
            if pulsePos < pulseOn {
                let phase = pulsePos / pulseOn
                pulseEnv = sin(phase * .pi)
            } else {
                pulseEnv = 0.0
            }

            let bodyA = sin(twoPi * carrierBaseA * time)
            let bodyB = sin(twoPi * carrierBaseB * time + 0.45) * 0.28
            let hum = sin(twoPi * subHumBase * time) * 0.06
            let raw = (bodyA + bodyB) * pulseEnv * 0.58 + hum
            lowPass += (raw - lowPass) * 0.06
            let sample = lowPass

            channel[i] = sample
            maxAbs = max(maxAbs, abs(sample))
        }

        applyEdgeFade(to: channel, frameCount: frameCount, sampleRate: sr)
        normalize(channel: channel, frameCount: frameCount, maxAbs: maxAbs, gain: 0.75)
        return buffer
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
