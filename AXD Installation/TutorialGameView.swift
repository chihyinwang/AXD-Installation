import SwiftUI
import RealityKit
import Combine
import AppKit

struct TutorialGameView: NSViewRepresentable {
    var towerLayout: TowerLayoutConfig = .default
    var onToggleScene: (() -> Void)? = nil

    func makeNSView(context: Context) -> TutorialARView {
        TutorialARView(
            frame: .zero,
            towerLayout: towerLayout,
            onToggleScene: onToggleScene
        )
    }

    func updateNSView(_ nsView: TutorialARView, context: Context) {}
}

final class TutorialARView: ARView {
    private let worldPhysicsConfig: GameARView.WorldPhysicsConfig = .default
    private let launchSequenceConfig: GameARView.LaunchSequenceConfig = .default
    private let cameraFollowConfig: GameARView.CameraFollowConfig = .default
    private let towerLayoutConfig: TowerLayoutConfig

    private let world = AnchorEntity(world: .zero)
    private let player = ModelEntity(
        mesh: .generateSphere(radius: 0.12),
        materials: [SimpleMaterial(color: .red, isMetallic: false)]
    )
    private let camera = PerspectiveCamera()
    private let cameraAnchor = AnchorEntity(world: .zero)

    private let onToggleScene: (() -> Void)?
    private var updateSub: Cancellable?
    private var playerPos: SIMD3<Float> = .zero

    private let groundThickness: Float = 0.05
    private let tutorialTowerForwardDistance: Float = 20.0

    init(
        frame frameRect: CGRect,
        towerLayout: TowerLayoutConfig = .default,
        onToggleScene: (() -> Void)? = nil
    ) {
        self.towerLayoutConfig = towerLayout
        self.onToggleScene = onToggleScene
        super.init(frame: frameRect)
        setupScene()
        setupUpdateLoop()
    }

    @MainActor required init(frame frameRect: CGRect) {
        self.towerLayoutConfig = .default
        self.onToggleScene = nil
        super.init(frame: frameRect)
        setupScene()
        setupUpdateLoop()
    }

    @MainActor required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if event.isARepeat { return }
        let c = (event.charactersIgnoringModifiers ?? "").lowercased()
        if c == "s" { onToggleScene?(); return }
    }

    private func setupScene() {
        environment.background = .color(.black)
        scene.addAnchor(world)

        let ground = makeGroundEntity()
        world.addChild(ground)
        addStreetReferenceProps()

        playerPos = startPlayerPosition()
        player.position = playerPos
        world.addChild(player)
        addTutorialTowers()

        let light = DirectionalLight()
        light.light.intensity = 2000
        light.look(at: .zero, from: [1, 2, 2], relativeTo: nil)
        world.addChild(light)

        camera.camera.fieldOfViewInDegrees = 60
        camera.camera.near = 0.05
        camera.camera.far = 500
        camera.position = .zero

        cameraAnchor.addChild(camera)
        scene.addAnchor(cameraAnchor)
    }

    private func setupUpdateLoop() {
        updateSub = scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
            guard let self else { return }
            self.updateCameraFollow()
        }
    }

    private func startPlayerPosition() -> SIMD3<Float> {
        let towerTopY = worldPhysicsConfig.groundY + launchSequenceConfig.startTowerHeight
        return SIMD3<Float>(worldPhysicsConfig.centerX, towerTopY + 0.12, worldPhysicsConfig.rooftopStartZ)
    }

    private func updateCameraFollow() {
        let highAltitude = min(
            max(0, playerPos.y - cameraFollowConfig.highAltitudeThreshold),
            cameraFollowConfig.highAltitudeCap
        )
        let extraBack = highAltitude * cameraFollowConfig.extraBackPerHighMeter
        let extraHeight = highAltitude * cameraFollowConfig.extraHeightPerHighMeter
        let lookDownBias = highAltitude * cameraFollowConfig.lookDownBiasPerHighMeter
        let offset: SIMD3<Float> = [
            0,
            cameraFollowConfig.baseHeight + extraHeight,
            cameraFollowConfig.baseBackDistance + extraBack
        ]

        let target = playerPos + SIMD3<Float>(0, -lookDownBias, 0)
        let camPos = target + offset
        cameraAnchor.position = camPos
        cameraAnchor.look(at: target, from: camPos, relativeTo: nil)
    }

    private func addTutorialTowers() {
        let towerHeight = towerLayoutConfig.towerHeight
        let towerSize = SIMD3<Float>(0.25, towerHeight, 0.25)
        let towerZ = playerPos.z - tutorialTowerForwardDistance

        let leftTower = ModelEntity(
            mesh: .generateBox(size: towerSize),
            materials: [SimpleMaterial(color: .white, isMetallic: false)]
        )
        leftTower.position = [towerLayoutConfig.leftX, towerHeight * 0.5, towerZ]
        world.addChild(leftTower)

        let rightTower = ModelEntity(
            mesh: .generateBox(size: towerSize),
            materials: [SimpleMaterial(color: .white, isMetallic: false)]
        )
        rightTower.position = [towerLayoutConfig.rightX, towerHeight * 0.5, towerZ]
        world.addChild(rightTower)
    }

    private func makeGroundEntity() -> ModelEntity {
        let width: Float = max(10, abs(towerLayoutConfig.leftX) + abs(towerLayoutConfig.rightX) + 6)
        let farthestTowerDistance = towerLayoutConfig.firstRowDistance
            + Float(max(towerLayoutConfig.rowCount - 1, 0)) * towerLayoutConfig.rowSpacing
        let depth: Float = farthestTowerDistance + 20

        let mesh = MeshResource.generateBox(size: [width, groundThickness, depth])
        let mat = SimpleMaterial(color: .darkGray, isMetallic: false)
        let ground = ModelEntity(mesh: mesh, materials: [mat])
        ground.position = [0, -groundThickness * 0.5, -depth * 0.5]
        return ground
    }

    private func addStreetReferenceProps() {
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
            let carMat = SimpleMaterial(color: color, isMetallic: false)
            let z = -(18 + Float(i) * 24)

            let rightCar = ModelEntity(mesh: .generateBox(size: carBodySize), materials: [carMat])
            rightCar.position = [carSideX, 0.5, z]
            world.addChild(rightCar)

            if i % 2 == 0 {
                let leftCar = ModelEntity(mesh: .generateBox(size: carBodySize), materials: [carMat])
                leftCar.position = [-carSideX, 0.5, z - 10]
                world.addChild(leftCar)
            }
        }
    }
}
