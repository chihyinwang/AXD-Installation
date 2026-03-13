import Foundation

struct FocusTimingConfig {
    let duration: Float
    let timeScale: Float
    let delay: Float

    static let `default` = FocusTimingConfig(
        duration: 5.0,
        timeScale: 0.15,
        delay: 0.55
    )
}
