// NvimAPI.swift
// SWUINeovim — typed wrappers for the Neovim RPC API (`nvim_*`).
//
// Each function corresponds to a Neovim API method and is expressed as a
// Swift `async throws` call on top of `RPCChannel.request(method:params:)`.
//
// The full API surface will be filled in during Phase 1 as each feature is
// exercised; only the methods required by that phase are guaranteed to be
// present.
//
// Reference: https://neovim.io/doc/user/api.html

import Foundation
import NvimRPC
import MsgPack

// TODO(phase1): add nvim_ui_attach, nvim_ui_try_resize, nvim_subscribe.
// TODO(phase1): add nvim_input, nvim_input_mouse.
// TODO(phase1): add nvim_get_mode, nvim_get_option, nvim_set_option.
// TODO(phase1): auto-generate remaining wrappers from api_info msgpack schema.

/// Typed, async wrappers around `RPCChannel.request / notify`.
///
/// All methods are `nonisolated` so callers on any actor can invoke them
/// without actor-hopping overhead; the underlying `request` / `notify` calls
/// already hop to `RPCChannel`'s actor internally.
struct NvimAPI {

    let channel: RPCChannel

    // MARK: - UI

    /// Attach the UI and begin receiving `redraw` notifications.
    func uiAttach(width: Int, height: Int, options: [String: MsgPackValue] = [:]) async throws {
        // nvim_ui_attach(width, height, options) → no return value
        _ = try await channel.request(
            method: "nvim_ui_attach",
            params: [.uint(UInt64(width)), .uint(UInt64(height)),
                     .map(Dictionary(uniqueKeysWithValues: options.map { (.string($0.key), $0.value) }))])
    }

    /// Detach the UI.
    func uiDetach() async throws {
        _ = try await channel.request(method: "nvim_ui_detach", params: [])
    }

    /// Resize the grid.
    func uiTryResize(width: Int, height: Int) async throws {
        _ = try await channel.request(
            method: "nvim_ui_try_resize",
            params: [.uint(UInt64(width)), .uint(UInt64(height))])
    }

    // MARK: - Input

    /// Send a key-string to Neovim (e.g. `"a"`, `"<CR>"`, `"<C-c>"`).
    func input(_ keys: String) async throws -> Int {
        let result = try await channel.request(method: "nvim_input", params: [.string(keys)])
        guard case .uint(let n) = result else { return 0 }
        return Int(n)
    }

    // MARK: - Evaluation

    /// Evaluate a Vimscript expression and return the result.
    func eval(_ expr: String) async throws -> MsgPackValue {
        return try await channel.request(method: "nvim_eval", params: [.string(expr)])
    }

    /// Execute a Vimscript command.
    func command(_ cmd: String) async throws {
        _ = try await channel.request(method: "nvim_command", params: [.string(cmd)])
    }
}
