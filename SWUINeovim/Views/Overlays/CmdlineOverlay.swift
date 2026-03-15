// CmdlineOverlay.swift
// SWUINeovim
//
// SwiftUI overlay that renders Neovim's external command line (ext_cmdline).
// Positioned at the bottom of the editor surface, styled to match the
// editor's color scheme. Shows the first character (e.g. ":", "/", "?"),
// prompt text, and the command line content with cursor positioning.

import SwiftUI

// MARK: - CmdlineOverlay

/// A SwiftUI overlay that displays Neovim's command line when `ext_cmdline`
/// is enabled.
///
/// This overlay appears at the bottom of the editor view and renders:
/// - The first character (`:`, `/`, `?`, etc.)
/// - An optional prompt string
/// - The command line content with inline highlight attributes
/// - A blinking cursor at the current position
///
/// ## Usage
///
/// ```swift
/// EditorSurface()
///     .overlay(alignment: .bottom) {
///         CmdlineOverlay(
///             state: session.cmdline,
///             highlightTable: session.highlightTable,
///             defaultColors: session.defaultColors
///         )
///     }
/// ```
struct CmdlineOverlay: View {
    /// The current command line state from the Neovim session.
    let state: CmdlineState

    /// Highlight table for resolving highlight IDs to colors.
    let highlightTable: [Int: RawHighlightAttrs]

    /// Default foreground/background colors.
    let defaultColors: DefaultColors

    /// Animation state for the blinking cursor.
    @State private var cursorVisible: Bool = true

    /// Timer driving the cursor blink animation.
    @State private var blinkTimer: Timer?

    /// The font used for the command line text.
    var font: Font = .system(size: 14, weight: .regular, design: .monospaced)

    /// The platform font used for text measurement (mirrors `font`).
    var measurementFontSize: CGFloat = 14

    /// Horizontal padding inside the command line bar.
    var horizontalPadding: CGFloat = 12

    /// Vertical padding inside the command line bar.
    var verticalPadding: CGFloat = 8

    /// Corner radius of the command line bar.
    var cornerRadius: CGFloat = 8

    /// Whether to show a shadow beneath the command line bar.
    var showShadow: Bool = true

    var body: some View {
        if state.isVisible {
            cmdlineBar
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.15), value: state.isVisible)
                .onAppear { startBlinking() }
                .onDisappear { stopBlinking() }
        }
    }

    // MARK: - Command Line Bar

    @ViewBuilder
    private var cmdlineBar: some View {
        HStack(spacing: 0) {
            // First character (e.g. ":", "/", "?")
            if !state.firstCharacter.isEmpty {
                Text(state.firstCharacter)
                    .font(font)
                    .foregroundStyle(firstCharacterColor)
                    .padding(.trailing, 2)
            }

            // Prompt (if any)
            if !state.prompt.isEmpty {
                Text(state.prompt)
                    .font(font)
                    .foregroundStyle(promptColor)
                    .padding(.trailing, 4)
            }

            // Indent spacing
            if state.indent > 0 {
                Text(String(repeating: " ", count: state.indent))
                    .font(font)
            }

            // Content with inline cursor
            cmdlineContent
                .font(font)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 0.5)
        )
        .shadow(color: showShadow ? .black.opacity(0.25) : .clear, radius: 8, y: -2)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    // MARK: - Content with Cursor

    @ViewBuilder
    private var cmdlineContent: some View {
        let fullText = state.text
        let cursorPos = state.position

        if fullText.isEmpty {
            // Empty command line — just show the cursor
            cursorView
        } else {
            // Build the text with cursor inserted at the correct position
            HStack(spacing: 0) {
                ForEach(Array(contentSegments.enumerated()), id: \.offset) { _, segment in
                    if segment.isCursor {
                        cursorView
                    } else {
                        Text(segment.text)
                            .foregroundStyle(foregroundColor(for: segment.highlightID))
                    }
                }

                // If cursor is at the end, show it after the last segment
                if cursorPos >= fullText.count {
                    cursorView
                }
            }
        }
    }

    // MARK: - Content Segments

    /// A segment of the command line content, either text or a cursor marker.
    private struct ContentSegment: Identifiable {
        let id: Int
        let text: String
        let highlightID: Int
        let isCursor: Bool

        init(id: Int, text: String, highlightID: Int = 0, isCursor: Bool = false) {
            self.id = id
            self.text = text
            self.highlightID = highlightID
            self.isCursor = isCursor
        }
    }

    /// Splits the command line content into segments with a cursor marker
    /// inserted at the correct position.
    private var contentSegments: [ContentSegment] {
        let content = state.content
        let cursorPos = state.position

        guard !content.isEmpty else {
            return [ContentSegment(id: 0, text: "", isCursor: true)]
        }

        var segments: [ContentSegment] = []
        var segmentID = 0
        var globalCharIndex = 0

        for chunk in content {
            let chunkText = chunk.text
            let chunkChars = Array(chunkText)
            let hlID = chunk.highlightID

            // Check if the cursor falls within this chunk
            let chunkStart = globalCharIndex
            let chunkEnd = globalCharIndex + chunkChars.count

            if cursorPos >= chunkStart && cursorPos < chunkEnd {
                // Cursor is inside this chunk — split it
                let localCursorPos = cursorPos - chunkStart

                if localCursorPos > 0 {
                    let before = String(chunkChars[0..<localCursorPos])
                    segments.append(ContentSegment(id: segmentID, text: before, highlightID: hlID))
                    segmentID += 1
                }

                // Insert cursor marker
                segments.append(ContentSegment(id: segmentID, text: "", isCursor: true))
                segmentID += 1

                if localCursorPos < chunkChars.count {
                    let after = String(chunkChars[localCursorPos...])
                    segments.append(ContentSegment(id: segmentID, text: after, highlightID: hlID))
                    segmentID += 1
                }
            } else {
                // Cursor is not in this chunk — add the whole thing
                if !chunkText.isEmpty {
                    segments.append(ContentSegment(id: segmentID, text: chunkText, highlightID: hlID))
                    segmentID += 1
                }
            }

            globalCharIndex = chunkEnd
        }

        return segments
    }

    // MARK: - Cursor View

    @ViewBuilder
    private var cursorView: some View {
        Rectangle()
            .fill(cursorColor)
            .frame(width: 2, height: measurementFontSize + 2)
            .opacity(cursorVisible ? 1.0 : 0.0)
    }

    // MARK: - Blink Animation

    private func startBlinking() {
        cursorVisible = true
        stopBlinking()

        let timer = Timer.scheduledTimer(withTimeInterval: 0.53, repeats: true) { _ in
            Task { @MainActor in
                withAnimation(.easeInOut(duration: 0.08)) {
                    cursorVisible.toggle()
                }
            }
        }
        blinkTimer = timer
    }

    private func stopBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        cursorVisible = true
    }

    // MARK: - Styling

    /// Resolves the foreground color for a given highlight ID.
    private func foregroundColor(for highlightID: Int) -> Color {
        guard let attrs = highlightTable[highlightID],
              let fg = attrs.foreground else {
            return defaultForeground
        }
        return Color(rgb: fg)
    }

    /// The color for the first character (`:`, `/`, etc.).
    private var firstCharacterColor: Color {
        .accentColor
    }

    /// The color for prompt text.
    private var promptColor: Color {
        defaultForeground.opacity(0.8)
    }

    /// The default foreground color from Neovim.
    private var defaultForeground: Color {
        Color(rgb: defaultColors.foreground)
    }

    /// The cursor color — matches the accent or foreground.
    private var cursorColor: Color {
        .accentColor
    }

    /// The border color for the command line bar.
    private var borderColor: Color {
        Color.primary.opacity(0.15)
    }
}

