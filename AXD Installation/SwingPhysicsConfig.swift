import Foundation

struct SwingPhysicsConfig {
    let detachAfterPassing: Float
    let initialSwingSpeed: Float
    let webAttachExtraHeight: Float
    let ropeScale: Float
    let ropeMinYZ: Float
    let ropeMaxHard: Float
    let minClearanceY: Float

    static let `default` = SwingPhysicsConfig(
        detachAfterPassing: 3.0,
        initialSwingSpeed: 7.0,
        webAttachExtraHeight: 1.8,
        ropeScale: 0.55,
        ropeMinYZ: 3.5,
        ropeMaxHard: 8.0,
        minClearanceY: 1.8
    )
}

