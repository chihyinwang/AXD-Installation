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
    let leadSwitchSilenceDuration: Float
    let towerVolumeAttackDuration: Float
    let towerVolumeReleaseDuration: Float

    static let `default` = TowerAudioMixSettings(
        activeTowerVolume: 4.0,
        backgroundVolumeNormal: 0.04,
        backgroundVolumeInFocus: 0.004,
        focusGuideCueVolume: 0.22,
        focusFadeInDuration: 0.12,
        focusFadeOutDuration: 0.22,
        leadSwitchTailLevel: 0.28,
        leadSwitchTailFadeDuration: 1.0,
        leadSwitchSilenceDuration: 0.36,
        towerVolumeAttackDuration: 0.24,
        towerVolumeReleaseDuration: 0.32
    )
}

final class TowerAudioMixController {
    private let audio: SpatialAudioRig
    private var towerAudioIDs: [UUID] = []
    private var towerFadeMultipliers: [Float] = []
    private var towerFadeOutSpeeds: [Float] = []
    private var towerCurrentVolumes: [Float] = []
    private var guideSourceID: UUID? = nil
    private var focusTargetRowIndex: Int? = nil
    private var nearestAudibleRowIndex: Int? = nil
    private var guideBlendTarget: Float = 0.0
    private var guideBlendCurrent: Float = 0.0
    private var focusAmount: Float = 0.0
    private var lastLeadRowIndex: Int? = nil
    private var pendingLeadActivationRowIndex: Int? = nil
    private var pendingLeadActivationRemaining: Float = 0.0

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
        towerCurrentVolumes.append(0.0)
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

    func fadeOutTowerRow(_ rowIndex: Int, duration: Float, startLevel: Float = 1.0) {
        guard rowIndex >= 0, rowIndex < towerFadeMultipliers.count else { return }
        let clampedDuration = max(duration, 0.001)
        let clampedStartLevel = max(0.0, min(startLevel, 1.0))
        towerFadeMultipliers[rowIndex] = max(towerFadeMultipliers[rowIndex], clampedStartLevel)
        let current = towerFadeMultipliers[rowIndex]
        towerFadeOutSpeeds[rowIndex] = current / clampedDuration
    }

    func resetToNormalMix() {
        focusAmount = 0.0
        guideBlendTarget = 0.0
        guideBlendCurrent = 0.0
        lastLeadRowIndex = nil
        pendingLeadActivationRowIndex = nil
        pendingLeadActivationRemaining = 0.0
        audio.setBackgroundVolume(settings.backgroundVolumeNormal)
        for i in towerAudioIDs.indices {
            towerFadeMultipliers[i] = 0.0
            towerFadeOutSpeeds[i] = 0.0
            towerCurrentVolumes[i] = 0.0
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
        advancePendingLeadActivation(deltaTime: deltaTime)

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
        let activeLeadRowIndex = resolvedLeadRowIndex(from: leadRowIndex)

        for (rowIndex, id) in towerAudioIDs.enumerated() {
            let isNearest = (rowIndex == activeLeadRowIndex)
            let fadeMultiplier = towerFadeMultipliers[rowIndex]
            let targetVolume: Float = isNearest
                ? settings.activeTowerVolume
                : (settings.activeTowerVolume * fadeMultiplier)
            let currentVolume = towerCurrentVolumes[rowIndex]
            let transitionDuration = (targetVolume > currentVolume)
                ? settings.towerVolumeAttackDuration
                : settings.towerVolumeReleaseDuration
            let step = min(max(deltaTime / max(transitionDuration, 0.001), 0.0), 1.0)
            let smoothedVolume = currentVolume + (targetVolume - currentVolume) * step
            towerCurrentVolumes[rowIndex] = smoothedVolume
            audio.setSourceVolume(sourceID: id, volume: smoothedVolume)
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

    private func advancePendingLeadActivation(deltaTime: Float) {
        guard pendingLeadActivationRemaining > 0 else { return }
        pendingLeadActivationRemaining = max(0.0, pendingLeadActivationRemaining - deltaTime)
        if pendingLeadActivationRemaining <= 0.0 {
            pendingLeadActivationRowIndex = nil
        }
    }

    private func resolvedLeadRowIndex(from leadRowIndex: Int?) -> Int? {
        guard let leadRowIndex else { return nil }
        guard pendingLeadActivationRemaining > 0 else { return leadRowIndex }
        if pendingLeadActivationRowIndex == leadRowIndex {
            return nil
        }
        return leadRowIndex
    }

    private func handleLeadRowTransition(to newLeadRowIndex: Int?) {
        guard newLeadRowIndex != lastLeadRowIndex else { return }
        defer { lastLeadRowIndex = newLeadRowIndex }

        if let previousLead = lastLeadRowIndex,
           let newLeadRowIndex,
           previousLead != newLeadRowIndex {
            pendingLeadActivationRowIndex = newLeadRowIndex
            pendingLeadActivationRemaining = settings.leadSwitchSilenceDuration
        } else {
            pendingLeadActivationRowIndex = nil
            pendingLeadActivationRemaining = 0.0
        }

        guard let previousLead = lastLeadRowIndex,
              previousLead >= 0,
              previousLead < towerFadeMultipliers.count else {
            return
        }

        let currentMultiplier = towerFadeMultipliers[previousLead]
        let targetMultiplier: Float
        if currentMultiplier > 0.0 {
            targetMultiplier = currentMultiplier
        } else {
            targetMultiplier = settings.leadSwitchTailLevel
        }
        towerFadeMultipliers[previousLead] = targetMultiplier
        towerFadeOutSpeeds[previousLead] = targetMultiplier / max(settings.leadSwitchTailFadeDuration, 0.001)
    }
}
