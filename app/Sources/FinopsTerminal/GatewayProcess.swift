import Darwin
import Foundation

/// Launches the Python gateway sidecar on a free localhost port and stops it on quit.
@MainActor
final class GatewayProcess {
    struct LaunchError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private var process: Process?

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "finops-terminal", directoryHint: .isDirectory)
    }

    static var logURL: URL { supportDirectory.appending(path: "gateway.log") }

    /// Starts the sidecar and returns its WebSocket URL once it answers /health.
    func start() async throws -> URL {
        let uv = try Self.locateUV()
        let gatewayDir = Self.locateGateway()
        guard FileManager.default.fileExists(atPath: gatewayDir.appending(path: "pyproject.toml").path) else {
            throw LaunchError("Gateway not found at \(gatewayDir.path). Set FINOPS_GATEWAY_DIR.")
        }

        let port = try Self.freePort()
        let token = UUID().uuidString

        try FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: Self.logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: Self.logURL)

        let process = Process()
        process.executableURL = uv
        process.currentDirectoryURL = gatewayDir
        process.arguments = [
            "run", "--project", gatewayDir.path, "finops-gateway",
            "--port", String(port), "--token", token, "--parent-pid", String(getpid()),
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["FINOPS_CACHE_DIR"] = Self.supportDirectory.path
        process.environment = environment
        process.standardOutput = log
        process.standardError = log
        try process.run()
        self.process = process

        let health = URL(string: "http://127.0.0.1:\(port)/health")!
        let deadline = Date.now.addingTimeInterval(180)
        while Date.now < deadline {
            guard process.isRunning else {
                throw LaunchError("Gateway exited (status \(process.terminationStatus)).\n\(Self.logTail())")
            }
            if let (_, response) = try? await URLSession.shared.data(from: health),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                return URL(string: "ws://127.0.0.1:\(port)/ws?token=\(token)")!
            }
            try await Task.sleep(for: .milliseconds(400))
        }
        stop()
        throw LaunchError("Gateway didn't become ready in time.\n\(Self.logTail())")
    }

    func stop() {
        guard let process, process.isRunning else { return }
        process.terminate()
        self.process = nil
    }

    // MARK: Helpers

    private static func locateUV() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [ProcessInfo.processInfo.environment["FINOPS_UV"]].compactMap { $0 } + [
            "\(home)/.local/bin/uv", "/opt/homebrew/bin/uv", "/usr/local/bin/uv", "\(home)/.cargo/bin/uv",
        ]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw LaunchError("uv not found. Install it (https://docs.astral.sh/uv/) or set FINOPS_UV.")
        }
        return URL(fileURLWithPath: path)
    }

    /// FINOPS_GATEWAY_DIR, or `<repo>/gateway` relative to this source file (development builds).
    private static func locateGateway() -> URL {
        if let dir = ProcessInfo.processInfo.environment["FINOPS_GATEWAY_DIR"] {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // FinopsTerminal
            .deletingLastPathComponent()  // Sources
            .deletingLastPathComponent()  // app
            .deletingLastPathComponent()  // repo root
            .appending(path: "gateway", directoryHint: .isDirectory)
    }

    private static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LaunchError("socket() failed") }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)

        let bound = withUnsafeMutablePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, length) == 0 && getsockname(fd, sa, &length) == 0
            }
        }
        guard bound else { throw LaunchError("Couldn't find a free port") }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    private static func logTail() -> String {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return "" }
        return text.split(separator: "\n").suffix(15).joined(separator: "\n")
    }
}
