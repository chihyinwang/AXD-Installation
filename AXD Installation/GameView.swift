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

    func makeNSView(context: Context) -> GameARView {
        GameARView(frame: .zero, focusTiming: focusTiming)
    }
    func updateNSView(_ nsView: GameARView, context: Context) {}
}

// MARK: - RealityKit View (macOS desktop, non-AR)

final class GameARView: ARView {

    // MARK: Types

    private enum PlayerMode { case rooftop, swinging, falling, grounded }
    private enum Side { case left, right }

    private struct SwingState {
        let anchor: SIMD3<Float>
        var ropeLengthYZ: Float       // Current rope length in the YZ plane (changes per frame via reel-in)
        let ropeTargetYZ: Float       // Target rope length in the YZ plane (computed once on attach)
        let towerZ: Float
        let rowIndex: Int
    }

    private struct AutoMove {
        var start: SIMD3<Float>
        var end: SIMD3<Float>
        var elapsed: Float
        var duration: Float
    }

    // MARK: Configuration (tuning knobs)

    // Core world / physics
    private let centerX: Float = 0
    private let groundY: Float = 0.12
    private let rooftopY: Float = 7.0
    private let rooftopStartZ: Float = -14.0
    private let gravity: Float = 9.8

    // Swing behavior
    private let detachAfterPassing: Float = 3.0
    private let initialSwingSpeed: Float = 7.0

    // Focus ("五感世界") timing
    private let focusTiming: FocusTimingConfig

    // Web attach & rope constraints
    private let webAttachExtraHeight: Float = 1.8

    private let ropeScale: Float = 0.55         // < 1 shortens the measured rope length
    private let ropeMinYZ: Float = 3.5          // Minimum rope length (YZ plane)
    private let ropeMaxHard: Float = 8.0        // Hard upper bound
    private let minClearanceY: Float = 1.8      // Keep lowest swing point above ground by this margin

    // Tower layout
    private let towerHeight: Float = 5.0

    private let rowCount: Int = 12
    private let rowSpacing: Float = 20

    private let leftX: Float = -5
    private let rightX: Float =  5

    // Currently unused layout knobs (kept intentionally for future tuning/visual polish)
    private let laneInset: Float = 0.55
    private let landingZOffset: Float = 0.4
    private let swingArcHeight: Float = 0.8

    // Ground mesh
    private let groundThickness: Float = 0.05

    // Legacy/unused (kept to avoid altering any behavior/structure)
    private let playerCenterX: Float = 0

    // MARK: Scene entities (RealityKit graph)

    private var updateSub: Cancellable?
    private var seconds: Double = 0

    private let world = AnchorEntity(world: .zero)

    private let player = ModelEntity(
        mesh: .generateSphere(radius: 0.12),
        materials: [SimpleMaterial(color: .red, isMetallic: false)]
    )

    private let camera = PerspectiveCamera()
    private let cameraAnchor = AnchorEntity(world: .zero)

    private lazy var towerPrototype: ModelEntity = {
        let m = ModelEntity(
            mesh: .generateBox(size: [0.25, towerHeight, 0.25]),
            materials: [SimpleMaterial(color: .white, isMetallic: false)]
        )
        return m
    }()

    private var webEntity: ModelEntity? = nil

    private let audio: SpatialAudioRig
    private let audioMixController: TowerAudioMixController

    // MARK: Runtime state

    private var mode: PlayerMode = .rooftop

    private var playerPos: SIMD3<Float> = [0, 4.0, -14.0]
    private var playerVel: SIMD3<Float> = .zero

    private var swing: SwingState? = nil

    private var focusRemaining: Float = 0
    private var focusDelayRemaining: Float = 0
    private var focusActive: Bool { focusRemaining > 0 }

    // Optional: record which side the next tower is on (useful for debugging / player feedback)
    private var expectedNextSide: Side? = nil

    private var rows: [(tower: ModelEntity, z: Float, side: Side)] = []
    private var currentRow: Int = -1

    private var autoMove: AutoMove? = nil

    // WASD scaffolding (currently only keyUp removes keys; keyDown is dedicated to Q/E)
    private var pressed: Set<PlayerMotion.InputKey> = []
    private var motion = PlayerMotion(position: [0, 0.12, 0], speed: 2.0, fixedY: 0.12)

    // MARK: Init

    init(frame frameRect: CGRect, focusTiming: FocusTimingConfig = .default) {
        self.focusTiming = focusTiming
        self.audio = SpatialAudioRig()
        self.audioMixController = TowerAudioMixController(audio: audio)
        super.init(frame: frameRect)
        setupScene()
        setupUpdateLoop()

        audio.start()
    }

    @MainActor required init(frame frameRect: CGRect) {
        self.focusTiming = .default
        self.audio = SpatialAudioRig()
        self.audioMixController = TowerAudioMixController(audio: audio)
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
    }

