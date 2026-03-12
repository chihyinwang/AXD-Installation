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

    private var loopBuffer: AVAudioPCMBuffer?
    private var sources: [UUID: AVAudioPlayerNode] = [:]
    private var started = false
    private var defaultSourceVolume: Float = 0.25

    private struct AttenuationProfile {
        let referenceDistance: Float
        let maximumDistance: Float
        let rolloffFactor: Float
    }

    private let normalAttenuation = AttenuationProfile(
        referenceDistance: 0.5,
        maximumDistance: 30,
        rolloffFactor: 3.0
    )
    private let focusAttenuation = AttenuationProfile(
        referenceDistance: 2.5,
        maximumDistance: 80,
        rolloffFactor: 0.8
    )

    // 1) Build the audio graph first: environment -> mainMixer.
    func configure(loopFileName: String = "tower_loop_mono1", fileExt: String = "wav") {
        guard !started else { return }

        engine.attach(environment)
        engine.connect(environment, to: engine.mainMixerNode, format: nil)

        let monoBuffer = loadLoopBufferNamed(loopFileName, ext: fileExt)
        self.loopBuffer = monoBuffer

        // Environment settings: HRTF and distance attenuation.
        environment.renderingAlgorithm = .HRTF
        environment.distanceAttenuationParameters.distanceAttenuationModel = .inverse
        applyAttenuation(normalAttenuation)
        // Distance attenuation parameters are configured on the environment node.
        // :contentReference[oaicite:0]{index=0}

        print("[audio] configured. sr=\(monoBuffer.format.sampleRate) ch=\(monoBuffer.format.channelCount)")
    }

    // 2) Add one looping 3D source for each tower.
    @discardableResult
    func addLoopingSource(at position: SIMD3<Float>, volume: Float = 0.25) -> UUID {
        guard let buf = loopBuffer else {
            fatalError("Call configure(...) before addLoopingSource(...)")
        }

        let id = UUID()
        let node = AVAudioPlayerNode()

        engine.attach(node)
        engine.connect(node, to: environment, format: buf.format)

        // Important: AVAudioEnvironmentNode spatializes mono input, so force a mono buffer.
        // :contentReference[oaicite:1]{index=1}
        node.renderingAlgorithm = .HRTF
        node.sourceMode = .spatializeIfMono
        node.reverbBlend = 0.0
        node.volume = volume
        defaultSourceVolume = volume

        node.position = AVAudio3DPoint(x: position.x, y: position.y, z: position.z)

        // loop
        node.scheduleBuffer(buf, at: nil, options: [.loops], completionHandler: nil)

        sources[id] = node
        return id
    }

    // 3) Start the engine and begin playback for all sources.
    func start() {
        guard !started else { return }
        started = true

        do {
            try engine.start()
        } catch {
            fatalError("Audio engine start failed: \(error)")
        }

        for (_, node) in sources {
            node.play()
        }
        print("[audio] started. sourceCount=\(sources.count)")
    }

    func stop() {
        for (_, node) in sources { node.stop() }
        engine.stop()
        started = false
    }

    // Update listener position every frame.
    func setListenerPosition(_ p: SIMD3<Float>) {
        environment.listenerPosition = AVAudio3DPoint(x: p.x, y: p.y, z: p.z)
    }

    func setNormalMix(defaultVolume: Float? = nil) {
        if let defaultVolume {
            self.defaultSourceVolume = defaultVolume
        }

        for (_, node) in sources {
            node.volume = self.defaultSourceVolume
        }
        applyAttenuation(normalAttenuation)
    }

    func setFocusMix(focusSourceID: UUID, focusSourceVolume: Float = 0.5, otherSourcesVolume: Float = 0.0) {
        for (id, node) in sources {
            node.volume = (id == focusSourceID) ? focusSourceVolume : otherSourcesVolume
        }
        applyAttenuation(focusAttenuation)
    }

    func restartAllLoopsFromBeginning() {
        guard let buf = loopBuffer else { return }

        for (_, node) in sources {
            node.stop()
            node.scheduleBuffer(buf, at: nil, options: [.loops], completionHandler: nil)
            if started {
                node.play()
            }
        }
    }

    // MARK: - Loading & Downmix (avoid channel mismatch)
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

            if inFormat.channelCount == 1 { return inBuffer }

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

    private func applyAttenuation(_ profile: AttenuationProfile) {
        environment.distanceAttenuationParameters.referenceDistance = profile.referenceDistance
        environment.distanceAttenuationParameters.maximumDistance = profile.maximumDistance
        environment.distanceAttenuationParameters.rolloffFactor = profile.rolloffFactor
    }
}
