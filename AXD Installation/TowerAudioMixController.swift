import Foundation

final class TowerAudioMixController {
    private let audio: SpatialAudioRig
    private var towerAudioIDs: [UUID] = []
    private var focusTargetRowIndex: Int? = nil
    private var isFocusMixApplied = false

    private let normalVolume: Float
    private let focusVolume: Float
    private let otherVolumeInFocus: Float

    init(
        audio: SpatialAudioRig,
        normalVolume: Float = 0.25,
        focusVolume: Float = 1.0,
        otherVolumeInFocus: Float = 0.0
    ) {
        self.audio = audio
        self.normalVolume = normalVolume
        self.focusVolume = focusVolume
        self.otherVolumeInFocus = otherVolumeInFocus
    }

    func registerTowerSource(_ id: UUID) {
        towerAudioIDs.append(id)
    }

    func setFocusTargetRowIndex(_ rowIndex: Int?) {
        focusTargetRowIndex = rowIndex
    }

    func clearFocusTarget() {
        focusTargetRowIndex = nil
    }

    func resetToNormalMix() {
        audio.setNormalMix(defaultVolume: normalVolume)
        isFocusMixApplied = false
    }

    func updateMix(isFocusActive: Bool) {
        if isFocusActive,
           let targetRow = focusTargetRowIndex,
           targetRow >= 0,
           targetRow < towerAudioIDs.count {
            if !isFocusMixApplied {
                print("[audio] focus mix on row \(targetRow)")
            }
            isFocusMixApplied = true
            audio.setFocusMix(
                focusSourceID: towerAudioIDs[targetRow],
                focusSourceVolume: focusVolume,
                otherSourcesVolume: otherVolumeInFocus
            )
            return
        }

        if isFocusMixApplied {
            print("[audio] return to normal mix")
            resetToNormalMix()
        }
    }
}

