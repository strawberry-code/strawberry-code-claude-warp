import SwiftUI
import AppKit

struct SettingsView: View {
    @Bindable var state: AppState
    let onRestart: () -> Void

    @State private var portString: String = ""

    var body: some View {
        Form {
            serverSection
            cliSection
            environmentsSection
            restartSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, maxWidth: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            portString = String(state.port)
        }
    }

    // MARK: - Sections

    private var serverSection: some View {
        Section("Server") {
            TextField("Host", text: $state.host)
                .textFieldStyle(.roundedBorder)

            TextField("Porta", text: $portString)
                .textFieldStyle(.roundedBorder)
                .onChange(of: portString) { _, newValue in
                    if let p = Int(newValue), p > 0, p <= 65535 {
                        state.port = p
                    }
                }

            Toggle("Avvia server all'apertura", isOn: $state.autoStart)
        }
    }

    private var cliSection: some View {
        Section("Claude CLI") {
            HStack {
                TextField("Percorso Claude CLI", text: $state.claudePath)
                    .textFieldStyle(.roundedBorder)
                Button("Auto-detect") {
                    state.claudePath = AppState.detectClaudePath()
                }
            }
        }
    }

    private var environmentsSection: some View {
        Section("Ambienti") {
            ForEach(state.environments) { env in
                envRow(env)
            }

            HStack {
                Button {
                    addEnvironmentWithPanel()
                } label: {
                    Label("Aggiungi...", systemImage: "plus")
                }

                Spacer()

                Button("Rileva") {
                    let detected = AppState.detectEnvironments()
                    for d in detected {
                        if !state.environments.contains(where: { $0.configDir == d.configDir }) {
                            state.environments.append(d)
                        }
                    }
                }
            }
        }
    }

    private func envRow(_ env: ClaudeEnvironment) -> some View {
        HStack {
            Image(systemName: state.activeEnvironmentId == env.id ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(state.activeEnvironmentId == env.id ? Color.accentColor : Color.secondary)
                .onTapGesture { state.activeEnvironmentId = env.id }

            VStack(alignment: .leading) {
                Text(env.name).font(.body)
                Text(env.configDir)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if state.environments.count > 1 {
                Button(role: .destructive) {
                    state.environments.removeAll { $0.id == env.id }
                    if state.activeEnvironmentId == env.id {
                        state.activeEnvironmentId = state.environments.first?.configDir ?? ""
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var restartSection: some View {
        Section {
            HStack {
                Spacer()
                Button("Riavvia server") {
                    onRestart()
                }
                .disabled(!state.isRunning)
                Spacer()
            }
        }
    }

    // MARK: - Helpers

    private func addEnvironmentWithPanel() {
        let panel = NSOpenPanel()
        panel.title = "Seleziona una directory di configurazione Claude Code"
        panel.message = "La directory deve contenere un settings.json valido per Claude Code"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path

        guard AppState.isClaudeConfigDir(path) else {
            let alert = NSAlert()
            alert.messageText = "Directory non valida"
            alert.informativeText = "La directory selezionata non contiene un settings.json valido per Claude Code."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        let raw = url.lastPathComponent.hasPrefix(".") ? String(url.lastPathComponent.dropFirst()) : url.lastPathComponent
        let name = AppState.prettifyDirName(raw)

        guard !state.environments.contains(where: { $0.configDir == path }) else { return }
        state.environments.append(ClaudeEnvironment(name: name, configDir: path))
    }
}