// MARK: - Block Command Line

/// A variant overlay for block command-line content (`:lua <<EOF` style).
/// Renders multi-line content in a larger panel.
struct CmdlineBlockOverlay: View {
    /// The lines of the block command, each being an array of styled chunks.
    var blockLines: [[(highlightID: Int, text: String)]]

    /// Highlight table for resolving highlight IDs to colors.
    let highlightTable: [Int: RawHighlightAttrs]

    /// Default foreground/background colors.
    let defaultColors: DefaultColors

    var font: Font = .system(size: 13, weight: .regular, design: .monospaced)

    var body: some View {
        if !blockLines.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(blockLines.enumerated()), id: \.offset) { lineIndex, chunks in
                    HStack(spacing: 0) {
                        lineNumberView(lineIndex + 1)

                        ForEach(Array(chunks.enumerated()), id: \.offset) { _, chunk in
                            Text(chunk.text)
                                .font(font)
                                .foregroundStyle(chunkColor(highlightID: chunk.highlightID))
                        }

                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(12)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.2), radius: 8, y: -2)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private func lineNumberView(_ number: Int) -> some View {
        Text("\(number)")
            .font(.system(size: 11, weight: .regular, design: .monospaced))
            .foregroundStyle(Color.secondary)
            .frame(width: 28, alignment: .trailing)
            .padding(.trailing, 8)
    }

    private func chunkColor(highlightID: Int) -> Color {
        guard let attrs = highlightTable[highlightID],
              let fg = attrs.foreground else {
            return Color(rgb: defaultColors.foreground)
        }
        return Color(rgb: fg)
    }
}

// MARK: - Wildmenu Overlay

/// Overlay for the command-line completion menu (wildmenu).
/// Shows a horizontal bar of completion candidates when the user
/// presses Tab in command mode.
struct WildmenuOverlay: View {
    var items: [String]
    var selectedIndex: Int

    var font: Font = .system(size: 13, weight: .regular, design: .monospaced)

    var body: some View {
        if !items.isEmpty {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                            Text(item)
                                .font(font)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    index == selectedIndex
                                        ? Color.accentColor.opacity(0.3)
                                        : Color.clear
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                .foregroundStyle(
                                    index == selectedIndex
                                        ? Color.accentColor
                                        : Color.primary
                                )
                                .id(index)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .frame(height: 32)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
                .onChange(of: selectedIndex) { _, newValue in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
        }
    }
}

// MARK: - Color Extension

extension Color {
    /// Initialize a Color from a 24-bit RGB integer (0xRRGGBB).
    init(rgb: UInt32) {
        let r = Double((rgb >> 16) & 0xFF) / 255.0
        let g = Double((rgb >> 8) & 0xFF) / 255.0
        let b = Double(rgb & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - Preview

#if DEBUG
struct CmdlineOverlay_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VStack {
                Spacer()

                // Simulated command line
                HStack(spacing: 0) {
                    Text(":")
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(.blue)
                        .padding(.trailing, 2)

                    Text("set number relativenumber")
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(.white)

                    Rectangle()
                        .fill(Color.blue)
                        .frame(width: 2, height: 16)

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.25), radius: 8, y: -2)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
        .previewDisplayName("Cmdline Overlay")
    }
}
#endif
