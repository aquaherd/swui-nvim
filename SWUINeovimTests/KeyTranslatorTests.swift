// KeyTranslatorTests.swift
// SWUINeovimTests — unit tests for KeyTranslator platform event → Neovim key string.
//
// Phase 1 tests will verify:
//   - Plain printable characters pass through unchanged.
//   - Special keys (Return, Escape, Tab, Backspace, arrows, F-keys) map to
//     the correct Neovim bracket notation (<CR>, <Esc>, <Tab>, <BS>, <Up>, <F1>…).
//   - Modifier combos produce correct prefixes: <C-a>, <M-a>, <S-F1>, <D-a> (⌘).
//   - IME composed characters are forwarded verbatim.

import XCTest
@testable import SWUINeovim

// TODO(phase1): add tests for special-key mapping table.
// TODO(phase1): add tests for modifier-prefix generation per platform.
// TODO(phase1): add tests for IME composed-character forwarding.
final class KeyTranslatorTests: XCTestCase {
    // Placeholder — tests will be added during Phase 1 InputHandler work.
}
