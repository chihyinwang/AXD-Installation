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

    // tower
    private let towerPrototype = ModelEntity(
        mesh: .generateBox(size: [0.25, 1.2, 0.25]),
        materials: [SimpleMaterial(color: .white, isMetallic: false)]
    )

    private enum Side { case left, right }

    private var rows: [(tower: ModelEntity, z: Float, side: Side)] = []
    private var currentRow: Int = -1

    private struct AutoMove {
        var start: SIMD3<Float>
        var end: SIMD3<Float>
        var elapsed: Float
        var duration: Float
    }
    private var autoMove: AutoMove? = nil

    // tuning knobs (你之後想改地圖密度就改這裡)
    private let rowCount: Int = 6
    private let rowSpacing: Float = 2.2
    private let leftX: Float = -1.4
    private let rightX: Float =  1.4
    private let laneInset: Float = 0.55      // 落點離 tower 中心多近
    private let landingZOffset: Float = 0.4  // 落點在 tower 前/後一點點
    private let swingArcHeight: Float = 0.8  // 蜘蛛人飛行弧線高度（純視覺）

    private let camera = PerspectiveCamera()
    private let cameraAnchor = AnchorEntity(world: .zero)

    private var pressed: Set<PlayerMotion.InputKey> = []
    private var motion = PlayerMotion(position: [0, 0.12, 0], speed: 2.0, fixedY: 0.12)
    
    private let audio = SpatialAudioRig()
    
    // MARK: init
    required init(frame frameRect: CGRect) {
        super.init(frame: frameRect)
        setupScene()
        setupUpdateLoop()
        
        audio.start()
//        audio.setListenerPosition(player.position(relativeTo: nil))
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
        let c = (event.charactersIgnoringModifiers ?? "").lowercased()

        // 忽略長按造成的重複 keyDown，避免一次跳多列 :contentReference[oaicite:1]{index=1}
        if event.isARepeat { return }

        if c == "q" { sling(to: .left); return }
        if c == "e" { sling(to: .right); return }
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

        player.position = [0, 0.12, 0]
        world.addChild(player)
        
        // Generate rows of towers (left & right columns)
        rows.removeAll()

        for i in 0..<rowCount {
            let z = -Float(i + 1) * rowSpacing

            // 交錯：第 0 排 left、第 1 排 right、第 2 排 left…
            // 想反過來就把 left/right 對調
            let side: Side = (i % 2 == 0) ? .left : .right
            let x: Float = (side == .left) ? leftX : rightX

            let tower = towerPrototype.clone(recursive: true)
            tower.position = [x, 0.6, z]
            world.addChild(tower)

            rows.append((tower: tower, z: z, side: side))
        }
        
        audio.configure(loopFileName: "tower_loop_mono", fileExt: "wav")

        for row in rows {
            _ = audio.addLoopingSource(at: row.tower.position(relativeTo: nil))
        }

        audio.start()
        audio.setListenerPosition(player.position(relativeTo: nil))

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
            
            let dt = Float(event.deltaTime)

            // 1) Auto move (Q/E sling)
            if var m = autoMove {
                m.elapsed += dt
                let t = min(m.elapsed / m.duration, 1)

                // smoothstep easing: 看起來更像衝刺/擺盪
                let eased = t * t * (3 - 2 * t)

                var pos = m.start + (m.end - m.start) * eased

                // 加一點「蜘蛛人弧線」(中間高、起落貼地)
                let arc = swingArcHeight * sin(Float.pi * eased)
                pos.y = m.end.y + arc

                motion.position = pos
                player.position = pos

                if t >= 1 {
                    // 落地：把 y 拉回地面
                    motion.position.y = m.end.y
                    player.position.y = m.end.y
                    autoMove = nil
                } else {
                    autoMove = m
                }
            } else {
                // 2) Manual move (WASD) — 你原本的邏輯照用
                motion.step(inputs: pressed, deltaTime: dt)
                player.position = motion.position
            }

            // 3) Listener 永遠每幀同步（你 Step 3 的核心要求）
            audio.setListenerPosition(player.position(relativeTo: nil))

            // 4) Camera lock / follow
            let camOffset: SIMD3<Float> = [0, 1.2, 2.6]
            let camPos = self.player.position(relativeTo: nil) + camOffset
            self.camera.transform.translation = camPos
            self.camera.look(at: self.player.position(relativeTo: nil),
                             from: camPos,
                             relativeTo: nil)
        }
    }
    
    private func sling(to side: Side) {
        if autoMove != nil { return }

        let next = currentRow + 1
        guard next < rows.count else {
            print("[sling] reached end of rows")
            return
        }

        let row = rows[next]

        // ✅ 關鍵：如果你按的是 Q(左) 但下一排塔在右，就不讓你跳（保持 q e q e 節奏）
        guard row.side == side else {
            print("[sling] wrong side. next row is \(row.side), you pressed \(side)")
            return
        }

        let tower = row.tower

        // 落點：在 tower 旁邊（靠近中線一點）
        let targetX = (side == .left) ? (leftX + laneInset) : (rightX - laneInset)
        let targetZ = row.z + landingZOffset
        let targetY = motion.position.y

        let start = motion.position
        let end: SIMD3<Float> = [targetX, targetY, targetZ]

        autoMove = AutoMove(start: start, end: end, elapsed: 0, duration: 0.35)
        currentRow = next

        print("[sling] row=\(next) side=\(side) end=\(end) tower=\(tower.position(relativeTo: nil))")
    }
    
    private func mapKey(_ event: NSEvent) -> PlayerMotion.InputKey? {
        // 優先用字元（適配不同鍵盤佈局），再用 keyCode 當備援
        if let c = event.charactersIgnoringModifiers?.lowercased() {
            switch c {
            case "w": return .w
            case "a": return .a
            case "s": return .s
            case "d": return .d
            default: break
            }
        }

        // keyCode 備援（常見 US 鍵盤：W=13 A=0 S=1 D=2）
        switch event.keyCode {
        case 13: return .w
        case 0:  return .a
        case 1:  return .s
        case 2:  return .d
        default: return nil
        }
    }
}
