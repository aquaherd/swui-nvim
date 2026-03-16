import Foundation
import NvimRPC

/// Phase 1 local transport: spawns `nvim --embed` and exchanges raw msgpack bytes
/// over stdin/stdout.
actor LocalProcessRPCTransport: RPCTransport {
    private let nvimPath: String
    private let arguments: [String]
    private let workingDirectory: URL

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()

    private var isStarted = false
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?

    nonisolated let received: AsyncThrowingStream<Data, Error>

    init(
        nvimPath: String = SWUINeovimMacApp.resolvedNvimPath(),
        arguments: [String] = ["--embed", "--headless"]
    ) {
        self.nvimPath = nvimPath
        self.arguments = arguments
        self.workingDirectory = FileManager.default.homeDirectoryForCurrentUser

        var captured: AsyncThrowingStream<Data, Error>.Continuation?
        self.received = AsyncThrowingStream<Data, Error> { cont in
            captured = cont
        }
        self.continuation = captured
    }

    func start() async throws {
        guard !isStarted else { return }

        process.executableURL = URL(fileURLWithPath: nvimPath)
        process.arguments = arguments
        var env = Self.makeLaunchEnvironment(nvimPath: nvimPath)
        if (env["TERM"] ?? "").isEmpty {
            env["TERM"] = "xterm-256color"
        }
        if (env["COLORTERM"] ?? "").isEmpty {
            env["COLORTERM"] = "truecolor"
        }
        process.environment = env
        process.currentDirectoryURL = workingDirectory
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                Task { await self.finishStream() }
            } else {
                Task { await self.emit(data) }
            }
        }

        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            Task { await self.handleProcessTermination() }
        }

        try process.run()
        isStarted = true
    }

    func send(_ data: Data) async throws {
        guard isStarted, process.isRunning else {
            throw RPCError.transportClosed
        }

        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            throw RPCError.transportClosed
        }
    }

    func stop() async {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil

        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }

        finishStream()
        isStarted = false
    }

    private func emit(_ data: Data) {
        continuation?.yield(data)
    }

    private func finishStream() {
        continuation?.finish()
        continuation = nil
    }

    private func handleProcessTermination() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        isStarted = false
        finishStream()
    }

    private static func makeLaunchEnvironment(nvimPath: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if (env["HOME"] ?? "").isEmpty {
            env["HOME"] = home
        }

        let nvimBinDir = URL(fileURLWithPath: nvimPath).deletingLastPathComponent().path
        let fallbackEntries = [
            nvimBinDir,
            "/opt/local/bin",
            "/opt/local/sbin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]

        let existingEntries = (env["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)

        var mergedEntries: [String] = []
        var seen = Set<String>()
        for entry in existingEntries + fallbackEntries {
            guard !entry.isEmpty, !seen.contains(entry) else { continue }
            seen.insert(entry)
            mergedEntries.append(entry)
        }
        env["PATH"] = mergedEntries.joined(separator: ":")

        return env
    }
}
