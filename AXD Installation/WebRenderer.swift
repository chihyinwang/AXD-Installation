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
    private var webCastState: WebCastState?
    private var detachedRopeState: DetachedRopeState?
    private var detachedRopeSegmentEntities: [ModelEntity] = []
    private var detachedRopeSimulationTime: Float = 0
    private let detachedRopePointCount: Int = 12
    private let detachedRopeSegmentRadius: Float = 0.0065

    private struct FailedShotState {
        enum Phase {
            case casting
            case dropping
        }
        let start: SIMD3<Float>
        let end: SIMD3<Float>
        let castDuration: Float
        let dropDuration: Float
        var phase: Phase
        var remaining: Float
    }

    private struct WebCastState {
        let duration: Float
        var remaining: Float
    }

    private struct DetachedRopeState {
        var points: [SIMD3<Float>]
        var previousPoints: [SIMD3<Float>]
        let segmentLength: Float
        var remaining: Float
        let pinnedStart: Bool
        let startPinPosition: SIMD3<Float>
    }

    init(world: Entity) {
        self.world = world
    }

    func startWebCast(duration: Float = 0.12) {
        let d = max(duration, 0.04)
        webCastState = WebCastState(duration: d, remaining: d)
    }

    func updateWeb(from start: SIMD3<Float>, to end: SIMD3<Float>) {
        let dir = end - start
        let length = simd_length(dir)
        guard length >= 0.001 else { return }

        if var cast = webCastState {
            cast.remaining = max(cast.remaining, 0)
            let progress = min(max(1.0 - (cast.remaining / cast.duration), 0.0), 1.0)
            let currentEnd = start + dir * progress
            updateStraightWeb(start: start, end: currentEnd)
            if progress >= 1.0 {
                webCastState = nil
            } else {
                webCastState = cast
            }
            return
        }

        updateStraightWeb(start: start, end: end)
    }

    func dropCurrentWebSoftly(from start: SIMD3<Float>, to end: SIMD3<Float>, lifetime: Float = 0.9) {
        hideWeb()
        spawnDetachedRope(from: start, to: end, pinnedStart: false, lifetime: lifetime)
    }

    private func updateStraightWeb(start: SIMD3<Float>, end: SIMD3<Float>) {
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
        webCastState = nil

        failedShotState = nil
        failedWebEntity?.removeFromParent()
        failedWebEntity = nil

        detachedRopeState = nil
        clearDetachedSegments()
        detachedRopeSimulationTime = 0
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

    func triggerFailedShot(from start: SIMD3<Float>, to end: SIMD3<Float>, castDuration: Float = 0.12, dropDuration: Float = 0.95) {
        let cast = max(castDuration, 0.04)
        let drop = max(dropDuration, 0.4)
        failedShotState = FailedShotState(
            start: start,
            end: end,
            castDuration: cast,
            dropDuration: drop,
            phase: .casting,
            remaining: cast
        )
        updateFailedWeb(start: start, end: start)
    }

    func tick(deltaTime: Float) {
        guard deltaTime > 0 else { return }

        if var cast = webCastState {
            cast.remaining -= deltaTime
            webCastState = cast.remaining <= 0 ? nil : cast
        }

        tickFailedShot(deltaTime: deltaTime)
        tickDetachedRope(deltaTime: deltaTime)
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

    private func tickFailedShot(deltaTime: Float) {
        guard var state = failedShotState else { return }

        state.remaining -= deltaTime
        if state.remaining <= 0 {
            switch state.phase {
            case .casting:
                failedShotState = FailedShotState(
                    start: state.start,
                    end: state.end,
                    castDuration: state.castDuration,
                    dropDuration: state.dropDuration,
                    phase: .dropping,
                    remaining: state.dropDuration
                )
                failedWebEntity?.removeFromParent()
                failedWebEntity = nil
                spawnDetachedRope(from: state.start, to: state.end, pinnedStart: true, lifetime: state.dropDuration)
            case .dropping:
                failedShotState = nil
            }
            return
        }

        failedShotState = state

        guard state.phase == .casting else { return }
        let t = 1.0 - (state.remaining / state.castDuration)
        let currentEnd = state.start + (state.end - state.start) * t
        updateFailedWeb(start: state.start, end: currentEnd)
    }

    private func spawnDetachedRope(from start: SIMD3<Float>, to end: SIMD3<Float>, pinnedStart: Bool, lifetime: Float) {
        let points = max(detachedRopePointCount, 4)
        var ropePoints: [SIMD3<Float>] = []
        ropePoints.reserveCapacity(points)

        let dir = end - start
        let totalLength = max(simd_length(dir), 0.001)
        let dirN = dir / totalLength

        var sideAxis = simd_cross(dirN, SIMD3<Float>(0, 1, 0))
        if simd_length(sideAxis) < 0.001 {
            sideAxis = SIMD3<Float>(1, 0, 0)
        } else {
            sideAxis = simd_normalize(sideAxis)
        }
        let bendAxis = simd_normalize(simd_cross(sideAxis, dirN))

        let lateralAmplitude: Float = pinnedStart ? 0.08 : 0.14
        let sagAmplitude: Float = pinnedStart ? 0.10 : 0.18

        for i in 0..<points {
            let t = Float(i) / Float(points - 1)
            var p = start + dir * t
            let bell = 4.0 * t * (1.0 - t)
            let wave = sin(t * .pi * 3.0)
            p += sideAxis * (wave * lateralAmplitude * bell)
            p -= bendAxis * (sagAmplitude * bell)
            ropePoints.append(p)
        }

        var previousPoints = ropePoints
        for i in 0..<points {
            if pinnedStart && i == 0 { continue }
            let t = Float(i) / Float(points - 1)
            let swirl = ((i % 2 == 0) ? 1.0 : -1.0) * (0.015 + 0.02 * t)
            previousPoints[i] = ropePoints[i] + sideAxis * swirl
        }

        let slackMultiplier: Float = pinnedStart ? 1.08 : 1.22
        detachedRopeState = DetachedRopeState(
            points: ropePoints,
            previousPoints: previousPoints,
            segmentLength: (totalLength * slackMultiplier) / Float(points - 1),
            remaining: max(lifetime, 0.2),
            pinnedStart: pinnedStart,
            startPinPosition: start
        )

        detachedRopeSimulationTime = 0
        ensureDetachedSegmentEntities(count: points - 1)
        updateDetachedRopeRender()
    }

    private func tickDetachedRope(deltaTime: Float) {
        guard var state = detachedRopeState else { return }
        state.remaining -= deltaTime
        if state.remaining <= 0 {
            detachedRopeState = nil
            clearDetachedSegments()
            detachedRopeSimulationTime = 0
            return
        }

        detachedRopeSimulationTime += deltaTime
        let gravity = SIMD3<Float>(0, -8.2, 0)
        let dt2 = deltaTime * deltaTime

        for i in 0..<state.points.count {
            if state.pinnedStart && i == 0 {
                state.points[i] = state.startPinPosition
                state.previousPoints[i] = state.startPinPosition
                continue
            }

            let current = state.points[i]
            let previous = state.previousPoints[i]
            let pointT = Float(i) / Float(max(state.points.count - 1, 1))
            let damping = max(0.935, 0.985 - pointT * 0.035)
            let wind = SIMD3<Float>(
                sin(detachedRopeSimulationTime * 4.2 + Float(i) * 0.7) * (0.22 + 0.26 * pointT),
                0,
                cos(detachedRopeSimulationTime * 3.1 + Float(i) * 0.5) * (0.12 + 0.18 * pointT)
            )
            let velocity = (current - previous) * damping
            let next = current + velocity + (gravity + wind) * dt2
            state.previousPoints[i] = current
            state.points[i] = next
        }

        for _ in 0..<2 {
            if state.pinnedStart {
                state.points[0] = state.startPinPosition
            }
            for i in 0..<(state.points.count - 1) {
                let p1 = state.points[i]
                let p2 = state.points[i + 1]
                let delta = p2 - p1
                let dist = max(simd_length(delta), 0.0001)
                let error = (dist - state.segmentLength) / dist
                let softness: Float = 0.82
                let correction = delta * 0.5 * error * softness

                if state.pinnedStart && i == 0 {
                    state.points[i + 1] -= correction * 2.0
                } else {
                    state.points[i] += correction
                    state.points[i + 1] -= correction
                }
            }
        }

        detachedRopeState = state
        updateDetachedRopeRender()
    }

    private func ensureDetachedSegmentEntities(count: Int) {
        if detachedRopeSegmentEntities.count >= count { return }
        for _ in detachedRopeSegmentEntities.count..<count {
            let mesh = MeshResource.generateCylinder(height: 1.0, radius: detachedRopeSegmentRadius)
            let material = UnlitMaterial(color: .white)
            let entity = ModelEntity(mesh: mesh, materials: [material])
            world?.addChild(entity)
            detachedRopeSegmentEntities.append(entity)
        }
    }

    private func clearDetachedSegments() {
        for segment in detachedRopeSegmentEntities {
            segment.removeFromParent()
        }
        detachedRopeSegmentEntities.removeAll(keepingCapacity: false)
    }

    private func updateDetachedRopeRender() {
        guard let state = detachedRopeState else { return }
        let segmentCount = state.points.count - 1
        ensureDetachedSegmentEntities(count: segmentCount)

        for i in 0..<segmentCount {
            let start = state.points[i]
            let end = state.points[i + 1]
            let dir = end - start
            let length = max(simd_length(dir), 0.0001)
            let segment = detachedRopeSegmentEntities[i]
            segment.position = (start + end) * 0.5
            segment.orientation = simd_quatf(from: [0, 1, 0], to: dir / length)
            segment.scale = [1, length, 1]
        }
    }
}
