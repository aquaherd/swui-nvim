// IOSInputHandler.swift
// SWUINeovim — iPadOS keyboard and pointer input handler.
//
// Handles UIKit `UIKeyCommand`, Smart Keyboard / hardware keyboard events,
// and Pencil/pointer/touch input, forwarding them to the active NvimSession.
//
// Phase 1 implementation note:
//   - Register UIKeyCommand entries for common Neovim shortcuts so they appear
//     in the discoverability overlay (⌘K sheet).
//   - Forward text via UITextInput for IME compatibility.
//   - Map UIPointerInteraction events to Neovim mouse protocol.

#if os(iOS)
import UIKit

// TODO(phase1): implement UITextInput / UIKeyInput for IME on iPadOS.
// TODO(phase1): register UIKeyCommands for ⌘-key shortcuts.
// TODO(phase1): map UIPointerInteraction to Neovim mouse protocol.
@MainActor
final class IOSInputHandler {
    private weak var session: NvimSession?

    init(session: NvimSession) {
        self.session = session
    }

    /// Translate and forward a hardware keyboard key event to Neovim.
    @discardableResult
    func handleKey(_ key: UIKey) -> Bool {
        guard let nvimKey = KeyTranslator.translate(key: key), !nvimKey.isEmpty else {
            return false
        }

        sendToSession(nvimKey)
        return true
    }

    /// Forward committed text input (software keyboard / IME).
    @discardableResult
    func handleInsertedText(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        sendToSession(text)
        return true
    }

    private func sendToSession(_ keys: String) {
        guard let session else { return }

        Task {
            try? await session.input(keys)
        }
    }
}
#endif
