// LocalTransport.swift
// Transport
//
// Spawns a local `nvim --embed` process and communicates over stdio pipes.

#if os(macOS)

import Foundation

/// A transport that spawns a local Neovim process with `--embed`
/// and communicates via stdin/stdout pipes.
///
/// This transport is only available on macOS — iPadOS cannot spawn
/// child processes.
public final class LocalTransport: NvimTransport, @unchecked Sendable {
    /// Path to the `nvim` binary. Defaults to `/opt/homebrew/bin/nvim`.
    public let nvimPath: String

    /// Additional arguments passed to `nvim` (after `--embed`).
    public let extraArguments: [String]

    /// Environment variables to pass to the child process.
    /// If `nil`, inherits the current process environment.
    public let environment: [String: String]?

    /// Working directory for the nvim process. If `nil`, inherits the current directory.
    public let workingDirectory: URL?

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()

    private var receivedContinuation: AsyncThrowingStream<Data, Error>.Continuation?
    private let _received: AsyncThrowingStream<Data, Error>

    private let lock = NSLock()
    private var _isRunning = false

    public var isRunning: Bool {
        lock.withLock { _isRunning }
    }

    public var received: AsyncThrowingStream<Data, Error> {
        _received
    }

    /// Creates a new local transport.
    ///
    /// - Parameters:
    ///   - nvimPath: Path to the `nvim` executable.
    ///   - extraArguments: Additional command-line arguments for nvim.
    ///   - environment: Environment variables for the child process.
    ///   - workingDirectory: Working directory for the nvim process.
    public init(
        nvimPath: String = "/opt/homebrew/bin/nvim",
        extraArguments: [String] = [],
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil
    ) {
        self.nvimPath = nvimPath
        self.extraArguments = extraArguments
        self.environment = environment
        self.workingDirectory = workingDirectory

        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        self._received = AsyncThrowingStream { cont in
            continuation = cont
        }
        self.receivedContinuation = continuation
    }

    // MARK: - NvimTransport

    public func start() async throws {
        process.executableURL = URL(fileURLWithPath: nvimPath)
        process.arguments = ["--embed"] + extraArguments

        if let environment {
            process.environment = environment
        }

        if let workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }

        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Read stdout data from nvim and yield into the async stream
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                // EOF — nvim closed stdout
                self?.receivedContinuation?.finish()
                return
            }
            self?.receivedContinuation?.yield(data)
        }

        // Read stderr and log it (but don't forward to the RPC stream)
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                // In a production app you might route this to a log view.
                NSLog("[nvim stderr] %@", text)
            }
        }

        // Handle process termination
        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            let status = proc.terminationStatus
            let reason = proc.terminationReason

            self.lock.withLock { self._isRunning = false }

            if reason == .uncaughtSignal || status != 0 {
                self.receivedContinuation?.finish(
                    throwing: LocalTransportError.processExited(
                        status: status,
                        reason: reason
                    )
                )
            } else {
                self.receivedContinuation?.finish()
            }
        }

        do {
            try process.run()
            lock.withLock { _isRunning = true }
        } catch {
            receivedContinuation?.finish(throwing: error)
            throw LocalTransportError.failedToLaunch(underlying: error)
        }
    }

    public func send(_ data: Data) async throws {
        guard isRunning else {
            throw LocalTransportError.notRunning
        }

        let fileHandle = stdinPipe.fileHandleForWriting

        // Write on a background queue to avoid blocking the caller.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try fileHandle.write(contentsOf: data)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: LocalTransportError.writeFailed(underlying: error))
                }
            }
        }
    }

    public func stop() async {
        guard isRunning else { return }

        // Close stdin so nvim receives EOF and exits gracefully
        try? stdinPipe.fileHandleForWriting.close()

        // Give nvim a moment to exit on its own
        let exitedGracefully = await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self else {
                    continuation.resume(returning: true)
                    return
                }
                continuation.resume(returning: !self.process.isRunning)
            }
        }

        if !exitedGracefully && process.isRunning {
            process.terminate()

            // If it still won't die after another second, SIGKILL
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, self.process.isRunning else { return }
                self.process.interrupt() // sends SIGINT; on macOS this is typically enough
            }
        }

        lock.withLock { _isRunning = false }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        receivedContinuation?.finish()
    }

    deinit {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
        }
    }
}

// MARK: - Errors

/// Errors specific to the local (process-based) transport.
public enum LocalTransportError: Error, CustomStringConvertible, Sendable {
    /// The nvim binary could not be launched.
    case failedToLaunch(underlying: Error)

    /// The transport is not running; call `start()` first.
    case notRunning

    /// Writing to the nvim process's stdin failed.
    case writeFailed(underlying: Error)

    /// The nvim process exited unexpectedly.
    case processExited(status: Int32, reason: Process.TerminationReason)

    public var description: String {
        switch self {
        case .failedToLaunch(let err):
            return "LocalTransport: failed to launch nvim — \(err.localizedDescription)"
        case .notRunning:
            return "LocalTransport: process is not running"
        case .writeFailed(let err):
            return "LocalTransport: write failed — \(err.localizedDescription)"
        case .processExited(let status, let reason):
            return "LocalTransport: nvim exited (status: \(status), reason: \(reason))"
        }
    }
}

#endif