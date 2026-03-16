import SwiftUI
import RealityKit
import Combine
import AppKit

enum TutorialEntryMode {
    case part1
    case part2
}

struct TutorialGameView: NSViewRepresentable {
    var entryMode: TutorialEntryMode = .part1
    var towerLayout: TowerLayoutConfig = .default
    var onTutorialMessageChanged: ((String) -> Void)? = nil
    var onSceneRequest: ((AppScene) -> Void)? = nil

    func makeNSView(context: Context) -> TutorialARView {
        TutorialARView(
            frame: .zero,
            entryMode: entryMode,
            towerLayout: towerLayout,
            onTutorialMessageChanged: onTutorialMessageChanged,
            onSceneRequest: onSceneRequest
        )
    }
    func updateNSView(_ nsView: TutorialARView, context: Context) {}
}

final class TutorialARView: ARView {
    private enum TutorialStep {
        case part2Intro
        case waitingForFirstInput
        case rightOriginal
        case rightWrapped
        case waitingForLeftOriginal
        case leftOriginal
        case leftWrapped
        case waitingForPart1Complete
        case part1Completed
    }

    private let worldPhysicsConfig: GameARView.WorldPhysicsConfig = .default
    private let launchSequenceConfig: GameARView.LaunchSequenceConfig = .default
    private let cameraFollowConfig: GameARView.CameraFollowConfig = .default
    private let entryMode: TutorialEntryMode
    private let towerLayoutConfig: TowerLayoutConfig

    private let world = AnchorEntity(world: .zero)
    private let player = ModelEntity(
        mesh: .generateSphere(radius: 0.12),
        materials: [SimpleMaterial(color: .red, isMetallic: false)]
    )
    private let camera = PerspectiveCamera()
    private let cameraAnchor = AnchorEntity(world: .zero)

    private let audio = SpatialAudioRig()
    private let webRenderer: WebRenderer

    private let onSceneRequest: ((AppScene) -> Void)?
    private let onTutorialMessageChanged: ((String) -> Void)?

    private var updateSub: Cancellable?
    private var playerPos: SIMD3<Float> = .zero

    private var tutorialStep: TutorialStep

    private var leftTower: ModelEntity?
    private var rightTower: ModelEntity?
    private var leftTowerSourceID: UUID?
    private var rightTowerSourceID: UUID?
    private var blinkElapsed: Float = 0

    private let groundThickness: Float = 0.05
    private let tutorialTowerForwardDistance: Float = 12.0
    private let soloListenVolume: Float = 1.0
    init(
        frame frameRect: CGRect,
        entryMode: TutorialEntryMode = .part1,
        towerLayout: TowerLayoutConfig = .default,
        onTutorialMessageChanged: ((String) -> Void)? = nil,
        onSceneRequest: ((AppScene) -> Void)? = nil
    ) {
        self.entryMode = entryMode
        self.towerLayoutConfig = towerLayout
        self.onTutorialMessageChanged = onTutorialMessageChanged
        self.onSceneRequest = onSceneRequest
        self.webRenderer = WebRenderer(world: world)
        self.tutorialStep = entryMode == .part1 ? .rightOriginal : .part2Intro

        super.init(frame: frameRect)
        setupScene()
        setupAudio()
        setupUpdateLoop()
        pushTutorialMessage(currentStepMessage())
    }

    @MainActor required init(frame frameRect: CGRect) {
        self.entryMode = .part1
        self.towerLayoutConfig = .default
        self.onTutorialMessageChanged = nil
        self.onSceneRequest = nil
        self.webRenderer = WebRenderer(world: world)
        self.tutorialStep = .rightOriginal

        super.init(frame: frameRect)
        setupScene()
        setupAudio()
        setupUpdateLoop()
        pushTutorialMessage(currentStepMessage())
    }

    @MainActor required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        audio.stop()
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if event.isARepeat { return }
        let c = (event.charactersIgnoringModifiers ?? "").lowercased()

