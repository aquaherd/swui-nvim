import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct SWUINeovimMacApp: App {
    @State private var controller = Phase1SessionController()
    @State private var inputText: String = "iHello from Phase 1<Esc>"
    @State private var savePath: String = "/tmp/swuinvim.txt"

    private var nvimPathBinding: Binding<String> {
        Binding(
            get: { controller.nvimPath },
            set: { controller.nvimPath = $0 }
        )
    }

    var body: some Scene {
        WindowGroup("SWUINeovimMac") {
            VStack(alignment: .leading, spacing: 12) {
                Text("SWUINeovim Phase 1 Local Session")
                    .font(.title2.weight(.semibold))

                HStack {
                    Text("nvim path")
                    TextField("/opt/local/bin/nvim", text: nvimPathBinding)
                        .textFieldStyle(.roundedBorder)
                }

                HStack(spacing: 10) {
                    Button("Connect Local") {
                        controller.connectLocal()
                    }
                    .disabled(controller.state == .connecting || controller.state == .attached)

                    Button("Disconnect") {
                        controller.disconnect()
                    }
                    .disabled(controller.state == .disconnected)
                }

                HStack(spacing: 10) {
                    Button("Save (:w)") {
                        controller.save()
                    }
                    .disabled(controller.state != .attached)

                    TextField("/tmp/swuinvim.txt", text: $savePath)
                        .textFieldStyle(.roundedBorder)

                    Button("Save As") {
                        controller.save(as: savePath)
                    }
                    .disabled(controller.state != .attached)
                }

                HStack {
                    Text("State:")
                    Text(controller.state.rawValue)
                        .fontWeight(.medium)
                }

                Text(controller.statusMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Divider()

                Text("Quick input")
                    .font(.headline)

                HStack {
                    TextField("Keys (nvim_input notation)", text: $inputText)
                        .textFieldStyle(.roundedBorder)
                    Button("Send") {
                        controller.sendInput(inputText)
                    }
                    .disabled(controller.state != .attached)
                }

                Text("Redraw events: \(controller.redrawEventCount)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding(16)
            .frame(minWidth: 620, minHeight: 360)
            #if os(macOS)
            .onAppear {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
            }
            #endif
        }
    }
}
