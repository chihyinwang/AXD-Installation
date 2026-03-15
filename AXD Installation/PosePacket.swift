import Foundation

struct PosePacket: Codable {
    let timestamp: TimeInterval
    let armModeCode: Int
    let armPoseStateCode: Int
    let raiseAngleDegrees: Float
    let wristOutDegrees: Float
}
