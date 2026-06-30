import Foundation

/// One named API key for a provider (e.g. tavily/apple).
struct NamedKey: Equatable {
    let name: String
    let value: String
}

/// Abstraction over where provider API keys come from.
/// First implementation reads ai-infra's keys.local.yaml; can be swapped later
/// for an `ai-infra keys export` command without touching consumers.
protocol KeySource {
    func keys(forProvider provider: String) throws -> [NamedKey]
}

/// Reads keys from ai-infra's private keys.local.yaml.
/// Structure: secrets.<provider>.<name>.value
/// Lightweight indentation parser — only extracts the requested provider's
/// `name: value` pairs. No third-party YAML dependency.
final class AIInfraYamlKeySource: KeySource {
    private let fileURL: URL

    init(fileURL: URL = AIInfraYamlKeySource.defaultURL()) {
        self.fileURL = fileURL
    }

    static func defaultURL() -> URL {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return home.appendingPathComponent("projects/ai-infra/.private/resources/keys.local.yaml")
    }

    func keys(forProvider provider: String) throws -> [NamedKey] {
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)

        var inSecrets = false
        var providerIndent: Int?
        var inProvider = false
        var currentKeyName: String?
        var result: [NamedKey] = []

        func indent(of line: String) -> Int {
            line.prefix { $0 == " " }.count
        }

        for rawLine in lines {
            let line = rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let lineIndent = indent(of: line)

            if trimmed == "secrets:" {
                inSecrets = true
                continue
            }
            guard inSecrets else { continue }

            if trimmed == "\(provider):" {
                providerIndent = lineIndent
                inProvider = true
                currentKeyName = nil
                continue
            }

            if inProvider {
                guard let pIndent = providerIndent else { continue }
                if lineIndent <= pIndent && trimmed.hasSuffix(":") {
                    inProvider = false
                    continue
                }
                if trimmed.hasSuffix(":") && lineIndent == pIndent + 2 {
                    currentKeyName = String(trimmed.dropLast())
                    continue
                }
                if trimmed.hasPrefix("value:"), let name = currentKeyName {
                    let value = trimmed
                        .replacingOccurrences(of: "value:", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    if !value.isEmpty {
                        result.append(NamedKey(name: name, value: value))
                    }
                }
            }
        }
        return result
    }
}
