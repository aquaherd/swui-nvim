// IntegrationTests.swift
// SWUINeovimTests — end-to-end integration tests using a real embedded Neovim.
//
// These tests spawn a `nvim --embed` process via LocalTransport and verify
// that the full stack (Transport → RPCChannel → NvimSession → GridState)
// functions end-to-end on a macOS CI machine.
//
// Precondition: `nvim` must be available on $PATH or at /usr/local/bin/nvim.
// Tests are skipped automatically when nvim is not found (XCTSkipUnless).
//
// Phase 1 tests will cover:
//   - Attach, receive initial grid_resize and flush.
//   - nvim_input sends a key and triggers a grid_line redraw.
//   - nvim_command ":q" causes NvimSession to transition to .disconnected.

import XCTest
@testable import SWUINeovim

// TODO(phase1): implement integration tests once LocalTransport is complete.
// TODO(phase1): add helper to locate `nvim` binary from PATH.
final class IntegrationTests: XCTestCase {
    // Placeholder — tests will be added during Phase 1 after LocalTransport lands.
}
