// GridStateTests.swift
// SWUINeovimTests — unit tests for GridState redraw processing.
//
// Phase 1 / 3 tests will verify:
//   - grid_resize creates / trims cell storage.
//   - grid_line correctly populates cells (text, hl_id, repeat).
//   - grid_scroll shifts rows without overflowing bounds.
//   - hl_attr_define stores highlight attributes and they survive grid_clear.

import XCTest
@testable import SWUINeovim

// TODO(phase1): add tests for grid_resize, grid_line, grid_scroll, grid_clear.
// TODO(phase1): add tests for highlight table integration (foreground/background colours).
// TODO(phase3): add tests for multi-grid (ext_multigrid) merging.
final class GridStateTests: XCTestCase {
    // Placeholder — tests will be added as GridState is fleshed out in Phase 1.
}