    override func keyUp(with event: NSEvent) {
        if let k = mapKey(event) {
            pressed.remove(k)
            print("[keys] up   =", pressed)
        }
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
        mode = .rooftop
        world.addChild(player)

        // Generate rows of towers (alternating left/right)
        rows.removeAll()

        for i in 0..<rowCount {
            let z = -Float(i + 1) * rowSpacing

            // Alternate: row 0 left, row 1 right, row 2 left, ...
            let side: Side = (i % 2 == 0) ? .left : .right
            let x: Float = (side == .left) ? leftX : rightX

            let tower = towerPrototype.clone(recursive: true)
            tower.position = [x, towerHeight * 0.5, z]
            world.addChild(tower)

            rows.append((tower: tower, z: z, side: side))
        }

        // Spatial audio: one looping source per tower, listener follows player
        audio.configure(loopFileName: "tower_loop_mono1", fileExt: "wav")

        for row in rows {
            let sourceID = audio.addLoopingSource(at: row.tower.position(relativeTo: nil))
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

            // 1) Focus delay countdown (uses real time)
            if focusDelayRemaining > 0 {
                focusDelayRemaining -= realDt
                if focusDelayRemaining <= 0 {
                    focusDelayRemaining = 0
                    focusRemaining = focusTiming.duration
                    print("[focus] start (delayed)")
                }
            }

            // 2) Focus countdown (uses real time)
            if focusRemaining > 0 {
                focusRemaining -= realDt
                if focusRemaining <= 0 {
                    focusRemaining = 0
                    expectedNextSide = nil
                    audioMixController.clearFocusTarget()
                    print("[focus] end")
                }
            }

            // 3) Simulation dt: slowed only while focus is active
            let dt = realDt * ((focusRemaining > 0) ? focusTiming.timeScale : 1.0)

            // --- Movement state machine ---
            switch mode {
            case .rooftop:
                // Standing still until the first Q/E attaches a web
                playerPos = [centerX, rooftopY, rooftopStartZ]
                playerVel = .zero

            case .swinging:
                guard var s = swing else { mode = .falling; break }

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
                updateWeb(from: playerPos, to: s.anchor)

                // 6) Detach later, while rising, and not too low (to emphasize airtime + visible arc)
                let farEnough = playerPos.z < s.towerZ - detachAfterPassing
                let rising = playerVel.y > 0.4
                let highEnough = playerPos.y > (groundY + minClearanceY + 0.6)

                if farEnough && rising && highEnough {
                    let passedRow = s.rowIndex
                    print(String(format: "[web] detach y=%.2f z=%.2f vy=%.2f vz=%.2f",
                                 playerPos.y, playerPos.z, playerVel.y, playerVel.z))

                    swing = nil
                    hideWeb()
                    mode = .falling

                    // Schedule focus to start after a short delay
                    focusDelayRemaining = focusTiming.delay
                    focusRemaining = 0

                    let nextIndex = passedRow + 1
                    if nextIndex < rows.count {
                        expectedNextSide = rows[nextIndex].side
                        audioMixController.setFocusTargetRowIndex(nextIndex)
                        print("[focus] will start after delay. next side should be \(expectedNextSide!)")
                    } else {
                        expectedNextSide = nil
                        audioMixController.clearFocusTarget()
                        print("[focus] will start after delay (no next tower)")
                    }
                    break
                }

                // Persist updated rope length
                swing = s

            case .falling:
                // Free fall until hitting the ground
                playerVel.y += -gravity * dt
                playerPos += playerVel * dt
                playerPos.x = centerX

                if playerPos.y <= groundY {
                    playerPos.y = groundY
                    playerVel = .zero
                    mode = .grounded
                }

            case .grounded:
                // Grounded state (no movement yet)
                playerPos.x = centerX
                playerPos.y = groundY
            }

            // Apply transform to the entity
            player.position = playerPos
            updateCameraFollow()

            // Listener always follows the player
            audio.setListenerPosition(playerPos)
            audioMixController.updateMix(isFocusActive: focusActive)
        }
    }

    // MARK: Input gating (Q/E -> attemptShoot -> shootWeb)

