import Foundation
import RealityKit
import simd
import AppKit

final class WebRenderer {
    private weak var world: Entity?
    private var webEntity: ModelEntity?

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

    private func ensureWebEntity() -> ModelEntity {
        if let webEntity { return webEntity }
        let mesh = MeshResource.generateCylinder(height: 1.0, radius: 0.01)
        let material = SimpleMaterial(color: .white, isMetallic: false)
        let web = ModelEntity(mesh: mesh, materials: [material])
        world?.addChild(web)
        webEntity = web
        return web
    }
}
