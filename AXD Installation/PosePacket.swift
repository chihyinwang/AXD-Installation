import Foundation

struct PosePacket: Codable {
    let deviceID: String
    let timestamp: TimeInterval
    let x: Float
    let y: Float
    let z: Float
    let qx: Float
    let qy: Float
    let qz: Float
    let qw: Float
    let raiseAngleDegrees: Float
    let isHandRaised: Bool
}

