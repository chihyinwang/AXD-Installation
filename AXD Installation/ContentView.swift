//
//  ContentView.swift
//  AXD Installation
//
//  Created by chihyin wang on 02/03/2026.
//

import SwiftUI

struct ContentView: View {
    private enum SceneSelection {
        case game
        case tutorial
    }

    @State private var sceneSelection: SceneSelection = .game
    @State private var tutorialMessage: String = "Welcome to the tutorial. Please press the hand grip once to see the next step."
    @StateObject private var poseReceiver = UDPPoseReceiver(port: 7777)

    var body: some View {
        ZStack(alignment: .top) {
            if sceneSelection == .game {
                GameView(onToggleScene: toggleSceneSelection)
                    .ignoresSafeArea()
            } else {
                TutorialGameView(
                    leftArmPoseStateCode: poseReceiver.leftPacket?.armPoseStateCode,
                    rightArmPoseStateCode: poseReceiver.rightPacket?.armPoseStateCode,
                    onTutorialMessageChanged: { message in
                        tutorialMessage = message
                    },
                    onToggleScene: toggleSceneSelection
                )
                    .ignoresSafeArea()
            }

            VStack(spacing: 10) {
                if sceneSelection == .tutorial {
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

    private func toggleSceneSelection() {
        sceneSelection = (sceneSelection == .game) ? .tutorial : .game
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