    private func attemptShoot(_ side: Side) {
        // 1) Block shooting while grounded (prevents underground swinging)
        if mode == .grounded {
            print("[shoot] blocked (grounded/dead)")
            return
        }

        // 2) First shot is allowed from rooftop
        if mode == .rooftop {
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
        focusRemaining = 0
        expectedNextSide = nil
        audioMixController.clearFocusTarget()
        print("[focus] consumed by shot")
    }

    private func shootWeb(to side: Side) {
        // Target the next row
        let nextIndex: Int
        if let s = swing {
            nextIndex = s.rowIndex + 1
        } else {
            nextIndex = currentRow + 1
        }

        guard nextIndex >= 0 && nextIndex < rows.count else {
            print("[web] no next tower")
            return
        }

        let row = rows[nextIndex]
        guard row.side == side else {
            print("[web] wrong side. next is \(row.side), you pressed \(side)")
            return
        }

        let tower = row.tower
        let towerPos = tower.position(relativeTo: nil)

        // Anchor = top of tower + extra height (to increase swing angle)
        let towerTopY = towerPos.y + towerHeight * 0.5
        let anchor = SIMD3<Float>(towerPos.x, towerTopY + webAttachExtraHeight, towerPos.z)

        let dx = centerX - anchor.x
        let dy = playerPos.y - anchor.y
        let dz = playerPos.z - anchor.z
        let L2 = dx*dx + dy*dy + dz*dz
        let yz2 = max(L2 - dx*dx, 0.01)
        let measuredYZ = sqrt(yz2)

        // Keep lowest point above ground: lowest approx = anchor.y - ropeYZ
        let maxByClearance = max(anchor.y - (groundY + minClearanceY), ropeMinYZ)
        let ropeMax = min(ropeMaxHard, maxByClearance)

        // Target rope length (scaled + clamped)
        let ropeTargetYZ = min(max(measuredYZ * ropeScale, ropeMinYZ), ropeMax)

        // Current rope length starts at measuredYZ (keeps current position -> no teleport)
        let ropeCurrentYZ = measuredYZ

        swing = SwingState(anchor: anchor,
                           ropeLengthYZ: ropeCurrentYZ,
                           ropeTargetYZ: ropeTargetYZ,
                           towerZ: towerPos.z,
                           rowIndex: nextIndex)

        print(String(format: "[web] measuredYZ=%.2f targetYZ=%.2f anchorY=%.2f minY(target)≈%.2f",
                     measuredYZ, ropeTargetYZ, anchor.y, anchor.y - ropeTargetYZ))
        currentRow = nextIndex
        mode = .swinging

        // Add initial tangential velocity in the YZ plane to ensure forward swing
        // radial = (dy, dz), tangent = (-dz, dy) normalized
        let radial = SIMD2<Float>(dy, dz)
        let rLen = max(simd_length(radial), 0.001)
        let rN = radial / rLen
        let tangent = SIMD2<Float>(-rN.y, rN.x)

        playerVel.y += tangent.x * initialSwingSpeed
        playerVel.z += tangent.y * initialSwingSpeed

        print("[web] attach row=\(nextIndex) side=\(side) anchor=\(anchor)")
    }

    // MARK: Web rendering (entity creation/update/removal)

    private func showWeb(from start: SIMD3<Float>, to end: SIMD3<Float>) {
        // One-shot creation (kept for reference; current gameplay uses updateWeb each frame)
        webEntity?.removeFromParent()
        webEntity = nil

        let dir = end - start
        let length = simd_length(dir)
        guard length > 0.001 else { return }

        let mesh = MeshResource.generateCylinder(height: 1.0, radius: 0.01)
        let mat  = SimpleMaterial(color: .white, isMetallic: false)
        let web  = ModelEntity(mesh: mesh, materials: [mat])

        // Cylinder height is along local Y; scale Y to match length
        web.scale = [1, length, 1]

        // Place at midpoint
        let mid = (start + end) * 0.5
        web.position = mid

        // Rotate local (0,1,0) to match direction
        let n = dir / length
        web.orientation = simd_quatf(from: [0, 1, 0], to: n)

        world.addChild(web)
        webEntity = web
    }

    private func ensureWebEntity() -> ModelEntity {
        if let w = webEntity { return w }
        let mesh = MeshResource.generateCylinder(height: 1.0, radius: 0.01)
        let mat  = SimpleMaterial(color: .white, isMetallic: false)
        let w = ModelEntity(mesh: mesh, materials: [mat])
        world.addChild(w)
        webEntity = w
        return w
    }

    private func updateWeb(from start: SIMD3<Float>, to end: SIMD3<Float>) {
        let dir = end - start
        let length = simd_length(dir)
        if length < 0.001 { return }

        let w = ensureWebEntity()

        // Place at midpoint
        w.position = (start + end) * 0.5

        // Rotate cylinder local Y axis to direction
        let n = dir / length
        w.orientation = simd_quatf(from: [0, 1, 0], to: n)

        // Scale height to length
        w.scale = [1, length, 1]
    }

    private func hideWeb() {
        webEntity?.removeFromParent()
        webEntity = nil
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
        let width: Float = max(10, abs(leftX) + abs(rightX) + 6)
        let depth: Float = Float(rowCount + 3) * rowSpacing + 8

        let mesh = MeshResource.generateBox(size: [width, groundThickness, depth])
        let mat = SimpleMaterial(color: .gray, isMetallic: false)
        let ground = ModelEntity(mesh: mesh, materials: [mat])

        // Place so the top surface is at y=0, extending from z=0 forward into negative Z
        ground.position = [0, -groundThickness * 0.5, -depth * 0.5]
        return ground
    }

    // MARK: Helpers

    private func mapKey(_ event: NSEvent) -> PlayerMotion.InputKey? {
        // Prefer characters (keyboard-layout friendly), fall back to keyCode
        if let c = event.charactersIgnoringModifiers?.lowercased() {
            switch c {
            case "w": return .w
            case "a": return .a
            case "s": return .s
            case "d": return .d
            default: break
            }
        }

        // Common US keyboard keyCodes: W=13 A=0 S=1 D=2
        switch event.keyCode {
        case 13: return .w
        case 0:  return .a
        case 1:  return .s
        case 2:  return .d
        default: return nil
        }
    }
}