        if c == "a" { onSceneRequest?(.game); return }
        if c == "s" { onSceneRequest?(.tutorialPart1); return }
        if c == "d" { onSceneRequest?(.tutorialPart2); return }

        if c == "q" {
            if tutorialStep == .leftOriginal {
                attemptShoot(side: .left)
                return
            }
            if tutorialStep == .leftWrapped {
                releaseWrappedWebSoftly(side: .left)
                transitionToStep(.part1Completed)
                return
            }
            pushTutorialMessage("Please follow the current tutorial step.")
            return
        }

        if c == "e" {
            if tutorialStep == .rightOriginal {
                attemptShoot(side: .right)
                return
            }
            if tutorialStep == .rightWrapped {
                releaseWrappedWebSoftly(side: .right)
                transitionToStep(.leftOriginal)
                return
            }
            pushTutorialMessage("Please follow the current tutorial step.")
            return
        }
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

    private func setupAudio() {
        audio.configureGeneratedTowerBaseLoop()

        if let leftTower {
            leftTowerSourceID = audio.addLoopingSource(
                at: leftTower.position(relativeTo: nil),
                volume: 0,
                toneVariant: .normal
            )
        }

        if let rightTower {
            rightTowerSourceID = audio.addLoopingSource(
                at: rightTower.position(relativeTo: nil),
                volume: 0,
                toneVariant: .normal
            )
        }

        audio.start()
        audio.setListenerPosition(playerPos)
        applyAudioMixForCurrentStep()
    }

