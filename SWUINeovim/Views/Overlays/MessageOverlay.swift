// MessageOverlay.swift
// SWUINeovim
//
// SwiftUI overlay for displaying Neovim messages (ext_messages).
// Renders msg_show / msg_clear events as notification-style banners
// anchored to the bottom of the editor surface.

import SwiftUI

// MARK: - MessageOverlay

/// Displays Neovim messages as a stack of notification banners at the
/// bottom of the editor view.
///
/// Messages are driven by the `NvimSession`'s published `messages` array.
/// Each message entry includes styled text chunks with highlight IDs,
/// a kind (e.g. "emsg" for errors, "wmsg" for warnings, "" for normal),
/// and a `replaceLast` flag for progressive output.
///
/// The overlay auto-dismisses informational messages after a timeout,
/// while errors and prompts persist until explicitly cleared by Neovim.
struct MessageOverlay: View {
    /// The messages to display, sourced from `NvimSession.messages`.
    let messages: [MessageEntry]

    /// Callback to resolve a highlight ID to foreground/background colors.
    /// Returns `(foreground: Color, background: Color)`.
    var resolveHighlight: ((Int) -> (foreground: Color, background: Color))?

    /// The default foreground color when no highlight is resolved.
    var defaultForeground: Color = .white

    /// The default background color when no highlight is resolved.
    var defaultBackground: Color = .black

    /// Maximum number of messages to display simultaneously.
    var maxVisibleMessages: Int = 5

    /// Whether to animate message appearance/disappearance.
    var animateTransitions: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(visibleMessages) { entry in
                MessageBanner(
                    entry: entry,
                    resolveHighlight: resolveHighlight,
                    defaultForeground: defaultForeground,
                    defaultBackground: defaultBackground
                )
                .transition(
                    animateTransitions
                        ? .asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .opacity
                        )
                        : .identity
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .animation(animateTransitions ? .easeInOut(duration: 0.2) : nil, value: messages.count)
    }

    /// The subset of messages to show, capped at `maxVisibleMessages`.
    /// Shows the most recent messages.
    private var visibleMessages: [MessageEntry] {
        if messages.count <= maxVisibleMessages {
            return messages
        }
        return Array(messages.suffix(maxVisibleMessages))
    }
}

// MARK: - MessageBanner

/// A single message banner displaying one `MessageEntry`.
struct MessageBanner: View {
    let entry: MessageEntry
    var resolveHighlight: ((Int) -> (foreground: Color, background: Color))?
    var defaultForeground: Color = .white
    var defaultBackground: Color = .black

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Kind icon
            if let icon = iconForKind(entry.kind) {
                Image(systemName: icon)
                    .foregroundStyle(colorForKind(entry.kind))
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 18, alignment: .center)
                    .padding(.top, 2)
            }

            // Message content
            messageText
                .font(.system(size: 13, design: .monospaced))
                .lineLimit(nil)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(backgroundForKind(entry.kind))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(borderColorForKind(entry.kind), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
    }

    /// Build the styled text view from the message's content chunks.
    @ViewBuilder
    private var messageText: some View {
        if entry.content.isEmpty {
            Text("")
        } else {
            entry.content.enumerated().reduce(Text("")) { result, indexed in
                let chunk = indexed.element
                let colors = resolveHighlight?(chunk.highlightID)
                let fg = colors?.foreground ?? defaultForeground
                return result + Text(chunk.text)
                    .foregroundColor(fg)
            }
        }
    }

    // MARK: - Kind Styling

    /// Maps Neovim message kinds to SF Symbol names.
    private func iconForKind(_ kind: String) -> String? {
        switch kind {
        case "emsg", "echoerr":
            return "xmark.circle.fill"
        case "wmsg":
            return "exclamationmark.triangle.fill"
        case "quickfix":
            return "list.bullet.rectangle.fill"
        case "search_count":
            return "magnifyingglass"
        case "lua_error":
            return "exclamationmark.circle.fill"
        case "rpc_error":
            return "network.slash"
        case "return_prompt":
            return "return"
        case "confirm", "confirm_sub":
            return "questionmark.circle.fill"
        case "":
            // Normal messages don't need an icon for clean appearance,
            // but we show one for consistency
            return "info.circle.fill"
        default:
            return "bubble.left.fill"
        }
    }

    /// Returns the accent color for the message kind's icon.
    private func colorForKind(_ kind: String) -> Color {
        switch kind {
        case "emsg", "echoerr", "lua_error", "rpc_error":
            return .red
        case "wmsg":
            return .yellow
        case "search_count":
            return .blue
        case "confirm", "confirm_sub", "return_prompt":
            return .orange
        case "quickfix":
            return .purple
        default:
            return .secondary
        }
    }

    /// Returns the background for the banner based on message kind.
    private func backgroundForKind(_ kind: String) -> some ShapeStyle {
        switch kind {
        case "emsg", "echoerr", "lua_error", "rpc_error":
            return AnyShapeStyle(.red.opacity(0.12))
        case "wmsg":
            return AnyShapeStyle(.yellow.opacity(0.10))
        case "confirm", "confirm_sub", "return_prompt":
            return AnyShapeStyle(.orange.opacity(0.10))
        default:
            return AnyShapeStyle(.ultraThinMaterial)
        }
    }

    /// Returns the border color for the banner based on message kind.
    private func borderColorForKind(_ kind: String) -> Color {
        switch kind {
        case "emsg", "echoerr", "lua_error", "rpc_error":
            return .red.opacity(0.3)
        case "wmsg":
            return .yellow.opacity(0.3)
        case "confirm", "confirm_sub", "return_prompt":
            return .orange.opacity(0.3)
        default:
            return .primary.opacity(0.1)
        }
    }
}

