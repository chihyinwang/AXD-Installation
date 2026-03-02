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

// SwiftUI -> AppKit bridge
struct GameView: NSViewRepresentable {
    func makeNSView(context: Context) -> GameARView { GameARView(frame: .zero) }
    func updateNSView(_ nsView: GameARView, context: Context) {}
}

// RealityKit view in non-AR mode (macOS desktop)
final class GameARView: ARView {

    private var updateSub: Cancellable?
    private var seconds: Double = 0

    private let world = AnchorEntity(world: .zero)

    private let player = ModelEntity(
        mesh: .generateSphere(radius: 0.12),
        materials: [SimpleMaterial(color: .red, isMetallic: false)]
    )

    private let tower = ModelEntity(
        mesh: .generateBox(size: [0.25, 1.2, 0.25]),
        materials: [SimpleMaterial(color: .white, isMetallic: false)]
    )

    private let camera = PerspectiveCamera()
    private let cameraAnchor = AnchorEntity(world: .zero)

    // MARK: init
    required init(frame frameRect: CGRect) {
        super.init(frame: frameRect)
        setupScene()
        setupUpdateLoop()
    }

    @MainActor required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Keyboard focus
    override var acceptsFirstResponder: Bool { true } // allow key events :contentReference[oaicite:4]{index=4}

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self) // try to grab focus :contentReference[oaicite:5]{index=5}
        print("[focus] firstResponder =", String(describing: window?.firstResponder))
    }

    override func keyDown(with event: NSEvent) {
        let c = event.charactersIgnoringModifiers ?? ""
        print("[keyDown] code=\(event.keyCode) chars=\(c)")
    }

    // MARK: Scene setup
    private func setupScene() {
        environment.background = .color(.black)

        scene.addAnchor(world)

        player.position = [0, 0.12, 0]
        tower.position  = [0.8, 0.6, -1.6]

        world.addChild(player)
        world.addChild(tower)

        // light so you can see white tower
        let light = DirectionalLight()
        light.light.intensity = 2000
        light.look(at: .zero, from: [1, 2, 2], relativeTo: nil)
        world.addChild(light)

        // fixed third-person-ish camera
        camera.camera.fieldOfViewInDegrees = 60
        cameraAnchor.addChild(camera)
        scene.addAnchor(cameraAnchor)
    }

    // MARK: Update loop (per frame)
    private func setupUpdateLoop() {
        // SceneEvents.Update fires every frame :contentReference[oaicite:7]{index=7}
        updateSub = scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            guard let self else { return }

            // heartbeat: print once per second
            self.seconds += event.deltaTime
            if self.seconds >= 1.0 {
                self.seconds = 0
                print("[tick] deltaTime =", String(format: "%.4f", event.deltaTime))
            }

            // lock camera (no mouse pan)
            let camPos: SIMD3<Float> = [0, 1.2, 2.6]
            self.camera.transform.translation = camPos
            self.camera.look(at: self.player.position(relativeTo: nil),
                             from: camPos,
                             relativeTo: nil)
        }
    }
}
