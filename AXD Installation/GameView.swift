//
//  GameView.swift
//  AXD Installation
//
//  Created by chihyin wang on 02/03/2026.
//

import SwiftUI
import RealityKit
import Combine
import AppKit

// MARK: - SwiftUI Bridge (SwiftUI -> AppKit -> RealityKit)

struct GameView: NSViewRepresentable {
    var focusTiming: FocusTimingConfig = .default
    var towerLayout: TowerLayoutConfig = .default
    var swingPhysics: SwingPhysicsConfig = .default

    func makeNSView(context: Context) -> GameARView {
        GameARView(
            frame: .zero,
            focusTiming: focusTiming,
            towerLayout: towerLayout,
            swingPhysics: swingPhysics
        )
    }
    func updateNSView(_ nsView: GameARView, context: Context) {}
}

// MARK: - RealityKit View (macOS desktop, non-AR)

final class GameARView: ARView {

    // MARK: Types

    private struct SwingState {
        let anchor: SIMD3<Float>
        var ropeLengthYZ: Float       // Current rope length in the YZ plane (changes per frame via reel-in)
        let ropeTargetYZ: Float       // Target rope length in the YZ plane (computed once on attach)
        let towerZ: Float
        let rowIndex: Int
    }

    // MARK: Configuration (tuning knobs)

    // Core world / physics
    private let centerX: Float = 0
    private let groundY: Float = 0.12
    private let rooftopY: Float = 7.0
    private let rooftopStartZ: Float = -14.0
    private let gravity: Float = 9.8

    // Swing behavior
    private let swingPhysicsConfig: SwingPhysicsConfig

    // Focus ("五感世界") timing
    private let focusStateMachine: FocusStateMachine
    private var focusActive: Bool { focusStateMachine.isActive }

    // Web attach & rope constraints are read from swingPhysicsConfig

    // Tower layout
    private let towerLayoutConfig: TowerLayoutConfig
    private let towerTrack: TowerTrack
    
    // Optional: record which side the next tower is on (useful for debugging / player feedback)
    private var expectedNextSide: TowerSide? = nil

    // Ground mesh
    private let groundThickness: Float = 0.05

    // MARK: Scene entities (RealityKit graph)

    private var updateSub: Cancellable?

    private let world = AnchorEntity(world: .zero)

    private let player = ModelEntity(
        mesh: .generateSphere(radius: 0.12),
        materials: [SimpleMaterial(color: .red, isMetallic: false)]
    )

    private let camera = PerspectiveCamera()
    private let cameraAnchor = AnchorEntity(world: .zero)

    private lazy var towerPrototype: ModelEntity = {
        let m = ModelEntity(
            mesh: .generateBox(size: [0.25, towerLayoutConfig.towerHeight, 0.25]),
            materials: [SimpleMaterial(color: .white, isMetallic: false)]
        )
        return m
    }()

    private let audio: SpatialAudioRig
    private let audioMixController: TowerAudioMixController
    private let gameStateMachine = GameStateMachine()
    private let webRenderer: WebRenderer

    // MARK: Runtime state

    private var playerPos: SIMD3<Float> = [0, 4.0, -14.0]
    private var playerVel: SIMD3<Float> = .zero

    private var swing: SwingState? = nil

    // MARK: Init

    init(
        frame frameRect: CGRect,
        focusTiming: FocusTimingConfig = .default,
        towerLayout: TowerLayoutConfig = .default,
        swingPhysics: SwingPhysicsConfig = .default
    ) {
        self.swingPhysicsConfig = swingPhysics
        self.towerLayoutConfig = towerLayout
        self.towerTrack = TowerTrack(layout: towerLayout)
        self.focusStateMachine = FocusStateMachine(timing: focusTiming)
        self.audio = SpatialAudioRig()
        self.audioMixController = TowerAudioMixController(audio: audio)
        self.webRenderer = WebRenderer(world: world)
        super.init(frame: frameRect)
        setupScene()
        setupUpdateLoop()

        audio.start()
    }

    @MainActor required init(frame frameRect: CGRect) {
        self.swingPhysicsConfig = .default
        self.towerLayoutConfig = .default
        self.towerTrack = TowerTrack(layout: .default)
        self.focusStateMachine = FocusStateMachine(timing: .default)
        self.audio = SpatialAudioRig()
        self.audioMixController = TowerAudioMixController(audio: audio)
        self.webRenderer = WebRenderer(world: world)
        super.init(frame: frameRect)
        setupScene()
        setupUpdateLoop()

        audio.start()
    }

