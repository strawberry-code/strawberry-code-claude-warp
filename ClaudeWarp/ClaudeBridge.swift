import Foundation

struct CLIResult {
    let text: String
    let inputTokens: Int
    let outputTokens: Int
    let isError: Bool
}

/// Gestione subprocess `claude -p` per chiamate headless.
enum ClaudeBridge {

    // MARK: - Model mapping

    private static let modelMap: [(keyword: String, flag: String)] = [
        ("opus", "opus"),
        ("sonnet", "sonnet"),
        ("haiku", "haiku"),
    ]

    static func resolveModelFlag(_ modelName: String) -> String {
        let lower = modelName.lowercased()
        for (keyword, flag) in modelMap {
            if lower.contains(keyword) { return flag }
        }
        return "sonnet"
    }

    // MARK: - Message formatting

    static func formatMessages(_ messages: [[String: Any]]) -> String {
        guard !messages.isEmpty else { return "" }

        // Single user message: use directly
        if messages.count == 1,
           let role = messages[0]["role"] as? String, role == "user" {
            return extractContent(messages[0]["content"])
        }

        // Multi-turn: format as transcript
        var parts: [String] = []
        for msg in messages {
            let role = msg["role"] as? String ?? "user"
            let content = extractContent(msg["content"])
            if role == "user" {
                parts.append("Human: \(content)")
            } else if role == "assistant" {
                parts.append("Assistant: \(content)")
            }
        }
        return parts.joined(separator: "\n\n")
    }

    private static func extractContent(_ content: Any?) -> String {
        if let str = content as? String { return str }
        if let blocks = content as? [[String: Any]] {
            var textParts: [String] = []
            for block in blocks {
                let type = block["type"] as? String ?? ""
                if type == "text", let text = block["text"] as? String {
                    textParts.append(text)
                } else if type == "tool_result" {
                    let inner = block["content"] ?? ""
                    if let jsonData = try? JSONSerialization.data(withJSONObject: inner),
                       let jsonStr = String(data: jsonData, encoding: .utf8) {
                        textParts.append("[Tool result: \(jsonStr)]")
                    }
                } else if type == "tool_use" {
                    let name = block["name"] as? String ?? "?"
                    let input = block["input"] ?? [String: Any]()
                    if let jsonData = try? JSONSerialization.data(withJSONObject: input),
                       let jsonStr = String(data: jsonData, encoding: .utf8) {
                        textParts.append("[Tool call: \(name)(\(jsonStr))]")
                    }
                }
            }
            return textParts.joined(separator: "\n")
        }
        if let val = content { return "\(val)" }
        return ""
    }

    // MARK: - System prompt + tools

    static func buildSystemPrompt(system: Any?, tools: [[String: Any]]?) -> String? {
        var sysText = ""

        if let str = system as? String {
            sysText = str
        } else if let blocks = system as? [[String: Any]] {
            sysText = blocks.compactMap { block -> String? in
                guard (block["type"] as? String) == "text" else { return nil }
                return block["text"] as? String
            }.joined(separator: "\n")
        }

        if let tools = tools, !tools.isEmpty {
            var toolDescs: [String] = []
            for tool in tools {
                let name = tool["name"] as? String ?? "unknown"
                let desc = tool["description"] as? String ?? ""
                let schema = tool["input_schema"] ?? [String: Any]()
                if let jsonData = try? JSONSerialization.data(withJSONObject: schema, options: .prettyPrinted),
                   let jsonStr = String(data: jsonData, encoding: .utf8) {
                    toolDescs.append("- **\(name)**: \(desc)\n  Input schema: \(jsonStr)")
                }
            }

            sysText += """

            \n\n---
            You have access to the following tools. To use a tool, respond with a JSON block like this:
            ```tool_use
            {"name": "tool_name", "input": {...}}
            ```

            Available tools:
            \(toolDescs.joined(separator: "\n"))
            """
        }

        return sysText.isEmpty ? nil : sysText
    }

    // MARK: - Parse tool_use blocks

    static func parseToolUse(from text: String) -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        var remaining = text

