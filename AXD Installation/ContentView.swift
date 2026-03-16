//
//  ContentView.swift
//  AXD Installation
//
//  Created by chihyin wang on 02/03/2026.
//

import SwiftUI

enum AppScene {
    case game
    case tutorialPart1
    case tutorialPart2
}

struct ContentView: View {
    @State private var sceneSelection: AppScene = .game
    @State private var sceneResetID: UUID = UUID()
    @State private var tutorialMessage: String = "Welcome to the tutorial part 1. Please press the hand grip once to see the next step."
    @StateObject private var poseReceiver = UDPPoseReceiver(port: 7777)

    var body: some View {
        ZStack(alignment: .top) {
            if sceneSelection == .game {
                GameView(onSceneRequest: requestScene)
                    .id(sceneResetID)
                    .ignoresSafeArea()
            } else if sceneSelection == .tutorialPart1 {
                TutorialGameView(
                    entryMode: .part1,
                    leftArmPoseStateCode: poseReceiver.leftPacket?.armPoseStateCode,
                    rightArmPoseStateCode: poseReceiver.rightPacket?.armPoseStateCode,
                    onTutorialMessageChanged: { message in
                        tutorialMessage = message
                    },
                    onSceneRequest: requestScene
                )
                    .id(sceneResetID)
                    .ignoresSafeArea()
            } else {
                TutorialGameView(
                    entryMode: .part2,
                    leftArmPoseStateCode: poseReceiver.leftPacket?.armPoseStateCode,
                    rightArmPoseStateCode: poseReceiver.rightPacket?.armPoseStateCode,
                    onTutorialMessageChanged: { message in
                        tutorialMessage = message
                    },
                    onSceneRequest: requestScene
                )
                    .id(sceneResetID)
                    .ignoresSafeArea()
            }

            VStack(spacing: 10) {
                if sceneSelection != .game {
                    Text(tutorialMessage)
                        .font(.system(.body, design: .monospaced))
                        .padding(12)
                        .background(.black.opacity(0.8))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                HStack(alignment: .top, spacing: 12) {
                    posePanel(
                        title: "Left Hand (armModeCode=0)",
                        packet: poseReceiver.leftPacket,
                        fallbackModeCode: 0
                    )

                    Spacer(minLength: 0)

                    posePanel(
                        title: "Right Hand (armModeCode=1)",
                        packet: poseReceiver.rightPacket,
                        fallbackModeCode: 1
                    )
                }
            }
            .padding()
            .padding(.top, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            poseReceiver.start()
        }
        .onDisappear {
            poseReceiver.stop()
        }
    }

    private func requestScene(_ target: AppScene) {
        sceneSelection = target
        switch target {
        case .game:
            break
        case .tutorialPart1:
            tutorialMessage = "Welcome to the tutorial part 1. Please press the hand grip once to see the next step."
        case .tutorialPart2:
            tutorialMessage = "Welcome to the tutorial part 2. Please press the hand grip once to see the next step."
        }
        sceneResetID = UUID()
    }

    @ViewBuilder
    private func posePanel(title: String, packet: PosePacket?, fallbackModeCode: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            Text(poseReceiver.isListening ? "listening: 7777" : "not listening")

            if let packet {
                Text("timestamp: \(String(format: "%.3f", packet.timestamp))")
                Text("armModeCode: \(packet.armModeCode)")
                Text("armPoseStateCode: \(packet.armPoseStateCode)")
                Text(String(format: "raiseAngle: %.1f°", packet.raiseAngleDegrees))
                Text(String(format: "wristOut: %.1f°", packet.wristOutDegrees))
            } else {
                Text("timestamp: -")
                Text("armModeCode: \(fallbackModeCode)")
                Text("armPoseStateCode: -")
                Text("raiseAngle: -")
                Text("wristOut: -")
            }
        }
        .font(.system(.body, design: .monospaced))
        .padding(12)
        .background(.black.opacity(0.7))
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    ContentView()
}
