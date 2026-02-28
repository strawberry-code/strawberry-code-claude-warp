import SwiftUI

struct MenuBarView: View {
    let state: AppState
    let onStart: () -> Void
    let onStop: () -> Void
    let onRestart: () -> Void
    let onQuit: () -> Void

    @State private var showClientConfig = false
    @State private var copiedFeedback = false
    @State private var copiedBase = false
    @State private var copiedKey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerSection
            Divider()
            controlsSection
            environmentSection
            modelsSection
            Divider()
            clientConfigSection
            Divider()
            footerSection
        }
        .padding(16)
        .frame(width: 280)
    }

    // MARK: - Sections

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ClaudeWarp")
                .font(.headline)

            HStack(spacing: 6) {
                Circle()
                    .fill(state.isRunning ? .green : .red)
                    .frame(width: 8, height: 8)
                Text(state.isRunning ? "Running" : "Stopped")
                    .foregroundStyle(state.isRunning ? .primary : .secondary)
            }

            Group {
                if state.isRunning {
                    Text(state.endpointURL)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Avvio...")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(height: 14, alignment: .leading)

            Text("Requests: \(state.requestCount)")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let error = state.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
    }

    private var controlsSection: some View {
        HStack(spacing: 8) {
            if state.isRunning {
                Button("Stop") { onStop() }
                Button("Restart") { onRestart() }
            } else {
                Button("Start") { onStart() }
            }

            Spacer()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(state.endpointURL, forType: .string)
                copiedFeedback = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    copiedFeedback = false
                }
            } label: {
                Text(copiedFeedback ? "Copiato!" : "Copy URL")
            }
        }
    }

    @ViewBuilder
    private var environmentSection: some View {
        if state.environments.count > 1 {
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("Ambiente")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(state.environments) { env in
                    envRadioRow(env)
                }
            }
        }
    }

    private func envRadioRow(_ env: ClaudeEnvironment) -> some View {
        HStack(spacing: 6) {
            Image(systemName: state.activeEnvironmentId == env.id ? "largecircle.fill.circle" : "circle")
                .font(.caption)
                .foregroundStyle(state.activeEnvironmentId == env.id ? Color.accentColor : Color.secondary)
            Text(env.name)
                .font(.caption)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            state.activeEnvironmentId = env.id
        }
    }

    @ViewBuilder
    private var modelsSection: some View {
        if !state.availableModels.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Modello")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(state.availableModels, id: \.self) { model in
                    modelRadioRow(model)
                }
            }
        }
    }

    private func modelRadioRow(_ model: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: state.selectedModel == model ? "largecircle.fill.circle" : "circle")
                .font(.caption)
                .foregroundStyle(state.selectedModel == model ? Color.accentColor : Color.secondary)
            Text(model)
                .font(.caption)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            state.selectedModel = model
        }
    }

    private var clientConfigSection: some View {
        DisclosureGroup("Configurazione client", isExpanded: $showClientConfig) {
            VStack(alignment: .leading, spacing: 6) {
                copyableEnvRow(
                    text: "ANTHROPIC_API_BASE=\(state.endpointURL)",
                    copied: $copiedBase
                )
                copyableEnvRow(
                    text: "ANTHROPIC_API_KEY=dummy",
                    copied: $copiedKey
                )
            }
            .padding(.top, 4)
        }
        .font(.caption)
    }

    private var footerSection: some View {
        HStack {
            SettingsLink {
                Text("Impostazioni...")
                    .font(.caption)
            }

            Spacer()

            Button("Esci") { onQuit() }
                .font(.caption)
        }
    }

    // MARK: - Helpers

    private func copyableEnvRow(text: String, copied: Binding<Bool>) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)

            Spacer(minLength: 2)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied.wrappedValue = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    copied.wrappedValue = false
                }
            } label: {
                Image(systemName: copied.wrappedValue ? "checkmark" : "doc.on.doc")
                    .font(.caption2)
                    .foregroundStyle(copied.wrappedValue ? .green : .secondary)
            }
            .buttonStyle(.plain)
        }
    }
}
