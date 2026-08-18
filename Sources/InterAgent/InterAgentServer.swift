import Foundation
import Network
import OSLog

/// Local HTTP IPC Server
/// - Bind 127.0.0.1 dynamic port, only accept local connections (security constraints)
/// - Single route: POST /cli
/// - All omaestri CLI commands are routed through this service
final class InterAgentServer {
    static let shared = InterAgentServer()
    private let logger = Logger.make(category: "InterAgentServer")

    private var listener: NWListener?
    private(set) var port: UInt16 = 0

    // MARK: - Unix Socket support
    private var unixSocketFd: Int32 = -1
    private var unixSocketSource: DispatchSourceRead?

    /// Currently active Unix socket path (for SwiftTermProvider to inject MAESTRI_SOCKET)
    private(set) var currentSocketPath: String?

    /// Globally fixed socket path (no longer bound to workspace UUID to avoid old terminal CLI disconnection after switching workspaces)
    static var globalSocketPath: String {
        let runDir = PersistenceManager.shared.appDataURL
            .appendingPathComponent("run").path
        return "\(runDir)/agent.sock"
    }

    private init() {}

    // MARK: - Start

    /// Starts the TCP HTTP server on a dynamic port. Throws if the listener cannot be created.
    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(Constants.interAgentServerHost),
            port: .any
        )

        listener = try NWListener(using: params)

        // Use a semaphore to wait for the port to be ready to ensure that SwiftTermProvider can read the correct port
        let semaphore = DispatchSemaphore(value: 0)
        var startError: Error? = nil

        listener?.stateUpdateHandler = { [weak self] state in
            self?.handleStateChange(state)
            switch state {
            case .ready, .failed:
                semaphore.signal()
            default:
                break
            }
        }
        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        listener?.start(queue: .global(qos: .userInitiated))

        // Wait up to 2 seconds
        let result = semaphore.wait(timeout: .now() + 2.0)
        if result == .timedOut {
            logger.warning("InterAgentServer: timed out waiting for port assignment")
        }
        _ = startError
        logger.debug("InterAgentServer starting on \(Constants.interAgentServerHost):\(self.port)")
    }

    // MARK: - Unix Socket life cycle

    /// Start global Unix socket (only called once in application life cycle)
    /// No longer rebuilt with workspace switching, the terminal identifies its identity through X-Terminal-ID
    func startUnixSocketIfNeeded() {
        guard unixSocketFd < 0 else { return }  // Already running
        do {
            try startUnixSocket()
        } catch {
            logger.error("InterAgentServer: Unix socket start failed: \(error)")
        }
    }

    private func startUnixSocket() throws {
        let path = Self.globalSocketPath
        currentSocketPath = path

        // Create run/ directory
        let runDir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: runDir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        // Clean up old socket files (anti-crash residue)
        unlink(path)

        // Create Unix socket
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "InterAgentServer", code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "socket() failed: \(String(cString: strerror(errno)))"])
        }
        unixSocketFd = fd

        // Binding
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8.prefix(103)
        withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
            pathBytes.enumerated().forEach { ptr[$0.offset] = $0.element }
        }
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw NSError(domain: "InterAgentServer", code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "bind() failed: \(String(cString: strerror(errno)))"])
        }

        // Monitoring
        guard listen(fd, 10) == 0 else {
            close(fd)
            throw NSError(domain: "InterAgentServer", code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "listen() failed"])
        }

        // DispatchSource accept loop
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
        source.setEventHandler { [weak self] in
            self?.acceptUnixConnection(serverFd: fd)
        }
        source.resume()
        unixSocketSource = source
        logger.info("InterAgentServer Unix socket ready at \(path)")
    }

    private func stopUnixSocket() {
        unixSocketSource?.cancel()
        unixSocketSource = nil
        if unixSocketFd >= 0 {
            close(unixSocketFd)
            unixSocketFd = -1
        }
        if let path = currentSocketPath {
            unlink(path)
        }
        currentSocketPath = nil
    }

    private func acceptUnixConnection(serverFd: Int32) {
        let clientFd = accept(serverFd, nil, nil)
        guard clientFd >= 0 else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.handleUnixClient(fd: clientFd)
        }
    }

    private func handleUnixClient(fd: Int32) {
        var accumulated = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        // Receive full HTTP request (blocking recv remains on DispatchQueue thread)
        while true {
            let n = recv(fd, &buffer, buffer.count, 0)
            guard n > 0 else { break }
            accumulated.append(contentsOf: buffer[..<n])
            // Check HTTP request for completeness
            if let headerEnd = accumulated.range(of: Data("\r\n\r\n".utf8)) {
                let headerStr = String(decoding: accumulated[..<headerEnd.upperBound], as: UTF8.self)
                let contentLength = Self.parseContentLength(from: headerStr)
                let bodyReceived = accumulated.count - headerEnd.upperBound
                if contentLength <= 0 || bodyReceived >= contentLength { break }
            }
        }
        guard !accumulated.isEmpty else { return }
        // After reading is completed, enter the async context routing command and no longer block the GCD thread
        Task { [weak self, fd] in
            if let self {
                let parsed = await self.parseHTTPRequest(accumulated)
                let responseData = self.buildHTTPResponse(body: parsed.responseBody, httpVersion: parsed.httpVersion)
                responseData.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
            }
            close(fd)
        }
    }

    /// Gracefully shuts down the TCP listener and cancels all in-flight connections.
    func stop() {
        // Cancel the listener first to prevent new connections from entering.
        listener?.cancel()
        listener = nil
        stopUnixSocket()
        port = 0
        logger.debug("InterAgentServer stopped")
    }

    // MARK: - Status processing

    private func handleStateChange(_ state: NWListener.State) {
        switch state {
        case .ready:
            port = listener?.port?.rawValue ?? 0
            restartCount = 0  // Reset backoff count after success
            logger.info("InterAgentServer ready on port \(self.port)")
        case .failed(let error):
            logger.error("InterAgentServer failed: \(error)")
            scheduleRestart()
        default:
            break
        }
    }

    private var restartCount = 0
    private let maxRestarts = 5

    private func scheduleRestart() {
        guard restartCount < maxRestarts else {
            logger.error("InterAgentServer: max restart attempts (\(self.maxRestarts)) reached, giving up")
            return
        }
        // Exponential backoff: 3s, 6s, 12s, 24s, 48s
        let delay = Constants.serverRestartDelay * pow(2.0, Double(restartCount))
        restartCount += 1
        logger.warning("InterAgentServer restarting in \(Int(delay))s (attempt \(self.restartCount)/\(self.maxRestarts))")
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            try? self?.start()
        }
    }

    // MARK: - Connection handling (HTTP POST /cli)

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        receiveRequest(on: connection)
    }

    private func receiveRequest(on connection: NWConnection) {
        // Chunked cumulative reception, maximum 1MB (supports large portal evaluate command)
        receiveData(on: connection, accumulated: Data())
    }

    private func receiveData(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 262144) { [weak self] data, _, isComplete, error in
            guard error == nil else { connection.cancel(); return }
            let total = accumulated + (data ?? Data())
            // Check whether HTTP request is complete (find header/body delimiter)
            if let headerEnd = total.range(of: Data("\r\n\r\n".utf8)) {
                // Parse Content-Length to decide whether to continue reading
                let headerData = total[..<headerEnd.upperBound]
                let headerStr = String(decoding: headerData, as: UTF8.self)
                let bodyStart = headerEnd.upperBound
                let contentLength = Self.parseContentLength(from: headerStr)
                let bodyReceived = total.count - bodyStart
                if contentLength <= 0 || bodyReceived >= contentLength {
                    // Request complete - entering async context routing command
                    Task { [weak self] in
                        guard let self else { connection.cancel(); return }
                        let parsed = await self.parseHTTPRequest(total)
                        let responseData = self.buildHTTPResponse(body: parsed.responseBody, httpVersion: parsed.httpVersion)
                        connection.send(content: responseData, completion: .idempotent)
                        connection.cancel()
                    }
                    return
                }
            }
            // The request is incomplete, continue reading
            if !isComplete {
                self?.receiveData(on: connection, accumulated: total)
            } else {
                // Connection closed prematurely
                Task { [weak self] in
                    guard let self else { connection.cancel(); return }
                    let parsed = await self.parseHTTPRequest(total)
                    let responseData = self.buildHTTPResponse(body: parsed.responseBody, httpVersion: parsed.httpVersion)
                    connection.send(content: responseData, completion: .idempotent)
                    connection.cancel()
                }
            }
        }
    }

    private static func parseContentLength(from headers: String) -> Int {
        for line in headers.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let val = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                return Int(val) ?? 0
            }
        }
        return 0
    }

    /// Parsing result: response body + requested HTTP version
    private struct ParsedRequest {
        let responseBody: String
        let httpVersion: String  // "1.0" or "1.1"
    }

    private func parseHTTPRequest(_ data: Data) async -> ParsedRequest {
        // Parse HTTP request, extract JSON body, X-Terminal-ID header and HTTP version
        let raw = String(decoding: data, as: UTF8.self)
        var terminalId: UUID?
        var args: [String] = []
        var httpVersion = "1.1"  // Default HTTP/1.1 (common for TCP channels)

        // Simple parsing: find the JSON body after the empty line
        let parts = raw.components(separatedBy: "\r\n\r\n")
        let headers = parts[0]
        let body = parts.count > 1 ? parts[1] : ""

        // Extract HTTP version from request line (e.g. "POST /cli HTTP/1.0")
        let headerLines = headers.components(separatedBy: "\r\n")
        if let requestLine = headerLines.first {
            if requestLine.contains("HTTP/1.0") {
                httpVersion = "1.0"
            } else if requestLine.contains("HTTP/1.1") {
                httpVersion = "1.1"
            }
        }

        // Extract X-Terminal-ID
        for line in headerLines {
            let lower = line.lowercased()
            if lower.hasPrefix("x-terminal-id:") {
                let idStr = line.dropFirst("x-terminal-id:".count).trimmingCharacters(in: .whitespaces)
                terminalId = UUID(uuidString: idStr)
            }
        }

        // Parsing JSON args
        if let bodyData = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
           let rawArgs = json["args"] as? [String] {
            args = rawArgs
        }

        guard !args.isEmpty else {
            return ParsedRequest(responseBody: "error: missing args", httpVersion: httpVersion)
        }
        let responseBody = await CLIRouter.shared.routeAsync(args: args, terminalId: terminalId)
        return ParsedRequest(responseBody: responseBody, httpVersion: httpVersion)
    }

    private func buildHTTPResponse(body: String, httpVersion: String = "1.1") -> Data {
        let bodyData = body.data(using: .utf8) ?? Data()
        // Return the HTTP version matching the request (HTTP/1.0 for CLI, HTTP/1.1 for SSH/curl)
        let header = "HTTP/\(httpVersion) 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        return (header.data(using: .utf8) ?? Data()) + bodyData
    }
}