// MARK: - Auto-Dismiss Modifier

/// A view modifier that automatically dismisses a message after a delay.
struct AutoDismissModifier: ViewModifier {
    let delay: TimeInterval
    let onDismiss: () -> Void

    @State private var dismissTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onAppear {
                dismissTask = Task {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    await MainActor.run { onDismiss() }
                }
            }
            .onDisappear {
                dismissTask?.cancel()
            }
    }
}

extension View {
    /// Automatically dismiss this view after the given delay.
    func autoDismiss(after delay: TimeInterval, onDismiss: @escaping () -> Void) -> some View {
        modifier(AutoDismissModifier(delay: delay, onDismiss: onDismiss))
    }
}

// MARK: - History Sheet

/// A sheet view that displays the full message history, scrollable.
/// Can be triggered by the user (e.g. via `:messages` or a toolbar button).
struct MessageHistorySheet: View {
    let messages: [MessageEntry]
    var resolveHighlight: ((Int) -> (foreground: Color, background: Color))?
    var defaultForeground: Color = .white

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(messages) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                if let icon = iconForKind(entry.kind) {
                                    Image(systemName: icon)
                                        .foregroundStyle(colorForKind(entry.kind))
                                        .font(.system(size: 12))
                                        .frame(width: 16, alignment: .center)
                                }

                                styledText(for: entry)
                                    .font(.system(size: 13, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                            .id(entry.id)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onAppear {
                    if let last = messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .navigationTitle("Messages")
            #if os(macOS)
            .frame(minWidth: 500, minHeight: 300)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func styledText(for entry: MessageEntry) -> Text {
        entry.content.reduce(Text("")) { result, chunk in
            let colors = resolveHighlight?(chunk.highlightID)
            let fg = colors?.foreground ?? defaultForeground
            return result + Text(chunk.text).foregroundColor(fg)
        }
    }

    private func iconForKind(_ kind: String) -> String? {
        switch kind {
        case "emsg", "echoerr": return "xmark.circle.fill"
        case "wmsg": return "exclamationmark.triangle.fill"
        case "lua_error": return "exclamationmark.circle.fill"
        case "": return nil
        default: return "bubble.left.fill"
        }
    }

    private func colorForKind(_ kind: String) -> Color {
        switch kind {
        case "emsg", "echoerr", "lua_error": return .red
        case "wmsg": return .yellow
        default: return .secondary
        }
    }
}

// MARK: - Previews

#Preview("Message Overlay — Mixed") {
    ZStack(alignment: .bottom) {
        Color.black
            .ignoresSafeArea()

        MessageOverlay(
            messages: [
                MessageEntry(
                    kind: "",
                    content: [(highlightID: 0, text: "3 lines yanked")]
                ),
                MessageEntry(
                    kind: "wmsg",
                    content: [(highlightID: 0, text: "W10: Warning: Changing a readonly file")]
                ),
                MessageEntry(
                    kind: "emsg",
                    content: [
                        (highlightID: 1, text: "E492: "),
                        (highlightID: 0, text: "Not an editor command: foobar"),
                    ]
                ),
            ]
        )
    }
    .frame(width: 600, height: 400)
}

#Preview("Message Overlay — Error") {
    ZStack(alignment: .bottom) {
        Color(white: 0.15)
            .ignoresSafeArea()

        MessageOverlay(
            messages: [
                MessageEntry(
                    kind: "lua_error",
                    content: [
                        (highlightID: 0, text: "E5108: Error executing lua: "),
                        (highlightID: 2, text: "init.lua:42: "),
                        (highlightID: 0, text: "attempt to index a nil value"),
                    ]
                ),
            ]
        )
    }
    .frame(width: 600, height: 300)
}

#Preview("Message Overlay — Confirm") {
    ZStack(alignment: .bottom) {
        Color(white: 0.15)
            .ignoresSafeArea()

        MessageOverlay(
            messages: [
                MessageEntry(
                    kind: "confirm",
                    content: [
                        (highlightID: 0, text: "Save changes to \"untitled\"? [Y]es, (N)o, (C)ancel: "),
                    ]
                ),
            ]
        )
    }
    .frame(width: 600, height: 300)
}

#Preview("Message Overlay — Empty") {
    ZStack(alignment: .bottom) {
        Color.black
            .ignoresSafeArea()

        MessageOverlay(messages: [])
    }
    .frame(width: 600, height: 300)
}

#Preview("Message History Sheet") {
    MessageHistorySheet(
        messages: [
            MessageEntry(kind: "", content: [(highlightID: 0, text: "Press ENTER or type command to continue")]),
            MessageEntry(kind: "emsg", content: [(highlightID: 0, text: "E37: No write since last change")]),
            MessageEntry(kind: "wmsg", content: [(highlightID: 0, text: "W12: Warning: File changed since editing started")]),
            MessageEntry(kind: "", content: [(highlightID: 0, text: "\"file.txt\" 42L, 1337B written")]),
            MessageEntry(kind: "lua_error", content: [
                (highlightID: 0, text: "E5108: Error executing lua: "),
                (highlightID: 0, text: "[string \":lua\"]:1: unexpected symbol near '}"),
            ]),
        ]
    )
}