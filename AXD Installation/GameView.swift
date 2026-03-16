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
    var onSceneRequest: ((AppScene) -> Void)? = nil

    func makeNSView(context: Context) -> GameARView {
        GameARView(
            frame: .zero,
            focusTiming: focusTiming,
            towerLayout: towerLayout,
            swingPhysics: swingPhysics,
            onSceneRequest: onSceneRequest
        )
    }
    func updateNSView(_ nsView: GameARView, context: Context) {}
}

// MARK: - RealityKit View (macOS desktop, non-AR)

final class GameARView: ARView {
    private enum ReleaseCueAudioPhase: Equatable {
        case idle
        case silencingBeforeGreen
        case waitingAfterGreen(elapsed: Float)
        case leadingNextTower(rowIndex: Int)
    }

    // MARK: Configuration

    private let worldPhysicsConfig: WorldPhysicsConfig = .default
    private let swingPhysicsConfig: SwingPhysicsConfig
    private let towerLayoutConfig: TowerLayoutConfig
    private let towerTrack: TowerTrack
    private let focusStateMachine: FocusStateMachine
    private let releaseConfig: ReleaseConfig = .default
    private let releaseCueAudioConfig: ReleaseCueAudioConfig = .default
    private let launchSequenceConfig: LaunchSequenceConfig = .default
    private let cameraFollowConfig: CameraFollowConfig = .default
    private let audioGuidanceConfig: AudioGuidanceConfig = .default
    private let debugConfig: DebugConfig = .default

    private let rearTowerAudibleDistance: Float = 6.0
    private let failedWebShotForwardDistance: Float = 7.0
    private let failedWebShotLateralDistance: Float = 2.6
    private let failedWebShotVerticalOffset: Float = 0.6
    private let groundThickness: Float = 0.05

    private var focusActive: Bool { focusStateMachine.isActive }
    private var expectedNextSide: TowerSide? = nil
    private var guidedTargetRowIndex: Int? = nil

    // MARK: Scene entities (RealityKit graph)

    private var updateSub: Cancellable?
    private let sceneEntities: GameSceneEntities

    private var world: AnchorEntity { sceneEntities.world }
    private var player: ModelEntity { sceneEntities.player }
    private var camera: PerspectiveCamera { sceneEntities.camera }
    private var cameraAnchor: AnchorEntity { sceneEntities.cameraAnchor }
    private var visibilityMaskSphere: ModelEntity { sceneEntities.visibilityMaskSphere }
    private var releaseCueIndicator: ModelEntity { sceneEntities.releaseCueIndicator }
    private var guideDebugSphere: ModelEntity { sceneEntities.guideDebugSphere }
    private var guideTowerDebugSphere: ModelEntity { sceneEntities.guideTowerDebugSphere }
    private var startTowerEntity: ModelEntity { sceneEntities.startTowerEntity }
    private var leftLaunchPegEntity: ModelEntity { sceneEntities.leftLaunchPegEntity }
    private var rightLaunchPegEntity: ModelEntity { sceneEntities.rightLaunchPegEntity }
    private var leftLaunchPegSupport: ModelEntity { sceneEntities.leftLaunchPegSupport }
    private var rightLaunchPegSupport: ModelEntity { sceneEntities.rightLaunchPegSupport }
    private var leftLaunchPegBase: ModelEntity { sceneEntities.leftLaunchPegBase }
    private var rightLaunchPegBase: ModelEntity { sceneEntities.rightLaunchPegBase }
    private let towerPrototype: ModelEntity

    private let audio: SpatialAudioRig
    private let audioMixController: TowerAudioMixController
    private let gameStateMachine = GameStateMachine()
    private let webRenderer: WebRenderer
    private let onSceneRequest: ((AppScene) -> Void)?

    // MARK: Runtime state

    private var playerPos: SIMD3<Float> = [0, 4.0, -14.0]
    private var playerVel: SIMD3<Float> = .zero

