import Foundation
import Network
import CoreImage
import os.log

/// Streams engine frames as JPEG over a loopback WebSocket to the Chrome extension.
/// Browsers don't apply CORS to WebSockets, so the Origin check is what stops other websites reading the camera.
final class FrameServer {
    static let port: UInt16 = 47831
    private static let allowedOrigin = "https://meet.google.com"

    /// Called on the server queue with the number of connected Meet tabs.
    var onClientCountChange: ((Int) -> Void)?

    private let queue = DispatchQueue(label: "VanishCam.frameServer", qos: .userInitiated)
    private let ciContext = CIContext()
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: NWConnection] = [:]
    private var pendingSends: Set<ObjectIdentifier> = []
    private var encoding = false

    func start() {
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        webSocket.setClientRequestHandler(queue) { _, headers in
            let origin = headers.first { $0.name.lowercased() == "origin" }?.value
            return NWProtocolWebSocket.Response(status: origin == Self.allowedOrigin ? .accept : .reject,
                                                subprotocol: nil)
        }

        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)

        do {
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    extLog.error("frame server failed: \(String(describing: error), privacy: .public)")
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            extLog.error("frame server could not start: \(String(describing: error), privacy: .public)")
        }
    }

    /// Called on the engine queue. Encodes only while a client is connected, and drops frames if busy.
    func push(_ buffer: CVPixelBuffer) {
        queue.async { [self] in
            guard !clients.isEmpty, !encoding else { return }
            encoding = true
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let image = CIImage(cvPixelBuffer: buffer)
                let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
                let options = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.85]
                let jpeg = ciContext.jpegRepresentation(of: image, colorSpace: colorSpace, options: options)
                queue.async { [self] in
                    encoding = false
                    if let jpeg { broadcast(jpeg) }
                }
            }
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                clients[id] = connection
                receive(on: connection)
                onClientCountChange?(clients.count)
            case .failed, .cancelled:
                remove(id, connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// Clients send nothing useful; reading is how a closed tab gets noticed.
    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] _, _, _, error in
            if error != nil {
                connection.cancel()
            } else {
                self?.receive(on: connection)
            }
        }
    }

    private func remove(_ id: ObjectIdentifier, _ connection: NWConnection) {
        pendingSends.remove(id)
        if clients.removeValue(forKey: id) != nil { onClientCountChange?(clients.count) }
    }

    private func broadcast(_ jpeg: Data) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
        for (id, connection) in clients where !pendingSends.contains(id) {
            pendingSends.insert(id)
            connection.send(content: jpeg, contentContext: context, isComplete: true,
                            completion: .contentProcessed { [weak self] _ in self?.pendingSends.remove(id) })
        }
    }
}
