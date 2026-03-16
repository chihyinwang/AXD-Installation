import AppKit
import RealityKit
import simd

struct SceneGeometryHelper {
    static func startPlayerPosition(
        centerX: Float,
        groundY: Float,
        rooftopStartZ: Float,
        startTowerHeight: Float
    ) -> SIMD3<Float> {
        let towerTopY = groundY + startTowerHeight
        return SIMD3<Float>(centerX, towerTopY + 0.12, rooftopStartZ)
    }

    static func makeGroundEntity(
        towerLayoutConfig: TowerLayoutConfig,
        groundThickness: Float
    ) -> ModelEntity {
        let width: Float = max(10, abs(towerLayoutConfig.leftX) + abs(towerLayoutConfig.rightX) + 6)
        let farthestTowerDistance = towerLayoutConfig.firstRowDistance
            + Float(max(towerLayoutConfig.rowCount - 1, 0)) * towerLayoutConfig.rowSpacing
        let depth: Float = farthestTowerDistance + 20

        let mesh = MeshResource.generateBox(size: [width, groundThickness, depth])
        let material = SimpleMaterial(color: .darkGray, isMetallic: false)
        let ground = ModelEntity(mesh: mesh, materials: [material])
        ground.position = [0, -groundThickness * 0.5, -depth * 0.5]
        return ground
    }

    static func addStreetReferenceProps(
        to world: Entity,
        towerLayoutConfig: TowerLayoutConfig
    ) {
        let roadWidth: Float = max(10, abs(towerLayoutConfig.leftX) + abs(towerLayoutConfig.rightX) + 6)
        let farthestTowerDistance = towerLayoutConfig.firstRowDistance
            + Float(max(towerLayoutConfig.rowCount - 1, 0)) * towerLayoutConfig.rowSpacing
        let roadDepth: Float = farthestTowerDistance + 20
        let lineY: Float = 0.01

        let edgeLineMat = SimpleMaterial(color: .white, isMetallic: false)
        let centerLineMat = SimpleMaterial(color: .yellow, isMetallic: false)

        let edgeLineSize = SIMD3<Float>(0.10, 0.005, roadDepth)
        let leftEdgeLine = ModelEntity(mesh: .generateBox(size: edgeLineSize), materials: [edgeLineMat])
        leftEdgeLine.position = [-(roadWidth * 0.5) + 0.5, lineY, -roadDepth * 0.5]
        world.addChild(leftEdgeLine)

        let rightEdgeLine = ModelEntity(mesh: .generateBox(size: edgeLineSize), materials: [edgeLineMat])
        rightEdgeLine.position = [(roadWidth * 0.5) - 0.5, lineY, -roadDepth * 0.5]
        world.addChild(rightEdgeLine)

        let dashLength: Float = 2.0
        let gapLength: Float = 2.0
        let dashStride = dashLength + gapLength
        let dashCount = Int(roadDepth / dashStride)
        let centerDashSize = SIMD3<Float>(0.14, 0.005, dashLength)

        for i in 0..<dashCount {
            let z = -((Float(i) + 0.5) * dashStride)
            let dash = ModelEntity(mesh: .generateBox(size: centerDashSize), materials: [centerLineMat])
            dash.position = [0, lineY, z]
            world.addChild(dash)
        }

        let carBodyColors: [NSColor] = [.systemBlue, .systemRed, .systemGray, .systemGreen]
        let carBodySize = SIMD3<Float>(1.8, 1.0, 3.8)
        let carSideX = (roadWidth * 0.5) - 1.6

        for i in 0..<6 {
            let color = carBodyColors[i % carBodyColors.count]
            let carMaterial = SimpleMaterial(color: color, isMetallic: false)
            let z = -(18 + Float(i) * 24)

            let rightCar = ModelEntity(mesh: .generateBox(size: carBodySize), materials: [carMaterial])
            rightCar.position = [carSideX, 0.5, z]
            world.addChild(rightCar)

            if i % 2 == 0 {
                let leftCar = ModelEntity(mesh: .generateBox(size: carBodySize), materials: [carMaterial])
                leftCar.position = [-carSideX, 0.5, z - 10]
                world.addChild(leftCar)
            }
        }
    }
}
