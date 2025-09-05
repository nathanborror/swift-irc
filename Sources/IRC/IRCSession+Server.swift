import Foundation
import OSLog
import Network

private let logger = Logger(subsystem: "IRCServerSession", category: "IRC")

@MainActor
@Observable
public class IRCSessionServer: IRCSession {

    public var server: Server
    public var registry = WaitRegistry()
    public var buffer = ""
    public var isConnected = false
    public var isAuthenticated = false
    public var isRegistered = false
    public var error: IRCSessionError? = nil

    private var connection: NWConnection? = nil
    private var connectionQueue = DispatchQueue(label: "irc.wire", qos: .userInitiated)
    private var incomingDataBuffer = ""
    private var motdBuffer = ""

    public init(_ server: Server) {
        self.server = server
    }

    public func connect() async throws {
        clearLogs()

        let host = server.config.server
        let port = NWEndpoint.Port(integerLiteral: server.config.port)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true

        let params: NWParameters
        if server.config.useTLS {
            let tls = handleTLS(host)
            params = NWParameters(tls: tls, tcp: tcp)
        } else {
            params = NWParameters(tls: nil, tcp: tcp)
        }

        let endpoint = NWEndpoint.hostPort(host: .init(host), port: port)
        connection = NWConnection(to: endpoint, using: params)
        connection?.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task {
                do {
                    try await handleStateUpdate(state: state)
                } catch {
                    print(error)
                }
            }
        }
        connection?.start(queue: connectionQueue)
    }

    public func disconnect() async throws {
        connection?.cancel()
        connection = nil
        isConnected = false
        await registry.cancelAll(IRCSessionError.disconnected)
    }

    public func send(_ line: String) async throws {
        guard let connection, let data = "\(line)\r\n".data(using: .utf8) else {
            throw IRCSessionError.unhandled(EncodingError.invalidValue(line, .init(codingPath: [], debugDescription: "utf8")))
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed({ error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }))
        }
    }

    // Private

    private func handleTLS(_ host: String) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(options.securityProtocolOptions, host)
        sec_protocol_options_set_peer_authentication_required(options.securityProtocolOptions, true)
        sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv12)
        return options
    }

    private func handleStateUpdate(state: NWConnection.State) async throws {
        switch state {
        case .ready:
            isConnected = true
            await handleListen()
        case .failed(let error):
            self.error = .unhandled(error)
            await registry.cancelAll(error)
            try await disconnect()
        case .cancelled:
            await registry.cancelAll(IRCSessionError.cancelled)
            try await disconnect()
        case .preparing:
            logger.info("preparing")
        default:
            break
        }
    }

    private func handleListen() async {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self else { return }
            Task {
                do {
                    try await self.processIncomingData(data)
                } catch {
                    print(error)
                }
                if error == nil {
                    await self.handleListen()
                }
            }
        }
    }
}