    @MainActor required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Keyboard focus & events

    override var acceptsFirstResponder: Bool { true } // Needed to receive key events

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self) // Attempt to grab keyboard focus
        print("[focus] firstResponder =", String(describing: window?.firstResponder))
    }

    override func keyDown(with event: NSEvent) {
        if event.isARepeat { return }

        let c = (event.charactersIgnoringModifiers ?? "").lowercased()
        if c == "q" { attemptShoot(.left); return }
        if c == "e" { attemptShoot(.right); return }
        if c == "r" { restartGame(); return }
    }

    // MARK: Scene setup

    private func setupScene() {
        environment.background = .color(.black)
        scene.addAnchor(world)

        let ground = makeGroundEntity()
        world.addChild(ground)

        // Player starts on the rooftop
        playerPos = [centerX, rooftopY, rooftopStartZ]
        player.position = playerPos
        playerVel = .zero
        gameStateMachine.transition(to: .rooftop)
        world.addChild(player)

        // Generate rows of towers (alternating left/right)
        towerTrack.rebuild(in: world, prototype: towerPrototype)

        // Spatial audio: one looping source per tower, listener follows player
        audio.configure(loopFileName: "tower_loop_mono1", fileExt: "wav")

        for node in towerTrack.nodes {
            let sourceID = audio.addLoopingSource(at: node.tower.position(relativeTo: nil))
            audioMixController.registerTowerSource(sourceID)
        }

        audio.start()
        audioMixController.resetToNormalMix()
        audio.setListenerPosition(player.position(relativeTo: nil))

        // Light so towers are visible
        let light = DirectionalLight()
        light.light.intensity = 2000
        light.look(at: .zero, from: [1, 2, 2], relativeTo: nil)
        world.addChild(light)

        // Camera setup
        camera.camera.fieldOfViewInDegrees = 60
        camera.position = .zero

        cameraAnchor.addChild(camera)
        scene.addAnchor(cameraAnchor)
    }

    // MARK: Update loop (per frame)

    private func setupUpdateLoop() {
        // SceneEvents.Update fires every frame
        updateSub = scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            guard let self else { return }

            let realDt = Float(event.deltaTime)
            handleFocusTick(realDt: realDt)
            let dt = realDt * focusStateMachine.simulationTimeScale
            updatePlayerState(dt: dt)
            applyFrameOutputs()
        }
    }

    private func handleFocusTick(realDt: Float) {
        let focusTickResult = focusStateMachine.tick(realDeltaTime: realDt)
        if focusTickResult.didStart {
            print("[focus] start (delayed)")
        }
        if focusTickResult.didEnd {
            expectedNextSide = nil
            audioMixController.clearFocusTarget()
            print("[focus] end")
        }
    }

    private func updatePlayerState(dt: Float) {
        switch gameStateMachine.state {
        case .rooftop:
            handleRooftopState()
        case .swinging:
            handleSwingingState(dt: dt)
        case .falling:
            handleFallingState(dt: dt)
        case .grounded:
            handleGroundedState()
        }
    }

    private func handleRooftopState() {
        // Standing still until the first Q/E attaches a web
        playerPos = [centerX, rooftopY, rooftopStartZ]
        playerVel = .zero
    }

    private func handleSwingingState(dt: Float) {
        guard var s = swing else {
            gameStateMachine.transition(to: .falling)
            return
        }

        // 0) Reel-in: move ropeLengthYZ toward ropeTargetYZ gradually (prevents teleport)
        let reelSpeed: Float = 6.0
        let diff = s.ropeTargetYZ - s.ropeLengthYZ
        let reelStep = max(min(diff, reelSpeed * dt), -reelSpeed * dt)
        s.ropeLengthYZ += reelStep

        // 1) Integrate motion in the YZ plane
        var p2 = SIMD2<Float>(playerPos.y - s.anchor.y, playerPos.z - s.anchor.z)
        var v2 = SIMD2<Float>(playerVel.y, playerVel.z)

        // Gravity affects Y (p2.x)
        v2.x += -gravity * dt
        p2 += v2 * dt

        // 2) Constraint: project position onto the circle (radius = ropeLengthYZ)
        let r = max(simd_length(p2), 0.001)
        p2 *= (s.ropeLengthYZ / r)

        // 3) Remove radial velocity (keep tangential component)
        let radial = p2 / s.ropeLengthYZ
        let vRad = simd_dot(v2, radial)
        v2 -= vRad * radial

        // Small damping (optional)
        v2 *= 0.999

        // 4) Write back to 3D (X locked to center line)
        playerPos.x = centerX
        playerPos.y = s.anchor.y + p2.x
        playerPos.z = s.anchor.z + p2.y
        playerVel.y = v2.x
        playerVel.z = v2.y

        // 5) Update web every frame (sticks to player + anchor)
        webRenderer.updateWeb(from: playerPos, to: s.anchor)

        // 6) Detach later, while rising, and not too low (to emphasize airtime + visible arc)
        let farEnough = playerPos.z < s.towerZ - swingPhysicsConfig.detachAfterPassing
        let rising = playerVel.y > 0.4
        let highEnough = playerPos.y > (groundY + swingPhysicsConfig.minClearanceY + 0.6)

        if farEnough && rising && highEnough {
            let passedRow = s.rowIndex
            print(String(format: "[web] detach y=%.2f z=%.2f vy=%.2f vz=%.2f",
                         playerPos.y, playerPos.z, playerVel.y, playerVel.z))

            swing = nil
            webRenderer.hideWeb()
            gameStateMachine.transition(to: .falling)

            // Schedule focus to start after a short delay
            focusStateMachine.scheduleAfterDelay()

            let nextIndex = passedRow + 1
            if let nextSide = towerTrack.side(at: nextIndex) {
                expectedNextSide = nextSide
                audioMixController.setFocusTargetRowIndex(nextIndex)
                print("[focus] will start after delay. next side should be \(expectedNextSide!)")
            } else {
                expectedNextSide = nil
                audioMixController.clearFocusTarget()
                print("[focus] will start after delay (no next tower)")
            }
            return
        }

        // Persist updated rope length
        swing = s
    }

    private func handleFallingState(dt: Float) {
        // Free fall until hitting the ground
        playerVel.y += -gravity * dt
        playerPos += playerVel * dt
        playerPos.x = centerX

        if playerPos.y <= groundY {
            playerPos.y = groundY
            playerVel = .zero
            gameStateMachine.transition(to: .grounded)
        }
    }

    private func handleGroundedState() {
        // Grounded state (no movement yet)
        playerPos.x = centerX
        playerPos.y = groundY
    }

    private func applyFrameOutputs() {
        // Apply transform to the entity
        player.position = playerPos
        updateCameraFollow()

        // Listener always follows the player
        audio.setListenerPosition(playerPos)
        audioMixController.updateMix(isFocusActive: focusActive)
    }

    private func restartGame() {
        print("[game] restart")

        // Reset core gameplay state
        swing = nil
        gameStateMachine.transition(to: .rooftop)
        playerPos = [centerX, rooftopY, rooftopStartZ]
        playerVel = .zero

        // Reset progression / focus / guidance
        towerTrack.resetProgress()
        focusStateMachine.reset()
        expectedNextSide = nil

        // Reset presentation systems
        webRenderer.hideWeb()
        audioMixController.clearFocusTarget()
        audioMixController.resetToNormalMix()
        audio.restartAllLoopsFromBeginning()

        // Apply immediately so restart is visually/audio consistent in the same frame
        applyFrameOutputs()
    }

    // MARK: Input gating (Q/E -> attemptShoot -> shootWeb)

    private func attemptShoot(_ side: TowerSide) {
        // 1) Block shooting while grounded (prevents underground swinging)
        if gameStateMachine.isGrounded {
            print("[shoot] blocked (grounded/dead)")
            return
        }

        // 2) First shot is allowed from rooftop
        if gameStateMachine.isRooftop {
            shootWeb(to: side)
            return
        }

        // 3) After the first tower: only allow shooting during focus
        guard focusActive else {
            print("[shoot] blocked (not in focus)")
            return
        }

        // Optional: enforce the expected alternating side rhythm
        if let expected = expectedNextSide, expected != side {
            print("[shoot] wrong side. expected \(expected), got \(side)")
            return
        }

        // Consume focus immediately on a successful shot (return to normal time)
        shootWeb(to: side)
        focusStateMachine.reset()
        expectedNextSide = nil
        audioMixController.clearFocusTarget()
        print("[focus] consumed by shot")
    }

    private func shootWeb(to side: TowerSide) {
        // Target the next row
        let nextIndex = towerTrack.nextIndex(fromSwingRow: swing?.rowIndex)
        guard let node = towerTrack.node(at: nextIndex) else {
            print("[web] no next tower")
            return
        }
        guard node.side == side else {
            print("[web] wrong side. next is \(node.side), you pressed \(side)")
            return
        }

        let tower = node.tower
        let towerPos = tower.position(relativeTo: nil)

        // Anchor = top of tower + extra height (to increase swing angle)
        let towerTopY = towerPos.y + towerLayoutConfig.towerHeight * 0.5
        let anchor = SIMD3<Float>(towerPos.x, towerTopY + swingPhysicsConfig.webAttachExtraHeight, towerPos.z)

        let dx = centerX - anchor.x
        let dy = playerPos.y - anchor.y
        let dz = playerPos.z - anchor.z
        let L2 = dx*dx + dy*dy + dz*dz
        let yz2 = max(L2 - dx*dx, 0.01)
        let measuredYZ = sqrt(yz2)

        // Keep lowest point above ground: lowest approx = anchor.y - ropeYZ
        let maxByClearance = max(anchor.y - (groundY + swingPhysicsConfig.minClearanceY), swingPhysicsConfig.ropeMinYZ)
        let ropeMax = min(swingPhysicsConfig.ropeMaxHard, maxByClearance)

        // Target rope length (scaled + clamped)
        let ropeTargetYZ = min(max(measuredYZ * swingPhysicsConfig.ropeScale, swingPhysicsConfig.ropeMinYZ), ropeMax)

        // Current rope length starts at measuredYZ (keeps current position -> no teleport)
        let ropeCurrentYZ = measuredYZ

        swing = SwingState(anchor: anchor,
                           ropeLengthYZ: ropeCurrentYZ,
                           ropeTargetYZ: ropeTargetYZ,
                           towerZ: towerPos.z,
                           rowIndex: nextIndex)

        print(String(format: "[web] measuredYZ=%.2f targetYZ=%.2f anchorY=%.2f minY(target)≈%.2f",
                     measuredYZ, ropeTargetYZ, anchor.y, anchor.y - ropeTargetYZ))
        towerTrack.registerAttach(rowIndex: nextIndex)
        gameStateMachine.transition(to: .swinging)

        // Add initial tangential velocity in the YZ plane to ensure forward swing
        // radial = (dy, dz), tangent = (-dz, dy) normalized
        let radial = SIMD2<Float>(dy, dz)
        let rLen = max(simd_length(radial), 0.001)
        let rN = radial / rLen
        let tangent = SIMD2<Float>(-rN.y, rN.x)

        playerVel.y += tangent.x * swingPhysicsConfig.initialSwingSpeed
        playerVel.z += tangent.y * swingPhysicsConfig.initialSwingSpeed

        print("[web] attach row=\(nextIndex) side=\(side) anchor=\(anchor)")
    }

    // MARK: Camera

    private func updateCameraFollow() {
        // Offset behind & above player (forward is -Z, so "behind" is +Z)
        let offset: SIMD3<Float> = [0, 1.6, 3.2]

        let target = playerPos
        let camPos = target + offset

        cameraAnchor.position = camPos
        cameraAnchor.look(at: target, from: camPos, relativeTo: nil)
    }

    // MARK: Ground

    private func makeGroundEntity() -> ModelEntity {
        // Ground size: wide enough for lanes; deep enough to cover the farthest tower row
        let width: Float = max(10, abs(towerLayoutConfig.leftX) + abs(towerLayoutConfig.rightX) + 6)
        let depth: Float = Float(towerLayoutConfig.rowCount + 3) * towerLayoutConfig.rowSpacing + 8

        let mesh = MeshResource.generateBox(size: [width, groundThickness, depth])
        let mat = SimpleMaterial(color: .gray, isMetallic: false)
        let ground = ModelEntity(mesh: mesh, materials: [mat])

        // Place so the top surface is at y=0, extending from z=0 forward into negative Z
        ground.position = [0, -groundThickness * 0.5, -depth * 0.5]
        return ground
    }

}
