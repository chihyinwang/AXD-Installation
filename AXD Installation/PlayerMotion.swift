//
//  PlayerMotion.swift
//  AXD Installation
//
//  Created by chihyin wang on 02/03/2026.
//

import simd

struct PlayerMotion {
    enum InputKey: Hashable { case w, a, s, d }

    var position: SIMD3<Float>
    let speed: Float          // meters per second
    let fixedY: Float         // keep player on ground plane

    init(position: SIMD3<Float>, speed: Float, fixedY: Float) {
        self.position = position
        self.speed = speed
        self.fixedY = fixedY
        self.position.y = fixedY
    }

    mutating func step(inputs: Set<InputKey>, deltaTime dt: Float) {
        guard dt > 0 else { return }

        var dir = SIMD3<Float>(repeating: 0)
        if inputs.contains(.w) { dir.z -= 1 }
        if inputs.contains(.s) { dir.z += 1 }
        if inputs.contains(.a) { dir.x -= 1 }
        if inputs.contains(.d) { dir.x += 1 }

        // no input -> no move
        if dir.x == 0 && dir.z == 0 { return }

        // normalize so diagonal isn't faster
        let len = simd_length(SIMD2<Float>(dir.x, dir.z))
        if len > 0 {
            dir.x /= len
            dir.z /= len
        }

        position += dir * (speed * dt)
        position.y = fixedY
    }
}
