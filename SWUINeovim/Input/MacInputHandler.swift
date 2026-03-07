// MacInputHandler.swift
// SWUINeovim — macOS keyboard and mouse input handler.
//
// Translates NSEvent keyboard/mouse events into Neovim key strings and
// sends them through the active NvimSession.
//
// Phase 1 implementation note:
//   - Use KeyTranslator for key-name resolution.
//   - Forward modifier combos (⌘, ⌃, ⌥, ⇧) as <C-…>, <M-…> etc.
//   - Handle IME composition via NSTextInputClient.

#if os(macOS)
import AppKit

// TODO(phase1): implement NSTextInputClient for IME support.
// TODO(phase1): forward mouse events (click, drag, scroll) as Neovim mouse input.
@MainActor
final class MacInputHandler {
    private weak var session: NvimSession?

    init(session: NvimSession) {
        self.session = session
    }

    /// Translate and forward a keyDown event to Neovim.
    ///
    /// Returns `true` when the event is consumed by the handler.
    @discardableResult
    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let nvimKey = KeyTranslator.translate(event: event), !nvimKey.isEmpty else {
            return false
        }

        sendToSession(nvimKey)
        return true
    }

    /// Forward committed text from IME/input method pipelines.
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