        while let range = remaining.range(of: "```tool_use") {
            let before = String(remaining[remaining.startIndex..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !before.isEmpty {
                blocks.append(["type": "text", "text": before])
            }

            remaining = String(remaining[range.upperBound...])

            guard let endRange = remaining.range(of: "```") else {
                blocks.append(["type": "text", "text": "```tool_use\(remaining)"])
                remaining = ""
                break
            }

            let jsonStr = String(remaining[remaining.startIndex..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            remaining = String(remaining[endRange.upperBound...])

            if let data = jsonStr.data(using: .utf8),
               let toolData = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let toolId = "toolu_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24))"
                blocks.append([
                    "type": "tool_use",
                    "id": toolId,
                    "name": toolData["name"] as? String ?? "unknown",
                    "input": toolData["input"] ?? [String: Any](),
                ])
            } else {
                blocks.append(["type": "text", "text": "```tool_use\n\(jsonStr)\n```"])
            }
        }

        let leftover = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        if !leftover.isEmpty {
            blocks.append(["type": "text", "text": leftover])
        }

        if blocks.isEmpty {
            blocks.append(["type": "text", "text": text])
        }

        return blocks
    }

    // MARK: - Call CLI

    static func call(prompt: String, systemPrompt: String?, modelFlag: String, claudePath: String, configDir: String? = nil) async throws -> CLIResult {
        var args = [
            "-p",
            "--tools", "",
            "--output-format", "json",
            "--model", modelFlag,
        ]

        if let sys = systemPrompt {
            args.append(contentsOf: ["--system-prompt", sys])
        }

        // Ambiente pulito per il subprocess claude
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        env.removeValue(forKey: "CI")
        env["TERM"] = "dumb"
        if env["HOME"] == nil {
            env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        }
        if env["PATH"] == nil {
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        }

        // Set config directory per il settings.json dell'ambiente selezionato.
        // Le credenziali OAuth restano in $HOME/.claude.json (gestite da Claude CLI).
        if let configDir = configDir {
            env["CLAUDE_CONFIG_DIR"] = configDir
        }
        // Rimuovi CLAUDE_CONFIG_DIR se punta al default — evita conflitto con le credenziali OAuth
        let home = env["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        if env["CLAUDE_CONFIG_DIR"] == "\(home)/.claude" {
            env.removeValue(forKey: "CLAUDE_CONFIG_DIR")
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                let stdinPipe = Pipe()

                process.executableURL = URL(fileURLWithPath: claudePath)
                process.arguments = args
                process.environment = env
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                process.standardInput = stdinPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: CLIResult(
                        text: "Failed to launch claude CLI: \(error.localizedDescription)",
                        inputTokens: 0, outputTokens: 0, isError: true
                    ))
                    return
                }

                // Write prompt to stdin and close
                let promptData = prompt.data(using: .utf8) ?? Data()
                stdinPipe.fileHandleForWriting.write(promptData)
                stdinPipe.fileHandleForWriting.closeFile()

                process.waitUntilExit()

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                if process.terminationStatus != 0 {
                    let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let stdout = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let detail = stderr.isEmpty ? (stdout.isEmpty ? "exit code \(process.terminationStatus)" : stdout) : stderr
                    print("[ClaudeWarp] CLI failed: exit=\(process.terminationStatus) stderr=\(stderr.prefix(200)) stdout=\(stdout.prefix(200))")
                    continuation.resume(returning: CLIResult(
                        text: "Claude CLI error: \(detail)",
                        inputTokens: 0, outputTokens: 0, isError: true
                    ))
                    return
                }

                guard let json = try? JSONSerialization.jsonObject(with: stdoutData) as? [String: Any] else {
                    let raw = String(data: stdoutData, encoding: .utf8) ?? ""
                    continuation.resume(returning: CLIResult(
                        text: "Invalid JSON from claude CLI: \(String(raw.prefix(500)))",
                        inputTokens: 0, outputTokens: 0, isError: true
                    ))
                    return
                }

                let result = json["result"] as? String ?? ""
                let usage = json["usage"] as? [String: Any] ?? [:]
                let inputTokens = usage["input_tokens"] as? Int ?? 0
                let outputTokens = usage["output_tokens"] as? Int ?? 0
                let isError = json["is_error"] as? Bool ?? false

                continuation.resume(returning: CLIResult(
                    text: result,
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    isError: isError
                ))
            }
        }
    }
}
