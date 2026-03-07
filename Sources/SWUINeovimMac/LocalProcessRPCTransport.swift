import Foundation
import NvimRPC

/// Phase 1 local transport: spawns `nvim --embed` and exchanges raw msgpack bytes
/// over stdin/stdout.
actor LocalProcessRPCTransport: RPCTransport {
    private let nvimPath: String
    private let arguments: [String]

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()

    private var isStarted = false
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?

    nonisolated let received: AsyncThrowingStream<Data, Error>

    init(
        nvimPath: String = "/opt/local/bin/nvim",
        arguments: [String] = ["--embed", "--headless", "-u", "NONE", "-n"]
    ) {
        self.nvimPath = nvimPath
        self.arguments = arguments

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
            Task { await self.finishStream() }
        }

        try process.run()
        isStarted = true
    }

    func send(_ data: Data) async throws {
        guard isStarted else {
            throw RPCError.transportClosed
        }

        stdinPipe.fileHandleForWriting.write(data)
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
}
