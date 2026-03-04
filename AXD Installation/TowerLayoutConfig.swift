import Foundation

struct TowerLayoutConfig {
    let towerHeight: Float
    let rowCount: Int
    let rowSpacing: Float
    let leftX: Float
    let rightX: Float

    static let `default` = TowerLayoutConfig(
        towerHeight: 5.0,
        rowCount: 12,
        rowSpacing: 20,
        leftX: -5,
        rightX: 5
    )
}

