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
    var leftArmPoseStateCode: Int?
    var rightArmPoseStateCode: Int?
    var onTutorialMessageChanged: ((String) -> Void)? = nil
    var onSceneRequest: ((AppScene) -> Void)? = nil

    func makeNSView(context: Context) -> TutorialARView {
        TutorialARView(
            frame: .zero,
            entryMode: entryMode,
            towerLayout: towerLayout,
            leftArmPoseStateCode: leftArmPoseStateCode,
            rightArmPoseStateCode: rightArmPoseStateCode,
            onTutorialMessageChanged: onTutorialMessageChanged,
            onSceneRequest: onSceneRequest
        )
    }

    func updateNSView(_ nsView: TutorialARView, context: Context) {
        nsView.updateArmPoseStateCodes(
            left: leftArmPoseStateCode,
            right: rightArmPoseStateCode
        )
    }
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

    private var leftArmPoseStateCode: Int?
    private var rightArmPoseStateCode: Int?

    private var tutorialStep: TutorialStep

    private var leftTower: ModelEntity?
    private var rightTower: ModelEntity?
    private var leftTowerSourceID: UUID?
    private var rightTowerSourceID: UUID?
    private var blinkElapsed: Float = 0

    private let groundThickness: Float = 0.05
    private let tutorialTowerForwardDistance: Float = 12.0
    private let soloListenVolume: Float = 1.0
    private let requiredArmPoseStateCode: Int = 2
    private let stepDelaySeconds: Float = 2.5
    private var stepElapsed: Float = 0

    init(
        frame frameRect: CGRect,
        entryMode: TutorialEntryMode = .part1,
        towerLayout: TowerLayoutConfig = .default,
        leftArmPoseStateCode: Int?,
        rightArmPoseStateCode: Int?,
        onTutorialMessageChanged: ((String) -> Void)? = nil,
        onSceneRequest: ((AppScene) -> Void)? = nil
    ) {
        self.entryMode = entryMode
        self.towerLayoutConfig = towerLayout
        self.leftArmPoseStateCode = leftArmPoseStateCode
        self.rightArmPoseStateCode = rightArmPoseStateCode
        self.onTutorialMessageChanged = onTutorialMessageChanged
        self.onSceneRequest = onSceneRequest
        self.webRenderer = WebRenderer(world: world)
        self.tutorialStep = entryMode == .part1 ? .waitingForFirstInput : .part2Intro

        super.init(frame: frameRect)
        setupScene()
        setupAudio()
        setupUpdateLoop()
        pushTutorialMessage(currentStepMessage())
    }

    @MainActor required init(frame frameRect: CGRect) {
        self.entryMode = .part1
        self.towerLayoutConfig = .default
        self.leftArmPoseStateCode = nil
        self.rightArmPoseStateCode = nil
        self.onTutorialMessageChanged = nil
        self.onSceneRequest = nil
        self.webRenderer = WebRenderer(world: world)
        self.tutorialStep = .waitingForFirstInput

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

    func updateArmPoseStateCodes(left: Int?, right: Int?) {
        leftArmPoseStateCode = left
        rightArmPoseStateCode = right
    }

    override func keyDown(with event: NSEvent) {
        if event.isARepeat { return }
        let c = (event.charactersIgnoringModifiers ?? "").lowercased()

        if c == "a" { onSceneRequest?(.game); return }
        if c == "s" { onSceneRequest?(.tutorialPart1); return }
        if c == "d" { onSceneRequest?(.tutorialPart2); return }

        if c == "q" {
            if tutorialStep == .waitingForFirstInput {
                transitionToStep(.rightOriginal)
                return
            }
            attemptShoot(side: .left)
            return
        }

        if c == "e" {
            if tutorialStep == .waitingForFirstInput {
                transitionToStep(.rightOriginal)
                return
            }
            attemptShoot(side: .right)
            return
        }

        if c == "r" {
            attemptRelease(side: .right)
            return
        }

        if c == "w" {
            attemptRelease(side: .left)
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
        stepElapsed += deltaTime
        updateCameraFollow()
        updateTowerBlinkHighlight(deltaTime: deltaTime)

        webRenderer.tick(deltaTime: deltaTime)
        audio.setListenerPosition(playerPos)

        if tutorialStep == .waitingForLeftOriginal, stepElapsed >= stepDelaySeconds {
            transitionToStep(.leftOriginal)
        }

        if tutorialStep == .waitingForPart1Complete, stepElapsed >= stepDelaySeconds {
            transitionToStep(.part1Completed)
        }
    }

    private func transitionToStep(_ step: TutorialStep) {
        tutorialStep = step
        stepElapsed = 0
        applyAudioMixForCurrentStep()
        pushTutorialMessage(currentStepMessage())
    }

    private func currentStepMessage() -> String {
        switch tutorialStep {
        case .part2Intro:
            return "Welcome to the tutorial part 2. Please press the hand grip once to see the next step."
        case .waitingForFirstInput:
            return "Welcome to the tutorial part 1. Please press the hand grip once to see the next step."
        case .rightOriginal:
            return "This is the Sound Tower. It makes sound.\nPlease raise your right hand and keep pressing the right hand grip."
        case .rightWrapped:
            return "The sound changed! You are hearing a Sound Tower wrapped in web.\nNow you can release the hand grip to loosen the web."
        case .waitingForLeftOriginal:
            return "Great. Get ready for the next Sound Tower."
        case .leftOriginal:
            return "This is another Sound Tower on the left.\nPlease raise your left hand and press the hand grip."
        case .leftWrapped:
            return "This tower's sound changed too!\nNow you can release the hand grip to loosen the web."
        case .waitingForPart1Complete:
            return "Nice. Preparing the completion message..."
        case .part1Completed:
            return "Part 1 tutorial completed."
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

        let armPoseStateCode = (side == .left) ? leftArmPoseStateCode : rightArmPoseStateCode
        guard armPoseStateCode == requiredArmPoseStateCode else {
            let sideLabel = (side == .left) ? "Left hand" : "Right hand"
            pushTutorialMessage("\(sideLabel): armPoseStateCode must be 2 to shoot.")
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

    private func attemptRelease(side: TowerSide) {
        if tutorialStep == .rightWrapped {
            guard side == .right else {
                pushTutorialMessage("Use R in this step.")
                return
            }
            webRenderer.hideWeb()
            if let rightTowerSourceID {
                audio.setSourceToneVariant(sourceID: rightTowerSourceID, variant: .normal)
            }
            transitionToStep(.waitingForLeftOriginal)
            return
        }

        if tutorialStep == .leftWrapped {
            guard side == .left else {
                pushTutorialMessage("Use W in this step.")
                return
            }
            webRenderer.hideWeb()
            if let leftTowerSourceID {
                audio.setSourceToneVariant(sourceID: leftTowerSourceID, variant: .normal)
            }
            transitionToStep(.waitingForPart1Complete)
            return
        }

        pushTutorialMessage("Please shoot first.")
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
