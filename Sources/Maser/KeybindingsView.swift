import MaserCore
import SwiftUI

/// Lists every command with its current menu and vim-style bindings.
struct KeybindingsView: View {
    static let windowID = "keybindings"

    var body: some View {
        let config = ConfigStore.shared
        VStack(alignment: .leading, spacing: 0) {
            Table(CommandID.allCases) {
                TableColumn("Command", value: \.title)
                TableColumn("Menu") { command in
                    Text(config.keymap.menu[command]?.symbols ?? "")
                }
                .width(min: 70, ideal: 90)
                TableColumn("Vim-style") { command in
                    Text((config.keymap.normal[command] ?? []).map(Keymap.format).joined(separator: ", "))
                        .monospaced()
                }
                .width(min: 70, ideal: 90)
                TableColumn("Config name") { command in
                    Text(command.rawValue).monospaced().foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack {
                Text(config.displayPath)
                    .monospaced()
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
                Button(CommandID.openConfig.title) { config.openConfigFile() }
            }
            .padding(10)
        }
        .frame(minWidth: 560, minHeight: 360)
        .configProblemsBanner()
        .commandHandler { _ in false }
    }
}

extension View {
    /// Shows problems from `config.toml` above the view until dismissed or fixed.
    func configProblemsBanner() -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            ConfigProblemsBanner()
        }
    }
}

private struct ConfigProblemsBanner: View {
    var body: some View {
        let config = ConfigStore.shared
        if !config.problems.isEmpty, !config.problemsDismissed {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Problems in \(config.displayPath)").bold()
                        ForEach(config.problems.prefix(5), id: \.self) { problem in
                            Text(problem).font(.callout).textSelection(.enabled)
                        }
                        if config.problems.count > 5 {
                            Text("…and \(config.problems.count - 5) more").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Open") { config.openConfigFile() }
                    Button("Dismiss", systemImage: "xmark") { config.problemsDismissed = true }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
                .padding(10)
                .background(.yellow.opacity(0.12))
                Divider()
            }
        }
    }
}
