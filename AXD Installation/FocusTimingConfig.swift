import Foundation

struct FocusTimingConfig {
    let duration: Float
    let timeScale: Float
    let delay: Float

    static let `default` = FocusTimingConfig(
        duration: 1.8,
        timeScale: 0.25,
        delay: 0.55
    )
}

