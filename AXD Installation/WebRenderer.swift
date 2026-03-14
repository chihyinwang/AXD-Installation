import Foundation
import RealityKit
import simd
import AppKit

final class WebRenderer {
    private weak var world: Entity?
    private var webEntity: ModelEntity?
    private var prepLeftWebEntity: ModelEntity?
    private var prepRightWebEntity: ModelEntity?
    private var failedWebEntity: ModelEntity?
    private var failedShotState: FailedShotState?

    private struct FailedShotState {
        let start: SIMD3<Float>
        let end: SIMD3<Float>
        let duration: Float
        var remaining: Float
    }

    init(world: Entity) {
        self.world = world
    }

    func updateWeb(from start: SIMD3<Float>, to end: SIMD3<Float>) {
        let dir = end - start
        let length = simd_length(dir)
        guard length >= 0.001 else { return }

        let web = ensureWebEntity()
        web.position = (start + end) * 0.5
        web.orientation = simd_quatf(from: [0, 1, 0], to: dir / length)
        web.scale = [1, length, 1]
    }

    func hideWeb() {
        webEntity?.removeFromParent()
        webEntity = nil
    }

    func updatePrepWeb(side: TowerSide, from start: SIMD3<Float>, to end: SIMD3<Float>) {
        let dir = end - start
        let length = simd_length(dir)
        guard length >= 0.001 else { return }

        let web = ensurePrepWebEntity(side: side)
        web.position = (start + end) * 0.5
        web.orientation = simd_quatf(from: [0, 1, 0], to: dir / length)
        web.scale = [1, length, 1]
    }

    func hidePrepWeb(side: TowerSide) {
        switch side {
        case .left:
            prepLeftWebEntity?.removeFromParent()
            prepLeftWebEntity = nil
        case .right:
            prepRightWebEntity?.removeFromParent()
            prepRightWebEntity = nil
        }
    }

    func hideAllPrepWebs() {
        hidePrepWeb(side: .left)
        hidePrepWeb(side: .right)
    }

    func triggerFailedShot(from start: SIMD3<Float>, to end: SIMD3<Float>, duration: Float = 0.22) {
        let d = max(duration, 0.05)
        failedShotState = FailedShotState(start: start, end: end, duration: d, remaining: d)
        updateFailedWeb(start: start, end: end)
    }

    func tick(deltaTime: Float) {
        guard var state = failedShotState else { return }
        guard deltaTime > 0 else { return }

        state.remaining -= deltaTime
        if state.remaining <= 0 {
            failedShotState = nil
            failedWebEntity?.removeFromParent()
            failedWebEntity = nil
            return
        }

        failedShotState = state
        let t = 1.0 - (state.remaining / state.duration)
        var currentEnd = state.end + (state.start - state.end) * t
        currentEnd.y -= 0.7 * t
        updateFailedWeb(start: state.start, end: currentEnd)
    }

    private func ensureWebEntity() -> ModelEntity {
        if let webEntity { return webEntity }
        let mesh = MeshResource.generateCylinder(height: 1.0, radius: 0.01)
        let material = SimpleMaterial(color: .white, isMetallic: false)
        let web = ModelEntity(mesh: mesh, materials: [material])
        world?.addChild(web)
        webEntity = web
        return web
    }

    private func ensurePrepWebEntity(side: TowerSide) -> ModelEntity {
        switch side {
        case .left:
            if let prepLeftWebEntity { return prepLeftWebEntity }
        case .right:
            if let prepRightWebEntity { return prepRightWebEntity }
        }

        let mesh = MeshResource.generateCylinder(height: 1.0, radius: 0.009)
        let material = UnlitMaterial(color: .white)
        let web = ModelEntity(mesh: mesh, materials: [material])
        world?.addChild(web)

        switch side {
        case .left:
            prepLeftWebEntity = web
        case .right:
            prepRightWebEntity = web
        }
        return web
    }

    private func ensureFailedWebEntity() -> ModelEntity {
        if let failedWebEntity { return failedWebEntity }
        let mesh = MeshResource.generateCylinder(height: 1.0, radius: 0.008)
        let material = UnlitMaterial(color: .lightGray)
        let web = ModelEntity(mesh: mesh, materials: [material])
        world?.addChild(web)
        failedWebEntity = web
        return web
    }

    private func updateFailedWeb(start: SIMD3<Float>, end: SIMD3<Float>) {
        let dir = end - start
        let length = simd_length(dir)
        guard length >= 0.001 else { return }

        let web = ensureFailedWebEntity()
        web.position = (start + end) * 0.5
        web.orientation = simd_quatf(from: [0, 1, 0], to: dir / length)
        web.scale = [1, length, 1]
    }
}
