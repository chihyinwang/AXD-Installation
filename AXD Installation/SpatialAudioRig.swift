//
//  SpatialAudioRig.swift
//  AXD Installation
//
//  Created by chihyin wang on 02/03/2026.
//

import Foundation
import AVFoundation
import simd

final class SpatialAudioRig {
    private let engine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()
    private let playerNode = AVAudioPlayerNode()

    private var loopBuffer: AVAudioPCMBuffer?

    func start(loopFileName: String = "tower_loop_mono", fileExt: String = "wav") {
        // 1) attach nodes
        engine.attach(environment)
        engine.attach(playerNode)

        // 2) load buffer (auto downmix to mono to avoid channel mismatch)
        let monoBuffer = loadLoopBufferNamed(loopFileName, ext: fileExt)
        loopBuffer = monoBuffer

        // 3) connect: player -> environment -> mainMixer
        engine.connect(playerNode, to: environment, format: monoBuffer.format)
        engine.connect(environment, to: engine.mainMixerNode, format: nil)

        // 4) spatial settings (make it OBVIOUS)
        environment.renderingAlgorithm = .HRTF   
        environment.distanceAttenuationParameters.distanceAttenuationModel = .inverse
        environment.distanceAttenuationParameters.referenceDistance = 0.5
        environment.distanceAttenuationParameters.maximumDistance = 30
        environment.distanceAttenuationParameters.rolloffFactor = 2.0
        

        // 5) source settings (playerNode conforms to AVAudio3DMixing)
        playerNode.renderingAlgorithm = .HRTF
        playerNode.sourceMode = .spatializeIfMono
        playerNode.reverbBlend = 0.0

        do {
            try engine.start()
        } catch {
            fatalError("Audio engine start failed: \(error)")
        }

        // 6) loop play
        playerNode.scheduleBuffer(monoBuffer, at: nil, options: [.loops], completionHandler: nil)
        playerNode.play()

        print("[audio] started. sr=\(monoBuffer.format.sampleRate) ch=\(monoBuffer.format.channelCount)")
    }

    func stop() {
        playerNode.stop()
        engine.stop()
    }

    // MARK: - Update positions (world meters)
    func setSourcePosition(_ p: SIMD3<Float>) {
        playerNode.position = AVAudio3DPoint(x: p.x, y: p.y, z: p.z)
    }

    func setListenerPosition(_ p: SIMD3<Float>) {
        environment.listenerPosition = AVAudio3DPoint(x: p.x, y: p.y, z: p.z)
    }

    // Optional (Phase 3 / head tracking later)
    func setListenerYawRadians(_ yaw: Float) {
        environment.listenerAngularOrientation = AVAudio3DAngularOrientation(yaw: yaw, pitch: 0, roll: 0)
    }

    // MARK: - Loading & downmix
    private func loadLoopBufferNamed(_ name: String, ext: String) -> AVAudioPCMBuffer {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else {
            fatalError("Missing audio file in bundle: \(name).\(ext)")
        }

        do {
            let file = try AVAudioFile(forReading: url)
            let inFormat = file.processingFormat
            let frameCount = AVAudioFrameCount(file.length)

            guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frameCount) else {
                fatalError("Failed to create input buffer")
            }
            try file.read(into: inBuffer)

            // Already mono
            if inFormat.channelCount == 1 {
                return inBuffer
            }

            // Downmix to mono float32
            let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                           sampleRate: inFormat.sampleRate,
                                           channels: 1,
                                           interleaved: false)!
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: inBuffer.frameCapacity) else {
                fatalError("Failed to create mono buffer")
            }
            outBuffer.frameLength = inBuffer.frameLength

            guard let converter = AVAudioConverter(from: inFormat, to: monoFormat) else {
                fatalError("Failed to create converter")
            }

            var didProvide = false
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                if didProvide {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                didProvide = true
                outStatus.pointee = .haveData
                return inBuffer
            }

            var err: NSError?
            converter.convert(to: outBuffer, error: &err, withInputFrom: inputBlock)
            if let err { fatalError("Downmix failed: \(err)") }

            print("[audio] downmixed to mono")
            return outBuffer
        } catch {
            fatalError("Failed reading audio: \(error)")
        }
    }
}
