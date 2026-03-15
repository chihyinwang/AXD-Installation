import AppKit
import RealityKit

struct GameSceneEntities {
    let world: AnchorEntity
    let player: ModelEntity
    let camera: PerspectiveCamera
    let cameraAnchor: AnchorEntity
    let visibilityMaskSphere: ModelEntity
    let releaseCueIndicator: ModelEntity
    let guideDebugSphere: ModelEntity
    let guideTowerDebugSphere: ModelEntity
    let startTowerEntity: ModelEntity
    let leftLaunchPegEntity: ModelEntity
    let rightLaunchPegEntity: ModelEntity
    let leftLaunchPegSupport: ModelEntity
    let rightLaunchPegSupport: ModelEntity
    let leftLaunchPegBase: ModelEntity
    let rightLaunchPegBase: ModelEntity

    init() {
        world = AnchorEntity(world: .zero)

        player = ModelEntity(
            mesh: .generateSphere(radius: 0.12),
            materials: [SimpleMaterial(color: .red, isMetallic: false)]
        )

        camera = PerspectiveCamera()
        cameraAnchor = AnchorEntity(world: .zero)

        visibilityMaskSphere = {
            let mesh = MeshResource.generateSphere(radius: 1.0)
            let material = UnlitMaterial(color: .black)
            return ModelEntity(mesh: mesh, materials: [material])
        }()

        releaseCueIndicator = {
            let mesh = MeshResource.generateSphere(radius: 0.12)
            let material = UnlitMaterial(color: .yellow)
            let indicator = ModelEntity(mesh: mesh, materials: [material])
            indicator.scale = .zero
            return indicator
        }()

        guideDebugSphere = {
            let mesh = MeshResource.generateSphere(radius: 0.28)
            let material = UnlitMaterial(color: .red)
            let sphere = ModelEntity(mesh: mesh, materials: [material])
            sphere.scale = .zero
            return sphere
        }()

        guideTowerDebugSphere = {
            let mesh = MeshResource.generateSphere(radius: 0.22)
            let material = UnlitMaterial(color: .systemBlue)
            let sphere = ModelEntity(mesh: mesh, materials: [material])
            sphere.scale = .zero
            return sphere
        }()

        startTowerEntity = {
            let mesh = MeshResource.generateBox(size: [0.55, 4.0, 0.55])
            let material = SimpleMaterial(color: .systemGray, isMetallic: false)
            return ModelEntity(mesh: mesh, materials: [material])
        }()

        leftLaunchPegEntity = {
            let mesh = MeshResource.generateCylinder(height: 1.0, radius: 0.08)
            let material = SimpleMaterial(color: .lightGray, isMetallic: false)
            return ModelEntity(mesh: mesh, materials: [material])
        }()

        rightLaunchPegEntity = {
            let mesh = MeshResource.generateCylinder(height: 1.0, radius: 0.08)
            let material = SimpleMaterial(color: .lightGray, isMetallic: false)
            return ModelEntity(mesh: mesh, materials: [material])
        }()

        leftLaunchPegSupport = {
            let mesh = MeshResource.generateCylinder(height: 1.0, radius: 0.045)
            let material = SimpleMaterial(color: .darkGray, isMetallic: false)
            return ModelEntity(mesh: mesh, materials: [material])
        }()

        rightLaunchPegSupport = {
            let mesh = MeshResource.generateCylinder(height: 1.0, radius: 0.045)
            let material = SimpleMaterial(color: .darkGray, isMetallic: false)
            return ModelEntity(mesh: mesh, materials: [material])
        }()

        leftLaunchPegBase = {
            let mesh = MeshResource.generateBox(size: [0.28, 0.14, 0.28])
            let material = SimpleMaterial(color: .gray, isMetallic: false)
            return ModelEntity(mesh: mesh, materials: [material])
        }()

        rightLaunchPegBase = {
            let mesh = MeshResource.generateBox(size: [0.28, 0.14, 0.28])
            let material = SimpleMaterial(color: .gray, isMetallic: false)
            return ModelEntity(mesh: mesh, materials: [material])
        }()
    }

    static func makeTowerPrototype(towerHeight: Float) -> ModelEntity {
        ModelEntity(
            mesh: .generateBox(size: [0.25, towerHeight, 0.25]),
            materials: [SimpleMaterial(color: .white, isMetallic: false)]
        )
    }
}