    private var swing: SwingState? = nil
    private var launchPrepTransition: Float = 0.0
    private var isFocusPendingFromLaunchArc: Bool = false
    private var isTowerAudioEnabled: Bool = false
    private var releaseWindowAudioPhase: ReleaseCueAudioPhase = .idle

    private var launchPrepLeftConnected: Bool = false
    private var launchPrepRightConnected: Bool = false
    private var launchPrepCharging: Bool = false
    private var launchPrepChargeElapsed: Float = 0.0
    private var launchPrepReleaseLeftArmed: Bool = false
    private var launchPrepReleaseRightArmed: Bool = false
    private var pendingChordReleaseSide: TowerSide? = nil
    private var pendingChordReleaseElapsed: Float = 0.0

    // MARK: Init

    init(
        frame frameRect: CGRect,
        focusTiming: FocusTimingConfig = .default,
        towerLayout: TowerLayoutConfig = .default,
        swingPhysics: SwingPhysicsConfig = .default,
        onSceneRequest: ((AppScene) -> Void)? = nil
    ) {
        self.swingPhysicsConfig = swingPhysics
        self.towerLayoutConfig = towerLayout
        self.towerTrack = TowerTrack(layout: towerLayout)
        self.focusStateMachine = FocusStateMachine(timing: focusTiming)
        self.sceneEntities = GameSceneEntities()
        self.towerPrototype = GameSceneEntities.makeTowerPrototype(towerHeight: towerLayout.towerHeight)
        self.audio = SpatialAudioRig()
        self.audioMixController = TowerAudioMixController(audio: audio)
        self.webRenderer = WebRenderer(world: sceneEntities.world)
        self.onSceneRequest = onSceneRequest
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
        self.sceneEntities = GameSceneEntities()
        self.towerPrototype = GameSceneEntities.makeTowerPrototype(towerHeight: TowerLayoutConfig.default.towerHeight)
        self.audio = SpatialAudioRig()
        self.audioMixController = TowerAudioMixController(audio: audio)
        self.webRenderer = WebRenderer(world: sceneEntities.world)
        self.onSceneRequest = nil
        super.init(frame: frameRect)
        setupScene()
        setupUpdateLoop()

        audio.start()
    }

