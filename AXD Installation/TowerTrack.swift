import Foundation
import RealityKit

enum TowerSide {
    case left
    case right
}

struct TowerNode {
    let tower: ModelEntity
    let side: TowerSide
}

final class TowerTrack {
    private(set) var nodes: [TowerNode] = []
    private(set) var currentRowIndex: Int = -1
    private let layout: TowerLayoutConfig

    init(layout: TowerLayoutConfig) {
        self.layout = layout
    }

    func rebuild(in world: Entity, prototype: ModelEntity) {
        nodes.removeAll()
        currentRowIndex = -1

        for i in 0..<layout.rowCount {
            let z = -Float(i + 1) * layout.rowSpacing
            let side: TowerSide = (i % 2 == 0) ? .left : .right
            let x: Float = (side == .left) ? layout.leftX : layout.rightX

            let tower = prototype.clone(recursive: true)
            tower.position = [x, layout.towerHeight * 0.5, z]
            world.addChild(tower)

            nodes.append(TowerNode(tower: tower, side: side))
        }
    }

    func node(at index: Int) -> TowerNode? {
        guard index >= 0 && index < nodes.count else { return nil }
        return nodes[index]
    }

    func side(at index: Int) -> TowerSide? {
        node(at: index)?.side
    }

    func nextIndex(fromSwingRow swingRowIndex: Int?) -> Int {
        if let swingRowIndex { return swingRowIndex + 1 }
        return currentRowIndex + 1
    }

    func registerAttach(rowIndex: Int) {
        currentRowIndex = rowIndex
    }

    func resetProgress() {
        currentRowIndex = -1
    }
}
