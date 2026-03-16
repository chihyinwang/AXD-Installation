import Foundation
import simd

extension GameARView {
    enum InputControlMode {
        case manualRelease
        case focusShootAutoRelease
    }

    struct InputControlConfig {
        let mode: InputControlMode

        static let `default` = InputControlConfig(
            mode: .focusShootAutoRelease
        )
    }

    enum ShootInputGateMode {
        case keyboardOnly
        case singlePhoneEitherArmMode
        case dualPhoneMappedArmModes
    }

    struct ShootInputGateConfig {
        let mode: ShootInputGateMode
        let requiredArmPoseStateCode: Int

        static let `default` = ShootInputGateConfig(
            mode: .keyboardOnly,
            requiredArmPoseStateCode: 2
        )
    }

    struct WorldPhysicsConfig {
        let centerX: Float
        let groundY: Float
        let rooftopY: Float
        let rooftopStartZ: Float
        let gravity: Float

        static let `default` = WorldPhysicsConfig(
            centerX: 0,
            groundY: 0.12,
            rooftopY: 7.0,
            rooftopStartZ: -14.0,
            gravity: 9.8
        )
    }

    struct ReleaseConfig {
        let upwardVelocityCap: Float
        let swingGroundSafetyMargin: Float
        let windowDepth: Float
        let cueHeight: Float

        static let `default` = ReleaseConfig(
            upwardVelocityCap: 5.0,
            swingGroundSafetyMargin: 0.35,
            windowDepth: 6.0,
            cueHeight: 1.1
        )
    }

    struct ReleaseCueAudioConfig {
        let fadeOutLeadTimeBeforeGreenSeconds: Float
        let fadeOutDurationSeconds: Float
        let fadeOutInitialLevel: Float
        let towerFadeInDelayAfterGreenSeconds: Float

        static let `default` = ReleaseCueAudioConfig(
            fadeOutLeadTimeBeforeGreenSeconds: 0.2,
            fadeOutDurationSeconds: 0.3,
            fadeOutInitialLevel: 0.16,
            towerFadeInDelayAfterGreenSeconds: 0.1
        )
    }

    struct CameraFollowConfig {
        let baseHeight: Float
        let baseBackDistance: Float
        let highAltitudeThreshold: Float
        let highAltitudeCap: Float
        let extraBackPerHighMeter: Float
        let extraHeightPerHighMeter: Float
        let lookDownBiasPerHighMeter: Float
        let visibilityMinDistance: Float
        let visibilityExtraDistance: Float

        static let `default` = CameraFollowConfig(
            baseHeight: 1.6,
            baseBackDistance: 3.2,
            highAltitudeThreshold: 3.5,
            highAltitudeCap: 3.2,
            extraBackPerHighMeter: 0.6,
            extraHeightPerHighMeter: 0.25,
            lookDownBiasPerHighMeter: 0.3,
            visibilityMinDistance: 4.0,
            visibilityExtraDistance: 8.0
        )
    }

    struct LaunchSequenceConfig {
        let startTowerHeight: Float
        let pegForwardOffset: Float
        let pegLateralOffset: Float
        let pegHeightOffset: Float
        let chargeMinDuration: Float
        let releaseChordWindow: Float
        let chargeCameraBackOffset: Float
        let chargePlayerBackOffset: Float
        let launchSpeed: Float
        let launchAngleDegrees: Float
        let focusTriggerHeight: Float

        static let `default` = LaunchSequenceConfig(
            startTowerHeight: 6.2,
            pegForwardOffset: 2.9,
            pegLateralOffset: 1.35,
            pegHeightOffset: 0.18,
            chargeMinDuration: 0.55,
            releaseChordWindow: 0.09,
            chargeCameraBackOffset: 0.7,
            chargePlayerBackOffset: 0.25,
            launchSpeed: 16.0,
            launchAngleDegrees: 15.0,
            focusTriggerHeight: 6.0
        )
    }

    struct SwingState {
        let anchor: SIMD3<Float>
        var ropeLengthYZ: Float
        var ropeTargetYZ: Float
        let towerZ: Float
        let rowIndex: Int
        let side: TowerSide
    }

    struct AudioGuidance {
        let targetRowIndex: Int
        let blend: Float
    }

    struct AudioGuidanceConfig {
        let isGuidePositionOffsetEnabled: Bool
        let isGuideDistanceLowPassEnabled: Bool
        let maxDistanceMeters: Float
        let minDistanceMeters: Float
        let xScaleAtMaxDistance: Float
        let zScaleAtMaxDistance: Float
        let lowPassNearDistanceMeters: Float
        let lowPassFarDistanceMeters: Float
        let lowPassNearCutoffHz: Float
        let lowPassFarCutoffHz: Float

        static let `default` = AudioGuidanceConfig(
            isGuidePositionOffsetEnabled: true,
            isGuideDistanceLowPassEnabled: true,
            maxDistanceMeters: 16.5,
            minDistanceMeters: 11.5,
            xScaleAtMaxDistance: 3.0,
            zScaleAtMaxDistance: 0.8,
            lowPassNearDistanceMeters: 11.0,
            lowPassFarDistanceMeters: 18.0,
            lowPassNearCutoffHz: 2200,
            lowPassFarCutoffHz: 280
        )
    }

    struct DebugConfig {
        let showGuideDebugSpheres: Bool

        static let `default` = DebugConfig(
            showGuideDebugSpheres: false
        )
    }
}