    @MainActor required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Keyboard focus & events

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        print("[focus] firstResponder =", String(describing: window?.firstResponder))
    }

    override func keyDown(with event: NSEvent) {
        if event.isARepeat { return }

        let c = (event.charactersIgnoringModifiers ?? "").lowercased()
        if c == "a" { onSceneRequest?(.game); return }
        if c == "s" { onSceneRequest?(.tutorialPart1); return }
        if c == "d" { onSceneRequest?(.tutorialPart2); return }

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

        playerPos = startPlayerPosition()
        player.position = playerPos
        playerVel = .zero
        gameStateMachine.transition(to: .rooftop)
        world.addChild(player)
        world.addChild(releaseCueIndicator)
        world.addChild(guideDebugSphere)
        world.addChild(guideTowerDebugSphere)
        setupLaunchPlatform()

        towerTrack.rebuild(in: world, prototype: towerPrototype)
        setTowerVisibility(false)

        audio.configureGeneratedTowerBaseLoop()
//        _ = audio.configureBackgroundLoop(fileName: "background_music", fileExt: "wav")
        _ = audio.configureBackgroundLoop(fileName: "background", fileExt: "mp3")

        for node in towerTrack.nodes {
            let sourceID = audio.addLoopingSource(at: node.tower.position(relativeTo: nil))
            audioMixController.registerTowerSource(sourceID)
        }
        let guideSourceID = audio.addLoopingSource(at: player.position(relativeTo: nil))
        audioMixController.registerGuideSource(guideSourceID)

        audio.start()
        audioMixController.resetToNormalMix()
        audio.setListenerPosition(player.position(relativeTo: nil))

        let light = DirectionalLight()
        light.light.intensity = 2000
        light.look(at: .zero, from: [1, 2, 2], relativeTo: nil)
        world.addChild(light)

        camera.camera.fieldOfViewInDegrees = 60
        camera.camera.near = 0.05
        camera.camera.far = 500
        camera.position = .zero

        visibilityMaskSphere.position = .zero
        cameraAnchor.addChild(visibilityMaskSphere)
        cameraAnchor.addChild(camera)
        scene.addAnchor(cameraAnchor)
    }

    // MARK: Update loop (per frame)

    private func setupUpdateLoop() {
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
        updateLaunchPrepTransition(dt: dt)
        switch gameStateMachine.state {
        case .rooftop:
            handleRooftopState(dt: dt)
        case .swinging:
            handleSwingingState(dt: dt)
        case .falling:
            handleFallingState(dt: dt)
        case .grounded:
            handleGroundedState()
        }
    }

    private func handleRooftopState(dt: Float) {
        // Standing on launch tower while preparing the first launch.
        let base = startPlayerPosition()
        playerPos = base
        playerVel = .zero

        if launchPrepCharging {
            launchPrepChargeElapsed += dt
        }
        let blend = launchChargeBlendFactor()
        playerPos.z += launchSequenceConfig.chargePlayerBackOffset * blend

        if let pendingSide = pendingChordReleaseSide {
            pendingChordReleaseElapsed += dt
            if pendingChordReleaseElapsed > launchSequenceConfig.releaseChordWindow {
                pendingChordReleaseSide = nil
                pendingChordReleaseElapsed = 0.0
                breakLaunchPrepConnection(for: pendingSide)
            }
        }
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
        updateReleaseCueAudioTransition(swingState: s, dt: dt)

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

        if isFocusPendingFromLaunchArc,
           playerVel.y <= 0,
           playerPos.y <= launchSequenceConfig.focusTriggerHeight {
            isFocusPendingFromLaunchArc = false
            if gameStateMachine.isGrounded {
                gameStateMachine.transition(to: .falling)
            }
            scheduleFocusForNextTower(afterRowIndex: -1, activateImmediately: true)
        }

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
        updateCameraFollow(deltaTime: realDeltaTime)
        webRenderer.tick(deltaTime: realDeltaTime)
        updateLaunchPrepWebs()

        // Listener always follows the player
        audio.setListenerPosition(playerPos)
        updateReleaseCueIndicator()
        let guidance = isTowerAudioEnabled ? audioGuidance() : nil
        updateTowerAudioSourcePositions()
        updateGuideAudioSource(guidance: guidance)
        let nearestRow = isTowerAudioEnabled ? audibleTowerRowIndex(to: playerPos) : nil
        audioMixController.setNearestAudibleRowIndex(
            selectedAudibleRowIndex(nearestRowIndex: nearestRow, guidance: guidance)
        )
        audioMixController.updateMix(isFocusActive: focusActive, deltaTime: realDeltaTime)
    }

    private func audioGuidance() -> AudioGuidance? {
        guard let targetRowIndex = guidedTargetRowIndex,
              towerTrack.node(at: targetRowIndex) != nil else {
            return nil
        }

        if focusActive {
            return AudioGuidance(targetRowIndex: targetRowIndex, blend: 1.0)
        }
        return nil
    }

    private func selectedAudibleRowIndex(nearestRowIndex: Int?, guidance: AudioGuidance?) -> Int? {
        switch releaseWindowAudioPhase {
        case .silencingBeforeGreen, .waitingAfterGreen:
            return nil
        case .leadingNextTower(let rowIndex):
            return rowIndex
        case .idle:
            break
        }
        if focusActive {
            return guidance?.targetRowIndex ?? nearestRowIndex
        }
        return nearestRowIndex
    }

    private func updateTowerAudioSourcePositions() {
        for (rowIndex, node) in towerTrack.nodes.enumerated() {
            guard let sourceID = audioMixController.sourceID(forRowIndex: rowIndex) else { continue }

            let towerPosition = node.tower.position(relativeTo: nil)
            audio.setSourcePosition(sourceID: sourceID, position: towerPosition)
        }
    }

    private func updateGuideAudioSource(guidance: AudioGuidance?) {
        guard let guidance,
              let targetNode = towerTrack.node(at: guidance.targetRowIndex) else {
            audioMixController.setGuideBlend(0.0)
            setGuideDebugSpheresVisible(false)
            return
        }

        let towerPosition = targetNode.tower.position(relativeTo: nil)
        let guidePosition = guidedAudioPosition(for: towerPosition)
        audioMixController.setGuideSourcePosition(guidePosition)
        audioMixController.setGuideBlend(guidance.blend)
        updateGuideDebugSphere(position: guidePosition)
    }

    private func guidedAudioPosition(for towerPosition: SIMD3<Float>) -> SIMD3<Float> {
        guard audioGuidanceConfig.isGuidePositionOffsetEnabled else {
            return towerPosition
        }

        let deltaXZ = SIMD2<Float>(towerPosition.x - playerPos.x, towerPosition.z - playerPos.z)
        let distance = max(simd_length(deltaXZ), 0.001)

        let maxDistance = max(audioGuidanceConfig.maxDistanceMeters, audioGuidanceConfig.minDistanceMeters + 0.01)
        let normalizedDistance = (distance - audioGuidanceConfig.minDistanceMeters) / (maxDistance - audioGuidanceConfig.minDistanceMeters)
        let distanceBlend = min(max(normalizedDistance, 0.0), 1.0)
        // Curve the response so lateral cue stays obvious longer, while depth pull-in is gentler.
        let lateralBlend = 1.0 - pow(1.0 - distanceBlend, 2.2)
        let depthBlend = pow(distanceBlend, 1.35)
        let lateralScale = 1.0 + (audioGuidanceConfig.xScaleAtMaxDistance - 1.0) * lateralBlend
        let depthScale = 1.0 - (1.0 - audioGuidanceConfig.zScaleAtMaxDistance) * depthBlend

        return SIMD3<Float>(
            playerPos.x + (towerPosition.x - playerPos.x) * lateralScale,
            towerPosition.y,
            playerPos.z + (towerPosition.z - playerPos.z) * depthScale
        )
    }

    private func updateGuideDebugSphere(position: SIMD3<Float>) {
        let isVisible = focusActive && debugConfig.showGuideDebugSpheres
        setGuideDebugSpheresVisible(isVisible)
        guard isVisible else { return }
        guideDebugSphere.position = visibleDebugGuidePosition(for: position)
        if let guidedTargetRowIndex,
           let targetNode = towerTrack.node(at: guidedTargetRowIndex) {
            let towerPosition = targetNode.tower.position(relativeTo: nil)
            guideTowerDebugSphere.position = visibleDebugGuidePosition(for: towerPosition)
        }
    }

    private func setGuideDebugSpheresVisible(_ visible: Bool) {
        guideDebugSphere.scale = visible ? SIMD3<Float>(repeating: 1.0) : .zero
        guideTowerDebugSphere.scale = visible ? SIMD3<Float>(repeating: 1.0) : .zero
    }

    private func visibleDebugGuidePosition(for guideWorldPosition: SIMD3<Float>) -> SIMD3<Float> {
        let cameraPosition = cameraAnchor.position(relativeTo: nil)
        let cameraToPlayerDistance = simd_distance(cameraPosition, playerPos)
        let maskRadius = max(
            cameraFollowConfig.visibilityMinDistance,
            cameraToPlayerDistance + cameraFollowConfig.visibilityExtraDistance
        )
        let maxVisibleDistance = max(maskRadius - 0.25, 0.5)

        let delta = guideWorldPosition - cameraPosition
        let distance = simd_length(delta)
        guard distance > maxVisibleDistance, distance > 0.001 else {
            return guideWorldPosition
        }

        let direction = delta / distance
        return cameraPosition + direction * maxVisibleDistance
    }

    private func audibleTowerRowIndex(to position: SIMD3<Float>) -> Int? {
        guard !towerTrack.nodes.isEmpty else { return nil }

        var selectedRowIndex: Int?
        var selectedDistanceSquared = Float.greatestFiniteMagnitude

        for (rowIndex, node) in towerTrack.nodes.enumerated() {
            let towerPosition = node.tower.position(relativeTo: nil)
            let zDelta = towerPosition.z - position.z

            // Keep towers audible if they are in front, or only slightly behind the player.
            if zDelta > rearTowerAudibleDistance {
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
        resetLaunchPrepState()
        isFocusPendingFromLaunchArc = false
        isTowerAudioEnabled = false
        launchPrepTransition = 0.0
        setTowerVisibility(false)
        gameStateMachine.transition(to: .rooftop)
        playerPos = startPlayerPosition()
        playerVel = .zero
        resetReleaseCueAudioTransitionState()

        // Reset progression / focus / guidance
        towerTrack.resetProgress()
        focusStateMachine.reset()
        expectedNextSide = nil
        guidedTargetRowIndex = nil

        // Reset presentation systems
        webRenderer.hideWeb()
        webRenderer.hideAllPrepWebs()
        audioMixController.clearFocusTarget()
        audioMixController.resetToNormalMix()
        audio.restartAllLoopsFromBeginning()

        // Apply immediately so restart is visually/audio consistent in the same frame
        applyFrameOutputs(realDeltaTime: 1.0 / 60.0)
    }

    // MARK: Input gating (Q/E -> attemptShoot -> shootWeb)

    private func attemptShoot(_ side: TowerSide) {
        // 1) Block shooting while grounded (prevents underground swinging)
        if gameStateMachine.isGrounded && !focusActive {
            print("[shoot] blocked (grounded/dead)")
            return
        }

        // 2) Launch prep on rooftop
        if gameStateMachine.isRooftop {
            handleLaunchPrepShoot(side)
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
            fireFailedWebShot(to: side)
            return
        }

        // Consume focus immediately on a successful shot (return to normal time)
        shootWeb(to: side, preferredRowIndex: guidedTargetRowIndex)
        focusStateMachine.reset()
        expectedNextSide = nil
        guidedTargetRowIndex = nil
        audioMixController.clearFocusTarget()
        print("[focus] consumed by shot")
    }

    private func attemptRelease(_ side: TowerSide) {
        if gameStateMachine.isRooftop {
            handleLaunchPrepRelease(side)
            return
        }

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

    private func handleLaunchPrepShoot(_ side: TowerSide) {
        guard !launchPrepCharging else { return }
        switch side {
        case .left:
            launchPrepLeftConnected = true
        case .right:
            launchPrepRightConnected = true
        }
        armLaunchChargeIfReady()
    }

    private func handleLaunchPrepRelease(_ side: TowerSide) {
        guard gameStateMachine.isRooftop else { return }

        if launchPrepCharging {
            let chargeReady = launchPrepChargeElapsed >= launchSequenceConfig.chargeMinDuration
            if !chargeReady {
                breakLaunchPrepConnection(for: side)
                return
            }

            if let pendingSide = pendingChordReleaseSide {
                if pendingSide != side && pendingChordReleaseElapsed <= launchSequenceConfig.releaseChordWindow {
                    launchPrepReleaseLeftArmed = true
                    launchPrepReleaseRightArmed = true
                    pendingChordReleaseSide = nil
                    pendingChordReleaseElapsed = 0.0
                    launchFromPrepIfReady()
                    return
                }
                return
            }

            pendingChordReleaseSide = side
            pendingChordReleaseElapsed = 0.0
            return
        }

        // Not charging yet: pressing release breaks whichever line is currently attached.
        breakLaunchPrepConnection(for: side)
    }

    private func armLaunchChargeIfReady() {
        guard launchPrepLeftConnected, launchPrepRightConnected else { return }
        launchPrepCharging = true
        launchPrepChargeElapsed = 0.0
        launchPrepReleaseLeftArmed = false
        launchPrepReleaseRightArmed = false
        print("[launch] charge started")
    }

    private func breakLaunchPrepConnection(for side: TowerSide) {
        switch side {
        case .left:
            launchPrepLeftConnected = false
            launchPrepReleaseLeftArmed = false
        case .right:
            launchPrepRightConnected = false
            launchPrepReleaseRightArmed = false
        }
        launchPrepCharging = false
        launchPrepChargeElapsed = 0.0
        pendingChordReleaseSide = nil
        pendingChordReleaseElapsed = 0.0
        webRenderer.hidePrepWeb(side: side)
        print("[launch] \(side) preload web released")
    }

    private func launchFromPrepIfReady() {
        guard launchPrepLeftConnected, launchPrepRightConnected else { return }
        guard launchPrepReleaseLeftArmed, launchPrepReleaseRightArmed else { return }

        let speed = launchSequenceConfig.launchSpeed
        let angle = launchSequenceConfig.launchAngleDegrees * (.pi / 180.0)
        playerVel = SIMD3<Float>(
            0,
            sin(angle) * speed,
            -cos(angle) * speed
        )

        resetLaunchPrepState()
        webRenderer.hideAllPrepWebs()
        isTowerAudioEnabled = true
        setTowerVisibility(true)
        isFocusPendingFromLaunchArc = true
        gameStateMachine.transition(to: .falling)
        print("[launch] released with speed=\(speed)")
    }

    private func resetLaunchPrepState() {
        launchPrepLeftConnected = false
        launchPrepRightConnected = false
        launchPrepCharging = false
        launchPrepChargeElapsed = 0.0
        launchPrepReleaseLeftArmed = false
        launchPrepReleaseRightArmed = false
        pendingChordReleaseSide = nil
        pendingChordReleaseElapsed = 0.0
    }

    private func scheduleFocusForNextTower(afterRowIndex rowIndex: Int, activateImmediately: Bool = false) {
        if activateImmediately {
            focusStateMachine.activateNow()
        } else {
            focusStateMachine.scheduleAfterDelay()
        }
        let nextIndex = rowIndex + 1
        if let nextSide = towerTrack.side(at: nextIndex) {
            expectedNextSide = nextSide
            guidedTargetRowIndex = nextIndex
            audioMixController.setFocusTargetRowIndex(nextIndex)
            print("[focus] will start after delay. next side should be \(nextSide)")
        } else {
            expectedNextSide = nil
            guidedTargetRowIndex = nil
            audioMixController.clearFocusTarget()
            print("[focus] will start after delay (no next tower)")
        }
    }

    private func shootWeb(to side: TowerSide, preferredRowIndex: Int? = nil) {
        let nextIndex = preferredRowIndex ?? towerTrack.nextIndex(fromSwingRow: swing?.rowIndex)
        guard let node = towerTrack.node(at: nextIndex) else {
            print("[web] no next tower")
            return
        }
        guard node.side == side else {
            print("[web] wrong side. next is \(node.side), you pressed \(side)")
            fireFailedWebShot(to: side)
            return
        }

        let tower = node.tower
        let towerPos = tower.position(relativeTo: nil)
        resetReleaseCueAudioTransitionState()

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

        let ropeTargetYZ = min(max(measuredYZ * swingPhysicsConfig.ropeScale, swingPhysicsConfig.ropeMinYZ), ropeMax)
        let ropeCurrentYZ = measuredYZ

        swing = SwingState(anchor: anchor,
                           ropeLengthYZ: ropeCurrentYZ,
                           ropeTargetYZ: ropeTargetYZ,
                           towerZ: towerPos.z,
                           rowIndex: nextIndex,
                           side: side)
        if let sourceID = audioMixController.sourceID(forRowIndex: nextIndex) {
            audio.setSourceToneVariant(sourceID: sourceID, variant: .muffled)
        }

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

        // Normalize swing entry speed so first swing (after launch) matches later swings.
        playerVel.y = tangent.x * swingPhysicsConfig.initialSwingSpeed
        playerVel.z = tangent.y * swingPhysicsConfig.initialSwingSpeed

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

    private func updateReleaseCueAudioTransition(swingState: SwingState, dt: Float) {
        let releaseStartZ = swingState.towerZ - swingPhysicsConfig.detachAfterPassing
        let zDistanceToGreen = max(playerPos.z - releaseStartZ, 0.0)
        let forwardSpeedTowardGreen = max(-playerVel.z, 0.0)
        let timeToGreen = zDistanceToGreen / max(forwardSpeedTowardGreen, 0.001)
        let inYellowPhaseBeforeGreen = playerPos.z > releaseStartZ
        let shouldStartFadeOut = inYellowPhaseBeforeGreen
            && timeToGreen <= releaseCueAudioConfig.fadeOutLeadTimeBeforeGreenSeconds

        if shouldStartFadeOut && releaseWindowAudioPhase == .idle {
            releaseWindowAudioPhase = .silencingBeforeGreen
            audioMixController.fadeOutTowerRow(
                swingState.rowIndex,
                duration: releaseCueAudioConfig.fadeOutDurationSeconds,
                startLevel: releaseCueAudioConfig.fadeOutInitialLevel
            )
        }

        guard isSuccessfulReleaseWindow(swingState: swingState) else {
            if case .waitingAfterGreen = releaseWindowAudioPhase {
                releaseWindowAudioPhase = .silencingBeforeGreen
            }
            return
        }

        let updatedElapsed: Float
        switch releaseWindowAudioPhase {
        case .waitingAfterGreen(let elapsed):
            updatedElapsed = elapsed + max(dt, 0)
        case .leadingNextTower:
            return
        default:
            updatedElapsed = max(dt, 0)
        }

        guard updatedElapsed >= releaseCueAudioConfig.towerFadeInDelayAfterGreenSeconds else {
            releaseWindowAudioPhase = .waitingAfterGreen(elapsed: updatedElapsed)
            return
        }

        let nextRowIndex = swingState.rowIndex + 1
        if towerTrack.node(at: nextRowIndex) != nil {
            releaseWindowAudioPhase = .leadingNextTower(rowIndex: nextRowIndex)
        } else {
            releaseWindowAudioPhase = .waitingAfterGreen(elapsed: updatedElapsed)
        }
    }

    private func resetReleaseCueAudioTransitionState() {
        releaseWindowAudioPhase = .idle
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
            playerVel.y = min(playerVel.y, releaseConfig.upwardVelocityCap)
        }

        swing = nil
        webRenderer.hideWeb()
        gameStateMachine.transition(to: .falling)
        audioMixController.fadeOutTowerRow(passedRow, duration: 0.6, startLevel: 0.16)

        if successful {
            scheduleFocusForNextTower(afterRowIndex: passedRow)
            return
        }

        resetReleaseCueAudioTransitionState()
        focusStateMachine.reset()
        expectedNextSide = nil
        guidedTargetRowIndex = nil
        audioMixController.clearFocusTarget()
    }

    private func fireFailedWebShot(to side: TowerSide) {
        let sideSign: Float = (side == .left) ? -1.0 : 1.0
        let start = playerPos + SIMD3<Float>(0, 0.2, 0)
        let end = start + SIMD3<Float>(
            sideSign * failedWebShotLateralDistance,
            failedWebShotVerticalOffset,
            -failedWebShotForwardDistance
        )
        webRenderer.triggerFailedShot(from: start, to: end)
    }

    private func launchChargeBlendFactor() -> Float {
        let t = min(max(launchPrepTransition, 0.0), 1.0)
        return t * t * (3.0 - 2.0 * t)
    }

    private func updateLaunchPrepTransition(dt: Float) {
        guard dt > 0 else { return }
        let target: Float = launchPrepCharging ? 1.0 : 0.0
        let speed = dt / max(launchSequenceConfig.chargeMinDuration, 0.001)
        if launchPrepTransition < target {
            launchPrepTransition = min(launchPrepTransition + speed, target)
        } else {
            launchPrepTransition = max(launchPrepTransition - speed, target)
        }
    }

    private func startPlayerPosition() -> SIMD3<Float> {
        SceneGeometryHelper.startPlayerPosition(
            centerX: worldPhysicsConfig.centerX,
            groundY: worldPhysicsConfig.groundY,
            rooftopStartZ: worldPhysicsConfig.rooftopStartZ,
            startTowerHeight: launchSequenceConfig.startTowerHeight
        )
    }

    private func launchPegPosition(for side: TowerSide) -> SIMD3<Float> {
        let sideSign: Float = (side == .left) ? -1.0 : 1.0
        let base = startPlayerPosition()
        return SIMD3<Float>(
            base.x + sideSign * launchSequenceConfig.pegLateralOffset,
            base.y + launchSequenceConfig.pegHeightOffset,
            base.z - launchSequenceConfig.pegForwardOffset
        )
    }

    private func setupLaunchPlatform() {
        let groundTopY = worldPhysicsConfig.groundY
        startTowerEntity.position = [
            worldPhysicsConfig.centerX,
            worldPhysicsConfig.groundY + launchSequenceConfig.startTowerHeight * 0.5,
            worldPhysicsConfig.rooftopStartZ
        ]
        startTowerEntity.scale = [
            1.0,
            launchSequenceConfig.startTowerHeight / 4.0,
            1.0
        ]
        world.addChild(startTowerEntity)

        let leftPegPosition = launchPegPosition(for: .left)
        let rightPegPosition = launchPegPosition(for: .right)
        leftLaunchPegEntity.position = leftPegPosition
        rightLaunchPegEntity.position = rightPegPosition
        leftLaunchPegEntity.scale = [1.0, 1.0, 1.0]
        rightLaunchPegEntity.scale = [1.0, 1.0, 1.0]
        world.addChild(leftLaunchPegEntity)
        world.addChild(rightLaunchPegEntity)

        let supportHeightLeft = max(leftPegPosition.y - groundTopY, 0.2)
        leftLaunchPegSupport.scale = [1.0, supportHeightLeft, 1.0]
        leftLaunchPegSupport.position = [leftPegPosition.x, groundTopY + supportHeightLeft * 0.5, leftPegPosition.z]
        world.addChild(leftLaunchPegSupport)

        let supportHeightRight = max(rightPegPosition.y - groundTopY, 0.2)
        rightLaunchPegSupport.scale = [1.0, supportHeightRight, 1.0]
        rightLaunchPegSupport.position = [rightPegPosition.x, groundTopY + supportHeightRight * 0.5, rightPegPosition.z]
        world.addChild(rightLaunchPegSupport)

        leftLaunchPegBase.position = [leftPegPosition.x, groundTopY + 0.07, leftPegPosition.z]
        rightLaunchPegBase.position = [rightPegPosition.x, groundTopY + 0.07, rightPegPosition.z]
        world.addChild(leftLaunchPegBase)
        world.addChild(rightLaunchPegBase)
    }

    private func updateLaunchPrepWebs() {
        guard gameStateMachine.isRooftop else {
            webRenderer.hideAllPrepWebs()
            return
        }

        let webStart = playerPos
        if launchPrepLeftConnected {
            webRenderer.updatePrepWeb(side: .left, from: webStart, to: leftLaunchPegEntity.position(relativeTo: nil))
        } else {
            webRenderer.hidePrepWeb(side: .left)
        }

        if launchPrepRightConnected {
            webRenderer.updatePrepWeb(side: .right, from: webStart, to: rightLaunchPegEntity.position(relativeTo: nil))
        } else {
            webRenderer.hidePrepWeb(side: .right)
        }
    }

    private func setTowerVisibility(_ isVisible: Bool) {
        for node in towerTrack.nodes {
            node.tower.isEnabled = isVisible
        }
    }

    // MARK: Camera

    private func updateCameraFollow(deltaTime _: Float) {
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
        let launchChargeBlend = launchChargeBlendFactor()
        let launchChargeOffset = SIMD3<Float>(0, 0, launchSequenceConfig.chargeCameraBackOffset * launchChargeBlend)

        let target = playerPos + SIMD3<Float>(0, -lookDownBias, 0)
        let camPos = target + offset + launchChargeOffset

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
