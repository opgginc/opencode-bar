import ArgumentParser
import Foundation

// MARK: - Exit Codes

enum CLIExitCode: Int32 {
    case success = 0
    case generalError = 1
    case authenticationFailed = 2
    case networkError = 3
    case invalidArguments = 4
}

// MARK: - Commands

struct OpenCodeBar: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "opencodebar",
        abstract: "AI provider usage monitor",
        version: "1.0.0",
        subcommands: [
            StatusCommand.self,
            ListCommand.self,
            ProviderCommand.self
        ],
        defaultSubcommand: StatusCommand.self
    )
}

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Display current usage status for all providers"
    )
    
    @Flag(name: .long, help: "Output as JSON instead of table")
    var json: Bool = false
    
    mutating func run() throws {
        let jsonFlag = self.json
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var error: Error?
        nonisolated(unsafe) var output: String?
        
        Task {
            do {
                let manager = CLIProviderManager()
                let results = await manager.fetchAll()
                
                guard !results.isEmpty else {
                    let stderr = FileHandle.standardError
                    let message = "Error: No provider data available. Check your OpenCode authentication.\n"
                    stderr.write(Data(message.utf8))
                    semaphore.signal()
                    Foundation.exit(CLIExitCode.generalError.rawValue)
                }
                
                if jsonFlag {
                    output = try JSONFormatter.format(results)
                } else {
                    output = TableFormatter.format(results)
                }
            } catch let e as ProviderError {
                error = e
            } catch let e {
                error = e
            }
            semaphore.signal()
        }
        
        semaphore.wait()
        
        if let error = error {
            let stderr = FileHandle.standardError
            let message = "Error: \(error.localizedDescription)\n"
            stderr.write(Data(message.utf8))
            
            if let providerError = error as? ProviderError {
                let exitCode: CLIExitCode
                switch providerError {
                case .authenticationFailed:
                    exitCode = .authenticationFailed
                case .networkError:
                    exitCode = .networkError
                default:
                    exitCode = .generalError
                }
                Foundation.exit(exitCode.rawValue)
            } else {
                Foundation.exit(CLIExitCode.generalError.rawValue)
            }
        }
        
        if let output = output {
            print(output)
        }
    }
}

struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all configured AI providers"
    )
    
    @Flag(name: .long, help: "Output as JSON instead of table")
    var json: Bool = false
    
    mutating func run() throws {
        let providers = CLIProviderManager.registeredProviders
        
        if json {
            let providerList = providers.map { provider in
                [
                    "id": provider.rawValue,
                    "name": provider.displayName
                ]
            }
            
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let jsonData = try encoder.encode(providerList)
            
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                print(jsonString)
            }
        } else {
            print("Available Providers:")
            print(String(repeating: "─", count: 50))
            
            for provider in providers.sorted(by: { $0.displayName < $1.displayName }) {
                let idPadded = provider.rawValue.padding(toLength: 20, withPad: " ", startingAt: 0)
                print("\(idPadded)  \(provider.displayName)")
            }
            
            print(String(repeating: "─", count: 50))
            print("Total: \(providers.count) providers")
        }
    }
}

struct ProviderCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "provider",
        abstract: "Get details for a specific provider"
    )
    
    @Argument(help: "Provider name (e.g., claude, openrouter, copilot)")
    var name: String
    
    @Flag(name: .long, help: "Output as JSON instead of table")
    var json: Bool = false
    
    mutating func run() throws {
        let providerName = self.name
        let jsonFlag = self.json
        
        guard let identifier = findProvider(name: providerName) else {
            let stderr = FileHandle.standardError
            let errorMessage = "Error: Provider '\(providerName)' not found\n"
            stderr.write(Data(errorMessage.utf8))
            
            if jsonFlag {
                let error = ["error": "Provider '\(providerName)' not found"]
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted]
                if let jsonData = try? encoder.encode(error),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    print(jsonString)
                }
            } else {
                let availableMessage = "\nAvailable providers:\n"
                stderr.write(Data(availableMessage.utf8))
                for provider in ProviderIdentifier.allCases.sorted(by: { $0.displayName < $1.displayName }) {
                    let providerLine = "  - \(provider.rawValue) (\(provider.displayName))\n"
                    stderr.write(Data(providerLine.utf8))
                }
            }
            Foundation.exit(CLIExitCode.invalidArguments.rawValue)
        }
        
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var error: Error?
        nonisolated(unsafe) var output: String?
        nonisolated(unsafe) var fetchFailed = false
        
        Task {
            do {
                let manager = CLIProviderManager()
                let results = await manager.fetchAll()
                
                guard let result = results[identifier] else {
                    if jsonFlag {
                        let errorDict = ["error": "Failed to fetch data for '\(identifier.displayName)'"]
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.prettyPrinted]
                        if let jsonData = try? encoder.encode(errorDict),
                           let jsonString = String(data: jsonData, encoding: .utf8) {
                            output = jsonString
                        }
                    } else {
                        output = "Error: Failed to fetch data for '\(identifier.displayName)'\nThis provider may not be configured or authentication may have failed."
                    }
                    fetchFailed = true
                    semaphore.signal()
                    return
                }
                
                if jsonFlag {
                    let singleResult = [identifier: result]
                    output = try JSONFormatter.format(singleResult)
                } else {
                    let singleResult = [identifier: result]
                    output = TableFormatter.format(singleResult)
                }
            } catch let e as ProviderError {
                error = e
            } catch let e {
                error = e
            }
            semaphore.signal()
        }
        
        semaphore.wait()
        
        if let error = error {
            if let output = output {
                print(output)
            }
            
            if let providerError = error as? ProviderError {
                let exitCode: CLIExitCode
                switch providerError {
                case .authenticationFailed:
                    exitCode = .authenticationFailed
                case .networkError:
                    exitCode = .networkError
                default:
                    exitCode = .generalError
                }
                let stderr = FileHandle.standardError
                let message = "Error: \(providerError.localizedDescription)\n"
                stderr.write(Data(message.utf8))
                Foundation.exit(exitCode.rawValue)
            } else {
                let stderr = FileHandle.standardError
                let message = "Error: \(error.localizedDescription)\n"
                stderr.write(Data(message.utf8))
                Foundation.exit(CLIExitCode.generalError.rawValue)
            }
        }
        
        if fetchFailed {
            if let output = output {
                print(output)
            }
            Foundation.exit(CLIExitCode.generalError.rawValue)
        }
        
        if let output = output {
            print(output)
        }
    }
    
    private func findProvider(name: String) -> ProviderIdentifier? {
        let lowercasedName = name.lowercased()
        
        if let provider = ProviderIdentifier(rawValue: lowercasedName) {
            return provider
        }
        
        for provider in ProviderIdentifier.allCases {
            if provider.rawValue.lowercased() == lowercasedName {
                return provider
            }
        }
        
        for provider in ProviderIdentifier.allCases {
            if provider.displayName.lowercased() == lowercasedName {
                return provider
            }
        }
        
        for provider in ProviderIdentifier.allCases {
            if provider.displayName.lowercased().contains(lowercasedName) {
                return provider
            }
        }
        
        return nil
    }
}

OpenCodeBar.main()
