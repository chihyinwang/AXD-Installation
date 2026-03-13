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

    // MARK: Configuration (tuning knobs)

    // Core world / physics
    private let worldPhysicsConfig: WorldPhysicsConfig = .default
    private let audioGuidanceConfig: AudioGuidanceConfig = .default
    private let releaseConfig: ReleaseConfig = .default
    private let cameraFollowConfig: CameraFollowConfig = .default

    // Swing behavior
    private let swingPhysicsConfig: SwingPhysicsConfig

    // Focus mode timing
    private let focusStateMachine: FocusStateMachine
    private var focusActive: Bool { focusStateMachine.isActive }

    // Web attach & rope constraints are read from swingPhysicsConfig

    // Tower layout
    private let towerLayoutConfig: TowerLayoutConfig
    private let towerTrack: TowerTrack
    
    // Optional: record which side the next tower is on (useful for debugging / player feedback)
    private var expectedNextSide: TowerSide? = nil
    private var guidedTargetRowIndex: Int? = nil

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
    private let visibilityMaskSphere: ModelEntity = {
        let mesh = MeshResource.generateSphere(radius: 1.0)
        let material = UnlitMaterial(color: .black)
        return ModelEntity(mesh: mesh, materials: [material])
    }()
    private let releaseCueIndicator: ModelEntity = {
        let mesh = MeshResource.generateSphere(radius: 0.12)
        let material = UnlitMaterial(color: .yellow)
        let indicator = ModelEntity(mesh: mesh, materials: [material])
        indicator.scale = .zero
        return indicator
    }()

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
        if c == "w" { attemptRelease(.left); return }
        if c == "e" { attemptShoot(.right); return }
        if c == "r" { attemptRelease(.right); return }
        if c == "g" { restartGame(); return }
    }

    // MARK: Scene setup

    private func setupScene() {
        environment.background = .color(.black)
        scene.addAnchor(world)

        let ground = makeGroundEntity()
        world.addChild(ground)
        addStreetReferenceProps()

        // Player starts on the rooftop
        playerPos = [worldPhysicsConfig.centerX, worldPhysicsConfig.rooftopY, worldPhysicsConfig.rooftopStartZ]
        player.position = playerPos
        playerVel = .zero
        gameStateMachine.transition(to: .rooftop)
        world.addChild(player)
        world.addChild(releaseCueIndicator)

        // Generate rows of towers
        towerTrack.rebuild(in: world, prototype: towerPrototype)

        // Spatial audio: one looping source per tower, listener follows player
        audio.configure(loopFileName: "beep", fileExt: "wav")
        _ = audio.configureBackgroundLoop(fileName: "background_music", fileExt: "wav")

        for node in towerTrack.nodes {
            let sourceID = audio.addLoopingSource(at: node.tower.position(relativeTo: nil))
            audioMixController.registerTowerSource(sourceID)
        }
        let guideSourceID = audio.addLoopingSource(at: player.position(relativeTo: nil))
        audioMixController.registerGuideSource(guideSourceID)

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
        camera.camera.near = 0.05
        camera.camera.far = 500
        camera.position = .zero

        // Inverted sphere around the camera: keeps near objects visible and masks far objects to black.
        visibilityMaskSphere.position = .zero
        cameraAnchor.addChild(visibilityMaskSphere)
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
            applyFrameOutputs(realDeltaTime: realDt)
        }
    }

    private func handleFocusTick(realDt: Float) {
        let focusTickResult = focusStateMachine.tick(realDeltaTime: realDt)
        if focusTickResult.didStart {
            print("[focus] start (delayed)")
        }
        if focusTickResult.didEnd {
            expectedNextSide = nil
            guidedTargetRowIndex = nil
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
        playerPos = [worldPhysicsConfig.centerX, worldPhysicsConfig.rooftopY, worldPhysicsConfig.rooftopStartZ]
        playerVel = .zero
    }

    private func handleSwingingState(dt: Float) {
        guard var s = swing else {
            gameStateMachine.transition(to: .falling)
            return
        }

        // 0) Dynamic reel-in:
        // Keep the motion natural by tightening rope faster when approaching ground,
        // instead of hard-clamping player height.
        let dynamicRopeMax = max(
            s.anchor.y - (worldPhysicsConfig.groundY + swingPhysicsConfig.minClearanceY + releaseConfig.swingGroundSafetyMargin),
            swingPhysicsConfig.ropeMinYZ
        )
        s.ropeTargetYZ = min(s.ropeTargetYZ, dynamicRopeMax)

        let groundProximity = max(0, (worldPhysicsConfig.groundY + swingPhysicsConfig.minClearanceY + 0.9) - playerPos.y)
        let reelSpeed: Float = 6.0 + groundProximity * 10.0
        let diff = s.ropeTargetYZ - s.ropeLengthYZ
        let reelStep = max(min(diff, reelSpeed * dt), -reelSpeed * dt)
        s.ropeLengthYZ += reelStep

        // 1) Integrate motion in the YZ plane
        var p2 = SIMD2<Float>(playerPos.y - s.anchor.y, playerPos.z - s.anchor.z)
        var v2 = SIMD2<Float>(playerVel.y, playerVel.z)

        // Gravity affects Y (p2.x)
        v2.x += -worldPhysicsConfig.gravity * dt
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
        playerPos.x = worldPhysicsConfig.centerX
        playerPos.y = s.anchor.y + p2.x
        playerPos.z = s.anchor.z + p2.y
        playerVel.y = v2.x
        playerVel.z = v2.y

        // 5) Update web every frame (sticks to player + anchor)
        webRenderer.updateWeb(from: playerPos, to: s.anchor)

        if hasMissedReleaseWindow(swingState: s) {
            print("[web] release window missed -> fail drop")
            releaseWeb(successful: false, swingState: s)
            return
        }

        // Persist updated rope length
        swing = s
    }

    private func handleFallingState(dt: Float) {
        // Free fall until hitting the ground
        playerVel.y += -worldPhysicsConfig.gravity * dt
        playerPos += playerVel * dt
        playerPos.x = worldPhysicsConfig.centerX

        if playerPos.y <= worldPhysicsConfig.groundY {
            playerPos.y = worldPhysicsConfig.groundY
            playerVel = .zero
            gameStateMachine.transition(to: .grounded)
        }
    }

    private func handleGroundedState() {
        // Grounded state (no movement yet)
        playerPos.x = worldPhysicsConfig.centerX
        playerPos.y = worldPhysicsConfig.groundY
    }

    private func applyFrameOutputs(realDeltaTime: Float) {
        // Apply transform to the entity
        player.position = playerPos
        updateCameraFollow()

        // Listener always follows the player
        audio.setListenerPosition(playerPos)
        updateReleaseCueIndicator()
        let guidance = audioGuidance(for: playerPos)
        updateTowerAudioSourcePositions()
        updateGuideAudioSource(playerPosition: playerPos, guidance: guidance)
        let nearestRow = audibleTowerRowIndex(to: playerPos)
        audioMixController.setNearestAudibleRowIndex(
            selectedAudibleRowIndex(nearestRowIndex: nearestRow, guidance: guidance)
        )
        audioMixController.updateMix(isFocusActive: focusActive, deltaTime: realDeltaTime)
    }

    private func audioGuidance(for playerPosition: SIMD3<Float>) -> AudioGuidance? {
        guard let targetRowIndex = guidedTargetRowIndex,
              let targetNode = towerTrack.node(at: targetRowIndex) else {
            return nil
        }

        if focusActive {
            return AudioGuidance(targetRowIndex: targetRowIndex, blend: 1.0)
        }

        let towerPosition = targetNode.tower.position(relativeTo: nil)
        let distanceToTarget = simd_distance(playerPosition, towerPosition)
        let denom = max(audioGuidanceConfig.assistTriggerDistance - audioGuidanceConfig.assistFullBlendDistance, 0.001)
        let rawBlend = (audioGuidanceConfig.assistTriggerDistance - distanceToTarget) / denom
        let blend = max(0.0, min(rawBlend, 1.0))
        if blend <= 0.0 {
            return nil
        }
        return AudioGuidance(targetRowIndex: targetRowIndex, blend: blend)
    }

    private func selectedAudibleRowIndex(nearestRowIndex: Int?, guidance: AudioGuidance?) -> Int? {
        if focusActive {
            return guidance?.targetRowIndex ?? nearestRowIndex
        }
        return nearestRowIndex
    }

    private func updateTowerAudioSourcePositions() {
        for (rowIndex, node) in towerTrack.nodes.enumerated() {
            guard let sourceID = audioMixController.sourceID(forRowIndex: rowIndex) else { continue }

            let towerPosition = node.tower.position(relativeTo: nil)
            let realPosition = exaggeratedAudioPosition(from: towerPosition)
            audio.setSourcePosition(sourceID: sourceID, position: realPosition)
        }
    }

    private func updateGuideAudioSource(playerPosition: SIMD3<Float>, guidance: AudioGuidance?) {
        guard let guidance,
              let targetNode = towerTrack.node(at: guidance.targetRowIndex) else {
            audioMixController.setGuideBlend(0.0)
            return
        }

        let towerPosition = targetNode.tower.position(relativeTo: nil)
        let guidePosition = assistedAudioPosition(
            for: targetNode.side,
            playerPosition: playerPosition,
            towerPosition: towerPosition,
            isFocusGuidance: focusActive
        )
        audioMixController.setGuideSourcePosition(guidePosition)
        audioMixController.setGuideBlend(guidance.blend)
    }

    private func exaggeratedAudioPosition(from worldPosition: SIMD3<Float>) -> SIMD3<Float> {
        let x = worldPhysicsConfig.centerX + (worldPosition.x - worldPhysicsConfig.centerX) * audioGuidanceConfig.horizontalExaggeration
        return SIMD3<Float>(x, worldPosition.y, worldPosition.z)
    }

    private func assistedAudioPosition(
        for side: TowerSide,
        playerPosition: SIMD3<Float>,
        towerPosition: SIMD3<Float>,
        isFocusGuidance: Bool
    ) -> SIMD3<Float> {
        let sideSign: Float = (side == .left) ? -1.0 : 1.0
        if isFocusGuidance {
        // Focus guide: emphasize left/right, but keep real tower depth so passing-by sensation remains.
        return SIMD3<Float>(
            playerPosition.x + sideSign * audioGuidanceConfig.focusLateralOffset,
            playerPosition.y + audioGuidanceConfig.focusHeightOffset,
            towerPosition.z
        )
        }

        return SIMD3<Float>(
            playerPosition.x + sideSign * audioGuidanceConfig.assistLateralOffset,
            towerPosition.y,
            playerPosition.z - audioGuidanceConfig.assistForwardOffset
        )
    }

    private func audibleTowerRowIndex(to position: SIMD3<Float>) -> Int? {
        guard !towerTrack.nodes.isEmpty else { return nil }

        var selectedRowIndex: Int?
        var selectedDistanceSquared = Float.greatestFiniteMagnitude

        for (rowIndex, node) in towerTrack.nodes.enumerated() {
            let towerPosition = node.tower.position(relativeTo: nil)
            let zDelta = towerPosition.z - position.z

            // Keep towers audible if they are in front, or only slightly behind the player.
            if zDelta > audioGuidanceConfig.rearTowerAudibleDistance {
                continue
            }

            let delta = towerPosition - position
            let distanceSquared = simd_length_squared(delta)
            if distanceSquared < selectedDistanceSquared {
                selectedDistanceSquared = distanceSquared
                selectedRowIndex = rowIndex
            }
        }

        if let selectedRowIndex {
            return selectedRowIndex
        }

        // Fallback: if all towers are filtered out, use absolute nearest.
        var nearestRowIndex = 0
        var nearestDistanceSquared = Float.greatestFiniteMagnitude
        for (rowIndex, node) in towerTrack.nodes.enumerated() {
            let delta = node.tower.position(relativeTo: nil) - position
            let distanceSquared = simd_length_squared(delta)
            if distanceSquared < nearestDistanceSquared {
                nearestDistanceSquared = distanceSquared
                nearestRowIndex = rowIndex
            }
        }
        return nearestRowIndex
    }

    private func restartGame() {
        print("[game] restart")

        // Reset core gameplay state
        swing = nil
        gameStateMachine.transition(to: .rooftop)
        playerPos = [worldPhysicsConfig.centerX, worldPhysicsConfig.rooftopY, worldPhysicsConfig.rooftopStartZ]
        playerVel = .zero

        // Reset progression / focus / guidance
        towerTrack.resetProgress()
        focusStateMachine.reset()
        expectedNextSide = nil
        guidedTargetRowIndex = nil

        // Reset presentation systems
        webRenderer.hideWeb()
        audioMixController.clearFocusTarget()
        audioMixController.resetToNormalMix()
        audio.restartAllLoopsFromBeginning()

        // Apply immediately so restart is visually/audio consistent in the same frame
        applyFrameOutputs(realDeltaTime: 1.0 / 60.0)
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
        guidedTargetRowIndex = nil
        audioMixController.clearFocusTarget()
        print("[focus] consumed by shot")
    }

    private func attemptRelease(_ side: TowerSide) {
        guard let swing else { return }
        guard gameStateMachine.state == .swinging else { return }
        guard swing.side == side else {
            print("[web] release ignored. swing side=\(swing.side), input=\(side)")
            return
        }

        let successful = isSuccessfulReleaseWindow(swingState: swing)
        if successful {
            print(String(format: "[web] good release y=%.2f z=%.2f vy=%.2f vz=%.2f",
                         playerPos.y, playerPos.z, playerVel.y, playerVel.z))
        } else {
            print(String(format: "[web] early/late release -> fail y=%.2f z=%.2f vy=%.2f vz=%.2f",
                         playerPos.y, playerPos.z, playerVel.y, playerVel.z))
        }
        releaseWeb(successful: successful, swingState: swing)
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

        let dx = worldPhysicsConfig.centerX - anchor.x
        let dy = playerPos.y - anchor.y
        let dz = playerPos.z - anchor.z
        let L2 = dx*dx + dy*dy + dz*dz
        let yz2 = max(L2 - dx*dx, 0.01)
        let measuredYZ = sqrt(yz2)

        // Keep lowest point above ground: lowest approx = anchor.y - ropeYZ
        let maxByClearance = max(anchor.y - (worldPhysicsConfig.groundY + swingPhysicsConfig.minClearanceY), swingPhysicsConfig.ropeMinYZ)
        let ropeMax = min(swingPhysicsConfig.ropeMaxHard, maxByClearance)

        // Target rope length (scaled + clamped)
        let ropeTargetYZ = min(max(measuredYZ * swingPhysicsConfig.ropeScale, swingPhysicsConfig.ropeMinYZ), ropeMax)

        // Current rope length starts at measuredYZ (keeps current position -> no teleport)
        let ropeCurrentYZ = measuredYZ

        swing = SwingState(anchor: anchor,
                           ropeLengthYZ: ropeCurrentYZ,
                           ropeTargetYZ: ropeTargetYZ,
                           towerZ: towerPos.z,
                           rowIndex: nextIndex,
                           side: side)

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

    private func isSuccessfulReleaseWindow(swingState: SwingState) -> Bool {
        let releaseStartZ = swingState.towerZ - swingPhysicsConfig.detachAfterPassing
        let releaseEndZ = releaseStartZ - releaseConfig.windowDepth
        let withinReleaseDepth = playerPos.z <= releaseStartZ && playerPos.z >= releaseEndZ
        let rising = playerVel.y > 0.4
        let highEnough = playerPos.y > (worldPhysicsConfig.groundY + swingPhysicsConfig.minClearanceY + 0.6)
        return withinReleaseDepth && rising && highEnough
    }

    private func hasMissedReleaseWindow(swingState: SwingState) -> Bool {
        let releaseStartZ = swingState.towerZ - swingPhysicsConfig.detachAfterPassing
        let releaseEndZ = releaseStartZ - releaseConfig.windowDepth
        let passedReleaseEnd = playerPos.z < releaseEndZ
        let passedStartAndDescending = (playerPos.z <= releaseStartZ) && (playerVel.y <= 0)
        return passedReleaseEnd || passedStartAndDescending
    }

    private func updateReleaseCueIndicator() {
        guard let swing, gameStateMachine.state == .swinging else {
            releaseCueIndicator.scale = .zero
            return
        }

        releaseCueIndicator.position = playerPos + SIMD3<Float>(0, releaseConfig.cueHeight, 0)
        releaseCueIndicator.scale = SIMD3<Float>(repeating: 1.0)
        let cueColor: NSColor = isSuccessfulReleaseWindow(swingState: swing) ? .systemGreen : .systemYellow
        releaseCueIndicator.model?.materials = [UnlitMaterial(color: cueColor)]
    }

    private func releaseWeb(successful: Bool, swingState: SwingState) {
        let passedRow = swingState.rowIndex

        if successful {
            // Keep successful releases readable: prevent excessive upward launch when releasing late.
            playerVel.y = min(playerVel.y, releaseConfig.upwardVelocityCap)
        }

        swing = nil
        webRenderer.hideWeb()
        gameStateMachine.transition(to: .falling)
        audioMixController.fadeOutTowerRow(passedRow, duration: 0.5)

        if successful {
            focusStateMachine.scheduleAfterDelay()
            let nextIndex = passedRow + 1
            if let nextSide = towerTrack.side(at: nextIndex) {
                expectedNextSide = nextSide
                guidedTargetRowIndex = nextIndex
                audioMixController.setFocusTargetRowIndex(nextIndex)
                print("[focus] will start after delay. next side should be \(expectedNextSide!)")
            } else {
                expectedNextSide = nil
                guidedTargetRowIndex = nil
                audioMixController.clearFocusTarget()
                print("[focus] will start after delay (no next tower)")
            }
            return
        }

        focusStateMachine.reset()
        expectedNextSide = nil
        guidedTargetRowIndex = nil
        audioMixController.clearFocusTarget()
    }

    // MARK: Camera

    private func updateCameraFollow() {
        // Offset behind & above player (forward is -Z, so "behind" is +Z).
        // At high altitude, pull camera farther back and aim lower to keep ground references visible.
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
        updateVisibilityMaskRadius(cameraPosition: camPos)
    }

    private func updateVisibilityMaskRadius(cameraPosition: SIMD3<Float>) {
        let cameraToPlayerDistance = simd_distance(cameraPosition, playerPos)
        let maskRadius = max(
            cameraFollowConfig.visibilityMinDistance,
            cameraToPlayerDistance + cameraFollowConfig.visibilityExtraDistance
        )

        // Flip winding with negative X scale so the inner surface renders from inside the sphere.
        visibilityMaskSphere.scale = [-maskRadius, maskRadius, maskRadius]
    }

    // MARK: Ground

    private func makeGroundEntity() -> ModelEntity {
        // Ground size: wide enough for lanes; deep enough to cover the farthest tower row
        let width: Float = max(10, abs(towerLayoutConfig.leftX) + abs(towerLayoutConfig.rightX) + 6)
        let depth: Float = Float(towerLayoutConfig.rowCount + 3) * towerLayoutConfig.rowSpacing + 8

        let mesh = MeshResource.generateBox(size: [width, groundThickness, depth])
        let mat = SimpleMaterial(color: .darkGray, isMetallic: false)
        let ground = ModelEntity(mesh: mesh, materials: [mat])

        // Place so the top surface is at y=0, extending from z=0 forward into negative Z
        ground.position = [0, -groundThickness * 0.5, -depth * 0.5]
        return ground
    }

    private func addStreetReferenceProps() {
        let roadWidth: Float = max(10, abs(towerLayoutConfig.leftX) + abs(towerLayoutConfig.rightX) + 6)
        let roadDepth: Float = Float(towerLayoutConfig.rowCount + 3) * towerLayoutConfig.rowSpacing + 8
        let lineY: Float = 0.01

        let edgeLineMat = SimpleMaterial(color: .white, isMetallic: false)
        let centerLineMat = SimpleMaterial(color: .yellow, isMetallic: false)

        // Left and right solid lane boundary lines.
        let edgeLineSize = SIMD3<Float>(0.10, 0.005, roadDepth)
        let leftEdgeLine = ModelEntity(mesh: .generateBox(size: edgeLineSize), materials: [edgeLineMat])
        leftEdgeLine.position = [-(roadWidth * 0.5) + 0.5, lineY, -roadDepth * 0.5]
        world.addChild(leftEdgeLine)

        let rightEdgeLine = ModelEntity(mesh: .generateBox(size: edgeLineSize), materials: [edgeLineMat])
        rightEdgeLine.position = [(roadWidth * 0.5) - 0.5, lineY, -roadDepth * 0.5]
        world.addChild(rightEdgeLine)

        // Dashed center line to provide strong speed reference.
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

        // Simple parked-car blocks as nearby scale references.
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

