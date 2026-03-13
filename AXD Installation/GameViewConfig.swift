import Foundation
import simd

extension GameARView {
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

    struct AudioGuidanceConfig {
        let rearTowerAudibleDistance: Float
        let horizontalExaggeration: Float
        let assistTriggerDistance: Float
        let assistFullBlendDistance: Float
        let assistLateralOffset: Float
        let assistForwardOffset: Float
        let focusLateralOffset: Float
        let focusHeightOffset: Float

        static let `default` = AudioGuidanceConfig(
            rearTowerAudibleDistance: 6.0,
            horizontalExaggeration: 2.0,
            assistTriggerDistance: 16.0,
            assistFullBlendDistance: 7.0,
            assistLateralOffset: 3.2,
            assistForwardOffset: 1.4,
            focusLateralOffset: 7.4,
            focusHeightOffset: 0.2
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
}
