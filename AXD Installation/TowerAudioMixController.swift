import Foundation
import simd

struct TowerAudioMixSettings {
    let activeTowerVolume: Float
    let backgroundVolumeNormal: Float
    let backgroundVolumeInFocus: Float
    let focusGuideCueVolume: Float
    let focusFadeInDuration: Float
    let focusFadeOutDuration: Float
    let leadSwitchTailLevel: Float
    let leadSwitchTailFadeDuration: Float

    static let `default` = TowerAudioMixSettings(
        activeTowerVolume: 4.0,
        backgroundVolumeNormal: 0.04,
        backgroundVolumeInFocus: 0.004,
        focusGuideCueVolume: 0.22,
        focusFadeInDuration: 0.12,
        focusFadeOutDuration: 0.22,
        leadSwitchTailLevel: 0.28,
        leadSwitchTailFadeDuration: 1.0
    )
}

final class TowerAudioMixController {
    private let audio: SpatialAudioRig
    private var towerAudioIDs: [UUID] = []
    private var towerFadeMultipliers: [Float] = []
    private var towerFadeOutSpeeds: [Float] = []
    private var guideSourceID: UUID? = nil
    private var focusTargetRowIndex: Int? = nil
    private var nearestAudibleRowIndex: Int? = nil
    private var guideBlendTarget: Float = 0.0
    private var guideBlendCurrent: Float = 0.0
    private var focusAmount: Float = 0.0
    private var lastLeadRowIndex: Int? = nil

    private let settings: TowerAudioMixSettings

    init(
        audio: SpatialAudioRig,
        settings: TowerAudioMixSettings = .default
    ) {
        self.audio = audio
        self.settings = settings
    }

    func registerTowerSource(_ id: UUID) {
        towerAudioIDs.append(id)
        towerFadeMultipliers.append(0.0)
        towerFadeOutSpeeds.append(0.0)
    }

    func registerGuideSource(_ id: UUID) {
        guideSourceID = id
        audio.setSourceVolume(sourceID: id, volume: 0.0)
    }

    func setFocusTargetRowIndex(_ rowIndex: Int?) {
        focusTargetRowIndex = rowIndex
    }

    func clearFocusTarget() {
        focusTargetRowIndex = nil
    }

    func setGuideBlend(_ blend: Float) {
        guideBlendTarget = max(0.0, min(blend, 1.0))
    }

    func setGuideSourcePosition(_ position: SIMD3<Float>) {
        guard let guideSourceID else { return }
        audio.setSourcePosition(sourceID: guideSourceID, position: position)
    }

    func setNearestAudibleRowIndex(_ rowIndex: Int?) {
        nearestAudibleRowIndex = rowIndex
    }

    func fadeOutTowerRow(_ rowIndex: Int, duration: Float) {
        guard rowIndex >= 0, rowIndex < towerFadeMultipliers.count else { return }
        let clampedDuration = max(duration, 0.001)
        if towerFadeMultipliers[rowIndex] < 1.0 {
            towerFadeMultipliers[rowIndex] = 1.0
        }
        let current = towerFadeMultipliers[rowIndex]
        towerFadeOutSpeeds[rowIndex] = current / clampedDuration
    }

    func resetToNormalMix() {
        focusAmount = 0.0
        guideBlendTarget = 0.0
        guideBlendCurrent = 0.0
        lastLeadRowIndex = nil
        audio.setBackgroundVolume(settings.backgroundVolumeNormal)
        for i in towerAudioIDs.indices {
            towerFadeMultipliers[i] = 0.0
            towerFadeOutSpeeds[i] = 0.0
            audio.setSourceVolume(sourceID: towerAudioIDs[i], volume: 0.0)
        }
        if let guideSourceID {
            audio.setSourceVolume(sourceID: guideSourceID, volume: 0.0)
        }
    }

    func sourceID(forRowIndex rowIndex: Int) -> UUID? {
        guard rowIndex >= 0, rowIndex < towerAudioIDs.count else { return nil }
        return towerAudioIDs[rowIndex]
    }

    func updateMix(isFocusActive: Bool, deltaTime: Float) {
        advanceTowerFades(deltaTime: deltaTime)

        let targetFocusAmount: Float = isFocusActive ? 1.0 : 0.0
        let transitionDuration = (targetFocusAmount > focusAmount) ? settings.focusFadeInDuration : settings.focusFadeOutDuration
        let blendStep = min(max(deltaTime / max(transitionDuration, 0.001), 0.0), 1.0)
        focusAmount += (targetFocusAmount - focusAmount) * blendStep
        guideBlendCurrent += (guideBlendTarget - guideBlendCurrent) * blendStep

        let backgroundVolume = settings.backgroundVolumeNormal
            + (settings.backgroundVolumeInFocus - settings.backgroundVolumeNormal) * focusAmount
        audio.setBackgroundVolume(backgroundVolume)

        let leadRowIndex = activeLeadRowIndex(isFocusActive: isFocusActive)
        handleLeadRowTransition(to: leadRowIndex)

        for (rowIndex, id) in towerAudioIDs.enumerated() {
            let isNearest = (rowIndex == leadRowIndex)
            let fadeMultiplier = towerFadeMultipliers[rowIndex]
            let volume: Float = isNearest
                ? settings.activeTowerVolume
                : (settings.activeTowerVolume * fadeMultiplier)
            audio.setSourceVolume(sourceID: id, volume: volume)
        }

        if let guideSourceID {
            let guideVolume = settings.focusGuideCueVolume * guideBlendCurrent * focusAmount
            audio.setSourceVolume(sourceID: guideSourceID, volume: guideVolume)
        }
    }

    private func activeLeadRowIndex(isFocusActive: Bool) -> Int? {
        if isFocusActive,
           let focusTargetRowIndex,
           focusTargetRowIndex >= 0,
           focusTargetRowIndex < towerAudioIDs.count {
            return focusTargetRowIndex
        }
        return nearestAudibleRowIndex
    }

    private func advanceTowerFades(deltaTime: Float) {
        guard deltaTime > 0 else { return }
        for i in towerFadeMultipliers.indices {
            let speed = towerFadeOutSpeeds[i]
            if speed <= 0 { continue }
            let next = max(0.0, towerFadeMultipliers[i] - speed * deltaTime)
            towerFadeMultipliers[i] = next
            if next <= 0.0 {
                towerFadeOutSpeeds[i] = 0.0
            }
        }
    }

    private func handleLeadRowTransition(to newLeadRowIndex: Int?) {
        guard newLeadRowIndex != lastLeadRowIndex else { return }
        defer { lastLeadRowIndex = newLeadRowIndex }

        guard let previousLead = lastLeadRowIndex,
              previousLead >= 0,
              previousLead < towerFadeMultipliers.count else {
            return
        }

        let targetMultiplier = max(towerFadeMultipliers[previousLead], settings.leadSwitchTailLevel)
        towerFadeMultipliers[previousLead] = targetMultiplier
        towerFadeOutSpeeds[previousLead] = targetMultiplier / max(settings.leadSwitchTailFadeDuration, 0.001)
    }
}
