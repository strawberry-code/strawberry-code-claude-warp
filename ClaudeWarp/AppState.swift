import Foundation
import SwiftUI

/// Un ambiente/subscription Claude con nome e path della config directory.
struct ClaudeEnvironment: Codable, Identifiable, Equatable {
    var id: String { configDir }
    var name: String
    var configDir: String
}

@Observable
final class AppState {
    // MARK: - Runtime state
    var isRunning = false
    var requestCount = 0
    var lastError: String?

    // MARK: - Settings (persisted via UserDefaults)
    var host: String {
        didSet { UserDefaults.standard.set(host, forKey: "host") }
    }
    var port: Int {
        didSet { UserDefaults.standard.set(port, forKey: "port") }
    }
    var claudePath: String {
        didSet { UserDefaults.standard.set(claudePath, forKey: "claudePath") }
    }
    var autoStart: Bool {
        didSet { UserDefaults.standard.set(autoStart, forKey: "autoStart") }
    }

    // MARK: - Environments
    var environments: [ClaudeEnvironment] {
        didSet { saveEnvironments() }
    }
    var activeEnvironmentId: String {
        didSet { UserDefaults.standard.set(activeEnvironmentId, forKey: "activeEnvironmentId") }
    }

    var activeEnvironment: ClaudeEnvironment? {
        environments.first { $0.id == activeEnvironmentId }
    }

    // MARK: - Computed
    var endpointURL: String {
        "http://\(host):\(port)"
    }

    // MARK: - Init
    init() {
        let defaults = UserDefaults.standard
        self.host = defaults.string(forKey: "host") ?? "127.0.0.1"
        self.port = defaults.object(forKey: "port") as? Int ?? 8082
        self.claudePath = defaults.string(forKey: "claudePath") ?? AppState.detectClaudePath()
        self.autoStart = defaults.object(forKey: "autoStart") as? Bool ?? true

        // Load environments
        let loadedEnvs: [ClaudeEnvironment]
        if let data = defaults.data(forKey: "environments"),
           let envs = try? JSONDecoder().decode([ClaudeEnvironment].self, from: data),
           !envs.isEmpty {
            loadedEnvs = envs
        } else {
            loadedEnvs = AppState.detectEnvironments()
        }
        self.environments = loadedEnvs
        self.activeEnvironmentId = defaults.string(forKey: "activeEnvironmentId") ?? loadedEnvs.first?.configDir ?? ""
    }

    // MARK: - Helpers
    static func detectClaudePath() -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", "claude"]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return path.isEmpty ? "/usr/local/bin/claude" : path
        } catch {
            return "/usr/local/bin/claude"
        }
    }

    /// Verifica se una directory contiene un settings.json valido per Claude Code.
    /// Un settings.json è di Claude Code se è JSON valido e contiene almeno una
    /// chiave nota: "permissions", "model", "env".
    static func isClaudeConfigDir(_ path: String) -> Bool {
        let settingsPath = "\(path)/settings.json"
        guard let data = FileManager.default.contents(atPath: settingsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        let knownKeys: Set<String> = ["permissions", "model", "env", "hooks", "enabledPlugins"]
        return !knownKeys.isDisjoint(with: json.keys)
    }

    /// Scansiona $HOME per directory che contengono un settings.json valido per Claude Code.
    static func detectEnvironments() -> [ClaudeEnvironment] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fm = FileManager.default
        var envs: [ClaudeEnvironment] = []

        let candidates = (try? fm.contentsOfDirectory(atPath: home))?.sorted() ?? []
        for item in candidates {
            guard item.hasPrefix(".") else { continue }
            let fullPath = "\(home)/\(item)"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue else { continue }
            guard isClaudeConfigDir(fullPath) else { continue }

            let name = prettifyDirName(String(item.dropFirst()))
            envs.append(ClaudeEnvironment(name: name, configDir: fullPath))
        }

        if envs.isEmpty {
            envs.append(ClaudeEnvironment(name: "claude", configDir: "\(home)/.claude"))
        }

        return envs
    }

    /// Converte un nome di directory in formato Capitalized:
    /// "claude-test" → "Claude Test", "claudia.prova_env" → "Claudia Prova Env"
    static func prettifyDirName(_ raw: String) -> String {
        raw.components(separatedBy: CharacterSet(charactersIn: "-._"))
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private func saveEnvironments() {
        if let data = try? JSONEncoder().encode(environments) {
            UserDefaults.standard.set(data, forKey: "environments")
        }
    }

    func incrementRequestCount() {
        requestCount += 1
    }
}
