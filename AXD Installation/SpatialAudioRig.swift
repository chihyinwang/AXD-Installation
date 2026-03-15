//
//  SpatialAudioRig.swift
//  AXD Installation
//
//  Created by chihyin wang on 02/03/2026.
//

import Foundation
import AVFoundation
import simd

enum TowerToneVariant {
    case normal
    case muffled
}

final class SpatialAudioRig {
    private let engine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()

    private var normalLoopBuffer: AVAudioPCMBuffer?
    private var muffledLoopBuffer: AVAudioPCMBuffer?
    private var sources: [UUID: AVAudioPlayerNode] = [:]
    private var sourceToneVariants: [UUID: TowerToneVariant] = [:]
    private var backgroundBuffer: AVAudioPCMBuffer?
    private var backgroundNode: AVAudioPlayerNode?
    private var started = false

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

    // Build a procedural "tower beacon" loop in code (no source file needed).
    func configureGeneratedTowerBaseLoop() {
        guard !started else { return }

        engine.attach(environment)
        engine.connect(environment, to: engine.mainMixerNode, format: nil)

        normalLoopBuffer = TowerToneGenerator.makeGeneratedTowerLoopBuffer()
        muffledLoopBuffer = TowerToneGenerator.makeGeneratedMuffledTowerLoopBuffer()

        environment.renderingAlgorithm = .HRTF
        environment.distanceAttenuationParameters.distanceAttenuationModel = .inverse
        applyAttenuation(normalAttenuation)
        print("[audio] configured generated tower loop. sr=\(normalLoopBuffer?.format.sampleRate ?? 0)")
    }

    // 2) Add one looping 3D source for each tower.
    @discardableResult
    func addLoopingSource(at position: SIMD3<Float>, volume: Float = 0.25, toneVariant: TowerToneVariant = .normal) -> UUID {
        guard let buf = loopBuffer(for: toneVariant) else {
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

        node.position = AVAudio3DPoint(x: position.x, y: position.y, z: position.z)

        // loop
        node.scheduleBuffer(buf, at: nil, options: [.loops], completionHandler: nil)

        sources[id] = node
        sourceToneVariants[id] = toneVariant
        return id
    }

    func setSourceToneVariant(sourceID: UUID, variant: TowerToneVariant) {
        guard let node = sources[sourceID] else { return }
        guard sourceToneVariants[sourceID] != variant else { return }
        guard let buffer = loopBuffer(for: variant) else { return }

        sourceToneVariants[sourceID] = variant
        node.stop()
        node.scheduleBuffer(buffer, at: nil, options: [.loops], completionHandler: nil)
        if started {
            node.play()
        }
    }

    @discardableResult
    func configureBackgroundLoop(fileName: String, fileExt: String) -> Bool {
        guard backgroundNode == nil else { return true }

        guard let url = Bundle.main.url(forResource: fileName, withExtension: fileExt) else {
            print("[audio] background file not found: \(fileName).\(fileExt)")
            return false
        }

        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            let frameCount = AVAudioFrameCount(file.length)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                print("[audio] background buffer allocation failed")
                return false
            }
            try file.read(into: buffer)
            buffer.frameLength = frameCount

            let node = AVAudioPlayerNode()
            node.volume = 0.0
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            node.scheduleBuffer(buffer, at: nil, options: [.loops], completionHandler: nil)

            backgroundBuffer = buffer
            backgroundNode = node
            return true
        } catch {
            print("[audio] background loading failed: \(error)")
            return false
        }
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
        backgroundNode?.play()
        print("[audio] started. sourceCount=\(sources.count)")
    }

    func stop() {
        for (_, node) in sources { node.stop() }
        backgroundNode?.stop()
        engine.stop()
        started = false
    }

    // Update listener position every frame.
    func setListenerPosition(_ p: SIMD3<Float>) {
        environment.listenerPosition = AVAudio3DPoint(x: p.x, y: p.y, z: p.z)
    }

    func setSourcePosition(sourceID: UUID, position: SIMD3<Float>) {
        guard let node = sources[sourceID] else { return }
        node.position = AVAudio3DPoint(x: position.x, y: position.y, z: position.z)
    }

    func setSourceVolume(sourceID: UUID, volume: Float) {
        guard let node = sources[sourceID] else { return }
        node.volume = max(0.0, volume)
    }

    func setBackgroundVolume(_ volume: Float) {
        backgroundNode?.volume = max(0.0, volume)
    }

    func restartAllLoopsFromBeginning() {
        guard let normalBuffer = normalLoopBuffer else { return }

        for (id, node) in sources {
            sourceToneVariants[id] = .normal
            node.stop()
            node.scheduleBuffer(normalBuffer, at: nil, options: [.loops], completionHandler: nil)
            if started {
                node.play()
            }
        }

        if let backgroundNode, let backgroundBuffer {
            backgroundNode.stop()
            backgroundNode.scheduleBuffer(backgroundBuffer, at: nil, options: [.loops], completionHandler: nil)
            if started {
                backgroundNode.play()
            }
        }
    }

    private func applyAttenuation(_ profile: AttenuationProfile) {
        environment.distanceAttenuationParameters.referenceDistance = profile.referenceDistance
        environment.distanceAttenuationParameters.maximumDistance = profile.maximumDistance
        environment.distanceAttenuationParameters.rolloffFactor = profile.rolloffFactor
    }

    private func loopBuffer(for variant: TowerToneVariant) -> AVAudioPCMBuffer? {
        switch variant {
        case .normal:
            return normalLoopBuffer
        case .muffled:
            return muffledLoopBuffer ?? normalLoopBuffer
        }
    }

}
