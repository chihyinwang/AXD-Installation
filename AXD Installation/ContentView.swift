//
//  ContentView.swift
//  AXD Installation
//
//  Created by chihyin wang on 02/03/2026.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var poseReceiver = UDPPoseReceiver(port: 7777)

    var body: some View {
        ZStack(alignment: .topLeading) {
            GameView()
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 6) {
                Text("iPhone Pose Receiver")
                    .font(.headline)
                Text(poseReceiver.isListening ? "listening: 7777" : "not listening")
                Text("device: \(poseReceiver.lastDeviceID)")
                Text(String(format: "x: %.3f", poseReceiver.x))
                Text(String(format: "y: %.3f", poseReceiver.y))
                Text(String(format: "z: %.3f", poseReceiver.z))
                Text(String(format: "raiseAngle: %.1f°", poseReceiver.raiseAngleDegrees))
                Text("isHandRaised: \(poseReceiver.isHandRaised ? "true" : "false")")
//                Text("packets: \(poseReceiver.packetCount)")
//                Text("listener state: \(poseReceiver.listenerStateDescription)")
//                Text("listener error: \(poseReceiver.listenerErrorDescription)")
            }
            .font(.system(.body, design: .monospaced))
            .padding(12)
            .background(.black.opacity(0.7))
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding()
        }
        .onAppear {
            poseReceiver.start()
        }
        .onDisappear {
            poseReceiver.stop()
        }
    }
}

#Preview {
    ContentView()
}