    private func setupUpdateLoop() {
        updateSub = scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            guard let self else { return }
            let dt = Float(event.deltaTime)
            self.tickTutorial(deltaTime: dt)
        }
    }

    private func tickTutorial(deltaTime: Float) {
        updateCameraFollow()
        updateTowerBlinkHighlight(deltaTime: deltaTime)

        webRenderer.tick(deltaTime: deltaTime)
        audio.setListenerPosition(playerPos)
    }

    private func transitionToStep(_ step: TutorialStep) {
        tutorialStep = step
        applyAudioMixForCurrentStep()
        pushTutorialMessage(currentStepMessage())
    }

    private func currentStepMessage() -> String {
        switch tutorialStep {
        case .part2Intro:
            return "Welcome to tutorial part 2."
        case .waitingForFirstInput:
            return "Welcome to tutorial."
        case .rightOriginal:
            return "Right tower sound is active. Press right hand grip (E) to shoot web."
        case .rightWrapped:
            return "The sound changed (web still attached). Press right hand grip (E) again to continue."
        case .waitingForLeftOriginal:
            return "Get ready for the next step."
        case .leftOriginal:
            return "Left tower sound is active. Press left hand grip (Q) to shoot web."
        case .leftWrapped:
            return "The sound changed (web still attached). Press left hand grip (Q) again to finish."
        case .waitingForPart1Complete:
            return "Almost done."
        case .part1Completed:
            return "Tutorial completed."
        }
    }

    private func pushTutorialMessage(_ message: String) {
        print("[tutorial] \(message)")
        onTutorialMessageChanged?(message)
    }

    private func attemptShoot(side: TowerSide) {
        guard tutorialStep != .part1Completed else { return }

        if tutorialStep == .rightOriginal, side != .right {
            pushTutorialMessage("Use E to shoot the RIGHT tower in this step.")
            return
        }

        if tutorialStep == .leftOriginal, side != .left {
            pushTutorialMessage("Use Q to shoot the LEFT tower in this step.")
            return
        }

        if tutorialStep != .rightOriginal && tutorialStep != .leftOriginal {
            pushTutorialMessage("Please follow the current tutorial step.")
            return
        }

        let targetTower = (side == .left) ? leftTower : rightTower
        let sourceID = (side == .left) ? leftTowerSourceID : rightTowerSourceID
        guard let targetTower, let sourceID else { return }

        let towerPosition = targetTower.position(relativeTo: nil)
        let start = playerPos
        let end = SIMD3<Float>(towerPosition.x, towerPosition.y + towerLayoutConfig.towerHeight * 0.5, towerPosition.z)

        webRenderer.updateWeb(from: start, to: end)

        audio.setSourceToneVariant(sourceID: sourceID, variant: .muffled)

        if tutorialStep == .rightOriginal && side == .right {
            transitionToStep(.rightWrapped)
            return
        }

        if tutorialStep == .leftOriginal && side == .left {
            transitionToStep(.leftWrapped)
        }
    }

    private func releaseWrappedWebSoftly(side: TowerSide) {
        let targetTower = (side == .left) ? leftTower : rightTower
        let sourceID = (side == .left) ? leftTowerSourceID : rightTowerSourceID
        guard let targetTower else {
            webRenderer.hideWeb()
            return
        }

        let towerPosition = targetTower.position(relativeTo: nil)
        let end = SIMD3<Float>(towerPosition.x, towerPosition.y + towerLayoutConfig.towerHeight * 0.5, towerPosition.z)
        webRenderer.dropCurrentWebSoftly(from: playerPos, to: end, lifetime: 0.9)
        if let sourceID {
            audio.setSourceToneVariant(sourceID: sourceID, variant: .normal)
        }
    }

    private func applyAudioMixForCurrentStep() {
        switch tutorialStep {
        case .part2Intro:
            if let leftTowerSourceID {
                audio.setSourceToneVariant(sourceID: leftTowerSourceID, variant: .normal)
                audio.setSourceVolume(sourceID: leftTowerSourceID, volume: 0)
            }
            if let rightTowerSourceID {
                audio.setSourceToneVariant(sourceID: rightTowerSourceID, variant: .normal)
                audio.setSourceVolume(sourceID: rightTowerSourceID, volume: 0)
            }
        case .waitingForFirstInput:
            if let leftTowerSourceID {
                audio.setSourceToneVariant(sourceID: leftTowerSourceID, variant: .normal)
                audio.setSourceVolume(sourceID: leftTowerSourceID, volume: 0)
            }
            if let rightTowerSourceID {
                audio.setSourceToneVariant(sourceID: rightTowerSourceID, variant: .normal)
                audio.setSourceVolume(sourceID: rightTowerSourceID, volume: 0)
            }
        case .rightOriginal:
            if let leftTowerSourceID {
                audio.setSourceToneVariant(sourceID: leftTowerSourceID, variant: .normal)
                audio.setSourceVolume(sourceID: leftTowerSourceID, volume: 0)
            }
            if let rightTowerSourceID {
                audio.setSourceToneVariant(sourceID: rightTowerSourceID, variant: .normal)
                audio.setSourceVolume(sourceID: rightTowerSourceID, volume: soloListenVolume)
            }
        case .rightWrapped:
            if let leftTowerSourceID {
                audio.setSourceToneVariant(sourceID: leftTowerSourceID, variant: .normal)
                audio.setSourceVolume(sourceID: leftTowerSourceID, volume: 0)
            }
            if let rightTowerSourceID {
                audio.setSourceToneVariant(sourceID: rightTowerSourceID, variant: .muffled)
                audio.setSourceVolume(sourceID: rightTowerSourceID, volume: soloListenVolume)
            }
        case .waitingForLeftOriginal:
            if let leftTowerSourceID {
                audio.setSourceToneVariant(sourceID: leftTowerSourceID, variant: .normal)
                audio.setSourceVolume(sourceID: leftTowerSourceID, volume: 0)
            }
            if let rightTowerSourceID {
                audio.setSourceToneVariant(sourceID: rightTowerSourceID, variant: .normal)
                audio.setSourceVolume(sourceID: rightTowerSourceID, volume: 0)
            }
        case .leftOriginal:
            if let leftTowerSourceID {
                audio.setSourceToneVariant(sourceID: leftTowerSourceID, variant: .normal)
                audio.setSourceVolume(sourceID: leftTowerSourceID, volume: soloListenVolume)
            }
            if let rightTowerSourceID {
                audio.setSourceToneVariant(sourceID: rightTowerSourceID, variant: .normal)
                audio.setSourceVolume(sourceID: rightTowerSourceID, volume: 0)
            }
        case .leftWrapped:
            if let leftTowerSourceID {
                audio.setSourceToneVariant(sourceID: leftTowerSourceID, variant: .muffled)
                audio.setSourceVolume(sourceID: leftTowerSourceID, volume: soloListenVolume)
            }
            if let rightTowerSourceID {
                audio.setSourceToneVariant(sourceID: rightTowerSourceID, variant: .normal)
                audio.setSourceVolume(sourceID: rightTowerSourceID, volume: 0)
            }
        case .waitingForPart1Complete, .part1Completed:
            if let leftTowerSourceID {
                audio.setSourceToneVariant(sourceID: leftTowerSourceID, variant: .normal)
                audio.setSourceVolume(sourceID: leftTowerSourceID, volume: 0)
            }
            if let rightTowerSourceID {
                audio.setSourceToneVariant(sourceID: rightTowerSourceID, variant: .normal)
                audio.setSourceVolume(sourceID: rightTowerSourceID, volume: 0)
            }
        }
    }

    private func updateTowerBlinkHighlight(deltaTime: Float) {
        blinkElapsed += deltaTime
        let isRedPhase = Int(blinkElapsed / 0.25).isMultiple(of: 2)

        let activeSide: TowerSide?
        switch tutorialStep {
        case .part2Intro:
            activeSide = nil
        case .waitingForFirstInput:
            activeSide = nil
        case .rightOriginal:
            activeSide = .right
        case .rightWrapped:
            activeSide = nil
        case .waitingForLeftOriginal:
            activeSide = nil
        case .leftOriginal:
            activeSide = .left
        case .leftWrapped:
            activeSide = nil
        case .waitingForPart1Complete:
            activeSide = nil
        case .part1Completed:
            activeSide = nil
        }

        applyTowerAppearance(tower: leftTower, isActive: activeSide == .left, isRedPhase: isRedPhase)
        applyTowerAppearance(tower: rightTower, isActive: activeSide == .right, isRedPhase: isRedPhase)
    }

    private func applyTowerAppearance(tower: ModelEntity?, isActive: Bool, isRedPhase: Bool) {
        guard let tower else { return }
        let color: NSColor
        if isActive {
            color = isRedPhase ? .systemRed : .white
        } else {
            color = .white
        }
        tower.model?.materials = [SimpleMaterial(color: color, isMetallic: false)]
    }

    private func startPlayerPosition() -> SIMD3<Float> {
        SceneGeometryHelper.startPlayerPosition(
            centerX: worldPhysicsConfig.centerX,
            groundY: worldPhysicsConfig.groundY,
            rooftopStartZ: worldPhysicsConfig.rooftopStartZ,
            startTowerHeight: launchSequenceConfig.startTowerHeight
        )
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
        self.leftTower = leftTower

        let rightTower = ModelEntity(
            mesh: .generateBox(size: towerSize),
            materials: [SimpleMaterial(color: .white, isMetallic: false)]
        )
        rightTower.position = [towerLayoutConfig.rightX, towerHeight * 0.5, towerZ]
        world.addChild(rightTower)
        self.rightTower = rightTower
    }

    private func makeGroundEntity() -> ModelEntity {
        SceneGeometryHelper.makeGroundEntity(
            towerLayoutConfig: towerLayoutConfig,
            groundThickness: groundThickness
        )
    }

    private func addStreetReferenceProps() {
        SceneGeometryHelper.addStreetReferenceProps(
            to: world,
            towerLayoutConfig: towerLayoutConfig
        )
    }
}
