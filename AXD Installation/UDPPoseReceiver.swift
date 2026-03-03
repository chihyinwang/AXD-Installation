import Foundation
import Network
import Combine

final class UDPPoseReceiver: ObservableObject {
    @Published var isListening = false
    @Published var listenerStateDescription = "idle"
    @Published var listenerErrorDescription = "-"
    @Published var packetCount = 0
    @Published var lastDeviceID = "-"
    @Published var lastTimestamp: TimeInterval = 0
    @Published var x: Float = 0
    @Published var y: Float = 0
    @Published var z: Float = 0
    @Published var raiseAngleDegrees: Float = 0
    @Published var isHandRaised: Bool = false

    private let queue = DispatchQueue(label: "udp.pose.receiver")
    private let decoder = JSONDecoder()
    private let port: UInt16
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    init(port: UInt16 = 7777) {
        self.port = port
    }

    func start() {
        guard listener == nil else { return }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            print("[udp-recv] invalid port \(port)")
            return
        }

        do {
            let listener = try NWListener(using: .udp, on: nwPort)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleNewConnection(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                DispatchQueue.main.async {
                    self.listenerStateDescription = String(describing: state)
                }
                switch state {
                case .ready:
                    DispatchQueue.main.async {
                        self.isListening = true
                        self.listenerErrorDescription = "-"
                    }
                    print("[udp-recv] listening on \(self.port)")
                case .waiting(let error):
                    DispatchQueue.main.async {
                        self.isListening = false
                        self.listenerErrorDescription = String(describing: error)
                    }
                    print("[udp-recv] listener waiting: \(error)")
                case .failed(let error):
                    DispatchQueue.main.async {
                        self.isListening = false
                        self.listenerErrorDescription = String(describing: error)
                    }
                    print("[udp-recv] listener failed: \(error)")
                case .cancelled:
                    DispatchQueue.main.async {
                        self.isListening = false
                        self.listenerErrorDescription = "-"
                    }
                    print("[udp-recv] listener cancelled")
                default:
                    break
                }
            }

            self.listener = listener
            listener.start(queue: queue)
        } catch {
            print("[udp-recv] failed to start listener: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil

        for (_, connection) in connections {
            connection.cancel()
        }
        connections.removeAll()

        DispatchQueue.main.async {
            self.isListening = false
            self.listenerStateDescription = "idle"
            self.listenerErrorDescription = "-"
        }
    }

    private func handleNewConnection(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections[key] = connection

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed(let error):
                print("[udp-recv] connection failed: \(error)")
                self.connections.removeValue(forKey: key)
            case .cancelled:
                self.connections.removeValue(forKey: key)
            default:
                break
            }
        }

        connection.start(queue: queue)
        receiveNext(on: connection, key: key)
    }

    private func receiveNext(on connection: NWConnection, key: ObjectIdentifier) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                self.handlePacketData(data)
            }

            if let error {
                print("[udp-recv] receive error: \(error)")
                self.connections.removeValue(forKey: key)
                return
            }

            if self.connections[key] != nil {
                self.receiveNext(on: connection, key: key)
            }
        }
    }

    private func handlePacketData(_ data: Data) {
        do {
            let packet = try decoder.decode(PosePacket.self, from: data)
            DispatchQueue.main.async {
                self.packetCount += 1
                self.lastDeviceID = packet.deviceID
                self.lastTimestamp = packet.timestamp
                self.x = packet.x
                self.y = packet.y
                self.z = packet.z
                self.raiseAngleDegrees = packet.raiseAngleDegrees
                self.isHandRaised = packet.isHandRaised
            }
        } catch {
            print("[udp-recv] decode error: \(error)")
        }
    }
}
