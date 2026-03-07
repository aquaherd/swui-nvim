import Foundation
import Observation
import MsgPack
import NvimRPC

@MainActor
@Observable
final class Phase1SessionController {
    enum ConnectionState: String {
        case disconnected
        case connecting
        case attached
        case failed
    }

    var state: ConnectionState = .disconnected
    var statusMessage: String = "Idle"
    var nvimPath: String = "/opt/local/bin/nvim"
    var redrawEventCount: Int = 0

    private var channel: RPCChannel?
    private var notificationTask: Task<Void, Never>?

    func connectLocal() {
        guard state == .disconnected else { return }

        state = .connecting
        statusMessage = "Starting local nvim --embed…"

        let transport = LocalProcessRPCTransport(nvimPath: nvimPath)
        let channel = RPCChannel(transport: transport)
        self.channel = channel

        Task {
            do {
                try await channel.start()
                try await attachUI(channel: channel)
                startNotificationLoop(channel: channel)
                await MainActor.run {
                    self.state = .attached
                    self.statusMessage = "Attached via local transport"
                }
            } catch {
                await MainActor.run {
                    self.state = .failed
                    self.statusMessage = "Connect failed: \(error)"
                }
            }
        }
    }

    func disconnect() {
        notificationTask?.cancel()
        notificationTask = nil

        let channel = self.channel
        self.channel = nil

        Task {
            await channel?.stop()
            await MainActor.run {
                self.state = .disconnected
                self.statusMessage = "Disconnected"
            }
        }
    }

    func sendInput(_ keys: String) {
        guard let channel else { return }
        Task {
            _ = try? await channel.request(method: "nvim_input", params: [.string(keys)])
        }
    }

    func save() {
        runCommand("write", success: "Saved current buffer")
    }

    func save(as path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusMessage = "Save As path is empty"
            return
        }

        let escaped = trimmed.replacingOccurrences(of: "\\", with: "\\\\")
        runCommand("write \(escaped)", success: "Saved to \(trimmed)")
    }

    private func runCommand(_ command: String, success: String) {
        guard let channel else {
            statusMessage = "Not connected"
            return
        }

        Task {
            do {
                _ = try await channel.request(method: "nvim_command", params: [.string(command)])
                await MainActor.run {
                    self.statusMessage = success
                }
            } catch {
                await MainActor.run {
                    self.statusMessage = "Command failed: \(error)"
                }
            }
        }
    }

    private func attachUI(channel: RPCChannel) async throws {
        let options: MsgPackValue = .map([
            .string("ext_linegrid"): .bool(true),
            .string("ext_multigrid"): .bool(true),
            .string("ext_popupmenu"): .bool(true),
            .string("ext_cmdline"): .bool(true),
            .string("ext_messages"): .bool(true),
            .string("rgb"): .bool(true),
        ])

        _ = try await channel.request(
            method: "nvim_ui_attach",
            params: [
                .int(120),
                .int(36),
                options,
            ]
        )
    }

    private func startNotificationLoop(channel: RPCChannel) {
        notificationTask = Task {
            let stream = await channel.notifications
            for await message in stream {
                guard case .notification(let method, _) = message else { continue }
                if method == "redraw" {
                    await MainActor.run {
                        self.redrawEventCount += 1
                    }
                }
            }
        }
    }
}
