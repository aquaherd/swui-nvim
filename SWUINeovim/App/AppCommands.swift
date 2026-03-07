// AppCommands.swift
// SWUINeovim
//
// macOS menu bar commands that forward actions to the active Neovim session.
// Provides standard Edit, View, Window, and File menu items that translate
// to Neovim commands or keystrokes via the session actor.

import SwiftUI

// MARK: - App Commands

/// The complete set of custom menu bar commands for SWUINeovim.
struct SWUINeovimCommands: Commands {
    @FocusedObject private var session: NvimSession?

    var body: some Commands {
        // Replace the default New Window command
        CommandGroup(replacing: .newItem) {
            Button("New Window") {
                NotificationCenter.default.post(name: .newNvimWindow, object: nil)
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("New Tab") {
                Task {
                    try? await session?.command("tabnew")
                }
            }
            .keyboardShortcut("t", modifiers: .command)

            Divider()

            Button("Open…") {
                Task {
                    try? await session?.command("browse confirm edit")
                }
            }
            .keyboardShortcut("o", modifiers: .command)
        }

        // File menu additions
        CommandGroup(after: .newItem) {
            Button("Save") {
                Task {
                    try? await session?.command("write")
                }
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(session == nil)

            Button("Save As…") {
                Task {
                    try? await session?.command("browse confirm saveas")
                }
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(session == nil)

            Button("Save All") {
                Task {
                    try? await session?.command("wall")
                }
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .disabled(session == nil)

            Divider()

            Button("Close Tab") {
                Task {
                    try? await session?.command("tabclose")
                }
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(session == nil)
        }

        // Edit menu — forward undo/redo and clipboard to Neovim
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") {
                Task {
                    try? await session?.input("u")
                }
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(session == nil)

            Button("Redo") {
                Task {
                    try? await session?.input("<C-r>")
                }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(session == nil)
        }

        CommandGroup(replacing: .pasteboard) {
            Button("Cut") {
                Task {
                    try? await session?.input("\"+x")
                }
            }
            .keyboardShortcut("x", modifiers: .command)
            .disabled(session == nil)

            Button("Copy") {
                Task {
                    try? await session?.input("\"+y")
                }
            }
            .keyboardShortcut("c", modifiers: .command)
            .disabled(session == nil)

            Button("Paste") {
                Task {
                    try? await session?.input("\"+gP")
                }
            }
            .keyboardShortcut("v", modifiers: .command)
            .disabled(session == nil)

            Button("Select All") {
                Task {
                    try? await session?.input("ggVG")
                }
            }
            .keyboardShortcut("a", modifiers: .command)
            .disabled(session == nil)
        }

        // Find / Replace
        CommandGroup(replacing: .textEditing) {
            Button("Find…") {
                Task {
                    try? await session?.input("/")
                }
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(session == nil)

            Button("Find and Replace…") {
                Task {
                    try? await session?.input(":%s/")
                }
            }
            .keyboardShortcut("h", modifiers: [.command, .option])
            .disabled(session == nil)

            Button("Find Next") {
                Task {
                    try? await session?.input("n")
                }
            }
            .keyboardShortcut("g", modifiers: .command)
            .disabled(session == nil)

            Button("Find Previous") {
                Task {
                    try? await session?.input("N")
                }
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(session == nil)
        }

        // View menu
        ViewCommands()

        // Font size commands
        CommandGroup(after: .textFormatting) {
            Button("Increase Font Size") {
                NotificationCenter.default.post(name: .increaseFontSize, object: nil)
            }
            .keyboardShortcut("+", modifiers: .command)

            Button("Decrease Font Size") {
                NotificationCenter.default.post(name: .decreaseFontSize, object: nil)
            }
            .keyboardShortcut("-", modifiers: .command)

            Button("Reset Font Size") {
                NotificationCenter.default.post(name: .resetFontSize, object: nil)
            }
            .keyboardShortcut("0", modifiers: .command)
        }

        // Window split commands
        NvimWindowCommands()

        // Help menu
        CommandGroup(replacing: .help) {
            Button("Neovim Help") {
                Task {
                    try? await session?.command("help")
                }
            }
            .disabled(session == nil)

            Button("SWUINeovim Help") {
                if let url = URL(string: "https://github.com/aquaherd/swuinvim") {
                    #if os(macOS)
                    NSWorkspace.shared.open(url)
                    #endif
                }
            }
        }
    }
}

// MARK: - Window Split / Navigation Commands

/// Commands for Neovim window splits and navigation.
struct NvimWindowCommands: Commands {
    @FocusedObject private var session: NvimSession?

    var body: some Commands {
        CommandMenu("Neovim") {
            // Splits
            Section("Splits") {
                Button("Split Horizontally") {
                    Task {
                        try? await session?.command("split")
                    }
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(session == nil)

                Button("Split Vertically") {
                    Task {
                        try? await session?.command("vsplit")
                    }
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(session == nil)

                Button("Close Split") {
                    Task {
                        try? await session?.command("close")
                    }
                }
                .disabled(session == nil)

                Button("Only This Split") {
                    Task {
                        try? await session?.command("only")
                    }
                }
                .disabled(session == nil)
            }

            Divider()

            // Navigation between splits
            Section("Navigate") {
                Button("Move to Left Split") {
                    Task {
                        try? await session?.input("<C-w>h")
                    }
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(session == nil)

                Button("Move to Right Split") {
                    Task {
                        try? await session?.input("<C-w>l")
                    }
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(session == nil)

                Button("Move to Upper Split") {
                    Task {
                        try? await session?.input("<C-w>k")
                    }
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(session == nil)

                Button("Move to Lower Split") {
                    Task {
                        try? await session?.input("<C-w>j")
                    }
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(session == nil)
            }

            Divider()

            // Tab navigation
            Section("Tabs") {
                Button("Next Tab") {
                    Task {
                        try? await session?.command("tabnext")
                    }
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
                .disabled(session == nil)

                Button("Previous Tab") {
                    Task {
                        try? await session?.command("tabprevious")
                    }
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
                .disabled(session == nil)
            }

            Divider()

            // Buffer navigation
            Section("Buffers") {
                Button("Next Buffer") {
                    Task {
                        try? await session?.command("bnext")
                    }
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(session == nil)

                Button("Previous Buffer") {
                    Task {
                        try? await session?.command("bprevious")
                    }
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(session == nil)

                Button("List Buffers") {
                    Task {
                        try? await session?.command("ls")
                    }
                }
                .disabled(session == nil)
            }

            Divider()

            // Terminal
            Section("Terminal") {
                Button("Open Terminal") {
                    Task {
                        try? await session?.command("terminal")
                    }
                }
                .keyboardShortcut("`", modifiers: .control)
                .disabled(session == nil)
            }

            Divider()

            // Command palette (Neovim command line)
            Button("Command Palette…") {
                Task {
                    try? await session?.input(":")
                }
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(session == nil)
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when the user requests a new Neovim window (Cmd+N).
    static let newNvimWindow = Notification.Name("com.swuinvim.newNvimWindow")

    /// Posted when the user requests a font size increase (Cmd++).
    static let increaseFontSize = Notification.Name("com.swuinvim.increaseFontSize")

    /// Posted when the user requests a font size decrease (Cmd+-).
    static let decreaseFontSize = Notification.Name("com.swuinvim.decreaseFontSize")

    /// Posted when the user requests a font size reset (Cmd+0).
    static let resetFontSize = Notification.Name("com.swuinvim.resetFontSize")

    /// Posted when the user requests toggling the sidebar.
    static let toggleSidebar = Notification.Name("com.swuinvim.toggleSidebar")
}

// MARK: - FocusedValues Extension

/// Provides the active NvimSession to the focused-value system so that
/// menu commands can access the currently focused editor's session.
struct FocusedNvimSessionKey: FocusedValueKey {
    typealias Value = NvimSession
}

extension FocusedValues {
    var nvimSession: NvimSession? {
        get { self[FocusedNvimSessionKey.self] }
        set { self[FocusedNvimSessionKey.self] = newValue }
    }
}