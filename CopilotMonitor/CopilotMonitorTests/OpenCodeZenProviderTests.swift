import XCTest
@testable import OpenCode_Bar

final class OpenCodeZenProviderTests: XCTestCase {

    func testParseModelCostsReadsCurrentMultilineStatsFormat() {
        let output = #"""
        ┌────────────────────────────────────────────────────────┐
        │                      MODEL USAGE                       │
        ├────────────────────────────────────────────────────────┤
        │ opencode/gpt-5.5                                       │
        │  Messages                                        2,871 │
        │  Input Tokens                                    12.5M │
        │  Cost                                        $215.2045 │
        ├────────────────────────────────────────────────────────┤
        │ opencode-go/kimi-k2.6                                  │
        │  Messages                                           18 │
        │  Input Tokens                                   410.6K │
        │  Cost                                          $0.2251 │
        └────────────────────────────────────────────────────────┘
        """#

        let modelCosts = OpenCodeZenProvider.parseModelCosts(from: output)

        XCTAssertEqual(modelCosts["opencode/gpt-5.5"], 215.2045)
        XCTAssertEqual(modelCosts["opencode-go/kimi-k2.6"], 0.2251)
        XCTAssertEqual(modelCosts.count, 2)
    }

    func testParseModelMessagesReadsCurrentMultilineStatsFormat() {
        let output = #"""
        ┌────────────────────────────────────────────────────────┐
        │                      MODEL USAGE                       │
        ├────────────────────────────────────────────────────────┤
        │ opencode/gpt-5.5                                       │
        │  Messages                                        2,871 │
        │  Cost                                        $215.2045 │
        ├────────────────────────────────────────────────────────┤
        │ openrouter/google/gemini-3-flash-preview               │
        │  Messages                                           26 │
        │  Cost                                          $0.5563 │
        └────────────────────────────────────────────────────────┘
        """#

        let modelMessages = OpenCodeZenProvider.parseModelMessages(from: output)

        XCTAssertEqual(modelMessages["opencode/gpt-5.5"], 2_871)
        XCTAssertEqual(modelMessages["openrouter/google/gemini-3-flash-preview"], 26)
        XCTAssertEqual(modelMessages.count, 2)
    }

    func testParseModelCostsIgnoresCostRowsOutsideModelUsageSection() {
        let output = #"""
        ┌────────────────────────────────────────────────────────┐
        │                      MODEL USAGE                       │
        ├────────────────────────────────────────────────────────┤
        │ opencode/gpt-5.5                                       │
        │  Messages                                        2,871 │
        │  Cost                                        $215.2045 │
        ├────────────────────────────────────────────────────────┤
        │                       TOOL USAGE                       │
        ├────────────────────────────────────────────────────────┤
        │ mcp-server                                             │
        │  Calls                                                4 │
        │  Cost                                          $1.2300 │
        └────────────────────────────────────────────────────────┘
        """#

        let modelCosts = OpenCodeZenProvider.parseModelCosts(from: output)

        XCTAssertEqual(modelCosts["opencode/gpt-5.5"], 215.2045)
        XCTAssertNil(modelCosts["mcp-server"])
        XCTAssertEqual(modelCosts.count, 1)
    }

    func testAdjustStatsForDisplayKeepsOnlyOpenCodeZenProviderPrefixes() {
        let modelCosts = [
            "opencode/gpt-5.5": 2.0,
            "opencode-go/minimax-m2.7": 4.0,
            "anthropic/claude-opus-4-7": 15.0,
            "openrouter/google/gemini-3-flash-preview": 9.0,
            "openai/gpt-5.5-fast": 0.0
        ]
        let modelMessages = [
            "opencode/gpt-5.5": 1,
            "opencode-go/minimax-m2.7": 159,
            "anthropic/claude-opus-4-7": 2_848,
            "openrouter/google/gemini-3-flash-preview": 26
        ]

        let adjusted = OpenCodeZenProvider.adjustStatsForDisplay(
            totalCost: 30.0,
            avgCostPerDay: 10.0,
            modelCosts: modelCosts,
            modelMessages: modelMessages
        )

        XCTAssertEqual(adjusted.excludedCost, 24.0, accuracy: 0.0001)
        XCTAssertEqual(adjusted.totalCost, 6.0, accuracy: 0.0001)
        XCTAssertEqual(adjusted.avgCostPerDay, 2.0, accuracy: 0.0001)
        XCTAssertEqual(adjusted.messages, 160)
        XCTAssertEqual(adjusted.modelCosts.keys.sorted(), [
            "opencode-go/minimax-m2.7",
            "opencode/gpt-5.5"
        ])
    }

    func testAdjustStatsForDisplayReturnsZeroWhenStatsHaveNoZenModels() {
        let adjusted = OpenCodeZenProvider.adjustStatsForDisplay(
            totalCost: 22.0,
            avgCostPerDay: 3.142857,
            modelCosts: [
                "openai/gpt-5.4": 11.2679,
                "openai/gpt-5.4-mini": 3.7001,
                "nano-gpt/minimax/minimax-m2.5": 4.2045,
                "nano-gpt/zai-org/glm-5:thinking": 1.6042
            ]
        )

        XCTAssertEqual(adjusted.excludedCost, 0, accuracy: 0.0001)
        XCTAssertEqual(adjusted.totalCost, 22.0, accuracy: 0.0001)
        XCTAssertEqual(adjusted.avgCostPerDay, 3.142857, accuracy: 0.0001)
        XCTAssertEqual(adjusted.messages, 0)
        XCTAssertEqual(adjusted.modelCosts.count, 4)
    }

    func testFetchThrowsAuthenticationFailedWhenBinaryMissing() async {
        // Use a guaranteed non-existent injected path so the test is deterministic
        // regardless of whether opencode is installed on the host.
        let provider = OpenCodeZenProvider(injectedBinaryPath: URL(fileURLWithPath: "/dev/null/nonexistent/opencode"))

        do {
            _ = try await provider.fetch()
            XCTFail("Expected authentication failure")
        } catch let error as ProviderError {
            switch error {
            case .authenticationFailed(let message):
                XCTAssertTrue(message.lowercased().contains("not found") || message.lowercased().contains("not accessible"))
            default:
                XCTFail("Expected authenticationFailed, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFetchThrowsAuthenticationFailedWhenBinaryPathIsNotAccessible() async {
        let provider = OpenCodeZenProvider(injectedBinaryPath: URL(fileURLWithPath: "/nonexistent/opencode"))

        do {
            _ = try await provider.fetch()
            XCTFail("Expected authentication failure")
        } catch let error as ProviderError {
            switch error {
            case .authenticationFailed:
                break
            default:
                XCTFail("Expected authenticationFailed, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFetchThrowsAuthenticationFailedWhenStatsReportsAuthError() throws {
        let outputData = "Error: You are not authenticated. Run 'opencode login' first.".data(using: .utf8)!

        do {
            _ = try OpenCodeZenProvider.handleStatsOutput(outputData: outputData, exitStatus: 1)
            XCTFail("Expected authentication failure")
        } catch let error as ProviderError {
            switch error {
            case .authenticationFailed:
                break
            default:
                XCTFail("Expected authenticationFailed for CLI auth error, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFetchThrowsAuthenticationFailedForVariedCLILoginHints() throws {
        let loginHints = [
            "Error: No active session. Please run `opencode login`.",
            "Error: You must be logged in to use this feature.",
            "Unauthorized: token not found. Run opencode login to continue.",
            "Error: Session expired. Sign in required.",
            "Authentication required. Please login to opencode.",
            "Error: Credentials not found. Use 'opencode login'.",
            "Not signed in. Run \"opencode login\" first."
        ]

        for hint in loginHints {
            let outputData = hint.data(using: .utf8)!
            do {
                _ = try OpenCodeZenProvider.handleStatsOutput(outputData: outputData, exitStatus: 1)
                XCTFail("Expected authentication failure for: \(hint)")
            } catch let error as ProviderError {
                switch error {
                case .authenticationFailed:
                    break
                default:
                    XCTFail("Expected authenticationFailed for '\(hint)', got \(error)")
                }
            } catch {
                XCTFail("Unexpected error for '\(hint)': \(error)")
            }
        }
    }

    func testFetchThrowsProviderErrorForNonAuthCLIFailure() throws {
        let outputData = "Error: Unknown command 'stats'".data(using: .utf8)!

        do {
            _ = try OpenCodeZenProvider.handleStatsOutput(outputData: outputData, exitStatus: 1)
            XCTFail("Expected provider error")
        } catch let error as ProviderError {
            switch error {
            case .providerError:
                break
            default:
                XCTFail("Expected providerError for non-auth CLI failure, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testIsOpenCodeZenModelMatchesOnlyZenProviderPrefixes() {
        XCTAssertTrue(OpenCodeZenProvider.isOpenCodeZenModel("opencode/gpt-5.5"))
        XCTAssertTrue(OpenCodeZenProvider.isOpenCodeZenModel(" opencode-go/minimax-m2.7 "))
        XCTAssertFalse(OpenCodeZenProvider.isOpenCodeZenModel("openai/gpt-5.5"))
        XCTAssertFalse(OpenCodeZenProvider.isOpenCodeZenModel("openrouter/opencode/gpt-5.5"))
        XCTAssertFalse(OpenCodeZenProvider.isOpenCodeZenModel("nano-gpt/minimax/minimax-m2.5"))
    }

    func testParseRealStatsOutput() {
        let output = """
        ┌────────────────────────────────────────────────────────┐
        │                       OVERVIEW                         │
        ├────────────────────────────────────────────────────────┤
        │Sessions                                            129 │
        │Messages                                          4,972 │
        │Days                                                  7 │
        └────────────────────────────────────────────────────────┘

        ┌────────────────────────────────────────────────────────┐
        │                    COST & TOKENS                       │
        ├────────────────────────────────────────────────────────┤
        │Total Cost                                       $12.20 │
        │Avg Cost/Day                                      $1.74 │
        │Avg Tokens/Session                                 8.2M │
        │Median Tokens/Session                            730.1K │
        │Input                                             27.4M │
        │Output                                             1.2M │
        │Cache Read                                      1034.3M │
        │Cache Write                                           0 │
        └────────────────────────────────────────────────────────┘

        ┌────────────────────────────────────────────────────────┐
        │                      MODEL USAGE                       │
        ├────────────────────────────────────────────────────────┤
        │ xiaomi-token-plan-cn/mimo-v2.5-pro                     │
        │  Messages                                        3,820 │
        │  Input Tokens                                    19.7M │
        │  Output Tokens                                    1.5M │
        │  Cache Read                                     913.9M │
        │  Cache Write                                         0 │
        │  Cost                                          $0.0000 │
        ├────────────────────────────────────────────────────────┤
        │ opencode-go/deepseek-v4-pro                            │
        │  Messages                                          343 │
        │  Input Tokens                                     5.0M │
        │  Output Tokens                                  195.4K │
        │  Cache Read                                      84.6M │
        │  Cache Write                                         0 │
        │  Cost                                         $10.5374 │
        ├────────────────────────────────────────────────────────┤
        │ opencode-go/minimax-m3                                 │
        │  Messages                                          184 │
        │  Input Tokens                                     1.4M │
        │  Output Tokens                                   47.3K │
        │  Cache Read                                      15.0M │
        │  Cache Write                                         0 │
        │  Cost                                          $0.4671 │
        ├────────────────────────────────────────────────────────┤
        │ opencode-go/deepseek-v4-flash                          │
        │  Messages                                           58 │
        │  Input Tokens                                   299.0K │
        │  Output Tokens                                   26.8K │
        │  Cache Read                                      14.8M │
        │  Cache Write                                         0 │
        │  Cost                                          $0.0909 │
        ├────────────────────────────────────────────────────────┤
        │ minimax-cn/MiniMax-M3                                  │
        │  Messages                                           46 │
        │  Input Tokens                                   778.1K │
        │  Output Tokens                                   18.7K │
        │  Cache Read                                       4.5M │
        │  Cache Write                                         0 │
        │  Cost                                          $0.5261 │
        ├────────────────────────────────────────────────────────┤
        │ opencode-go/mimo-v2.5-pro                              │
        │  Messages                                           29 │
        │  Input Tokens                                   310.7K │
        │  Output Tokens                                    5.1K │
        │  Cache Read                                       1.4M │
        │  Cache Write                                         0 │
        │  Cost                                          $0.5794 │
        ├────────────────────────────────────────────────────────┤
        │ xiaomi/mimo-v2.5-pro                                   │
        │  Messages                                            3 │
        │  Input Tokens                                        0 │
        │  Output Tokens                                        0 │
        │  Cache Read                                          0 │
        │  Cache Write                                         0 │
        │  Cost                                          $0.0000 │
        ├────────────────────────────────────────────────────────┤
        \u{001B}[1A└────────────────────────────────────────────────────────┘

        ┌────────────────────────────────────────────────────────┐
        │                      TOOL USAGE                        │
        ├────────────────────────────────────────────────────────┤
        │ bash               ████████████████████ 2228 (41.0%)   │
        └────────────────────────────────────────────────────────┘
        """

        let modelCosts = OpenCodeZenProvider.parseModelCosts(from: output)
        let modelMessages = OpenCodeZenProvider.parseModelMessages(from: output)

        XCTAssertEqual(modelCosts["opencode-go/deepseek-v4-pro"] ?? -1, 10.5374, accuracy: 0.0001)
        XCTAssertEqual(modelCosts["opencode-go/minimax-m3"] ?? -1, 0.4671, accuracy: 0.0001)
        XCTAssertEqual(modelCosts["opencode-go/deepseek-v4-flash"] ?? -1, 0.0909, accuracy: 0.0001)
        XCTAssertEqual(modelCosts["opencode-go/mimo-v2.5-pro"] ?? -1, 0.5794, accuracy: 0.0001)

        let adjusted = OpenCodeZenProvider.adjustStatsForDisplay(
            totalCost: 12.20,
            avgCostPerDay: 1.74,
            modelCosts: modelCosts,
            modelMessages: modelMessages
        )
        XCTAssertEqual(adjusted.totalCost, 11.6748, accuracy: 0.0001)
        XCTAssertEqual(adjusted.messages, 614)
    }

    func testIdentifyStaleOpenCodeStatsPidsHandlesLargeProcessList() {
        // Reproduce the original deadlock conditions: a process list larger than the
        // 64KB pipe buffer. The parser must return quickly and identify only the
        // matching stale `opencode stats` processes.
        var lines: [String] = []

        // Targets: stale `opencode stats` processes that should be reaped.
        lines.append("12345 7200 /usr/local/bin/opencode stats --days 7 --models")
        lines.append("12346 3600 /Users/test/.opencode/bin/opencode stats")
        lines.append("12347 999999 /opt/homebrew/bin/opencode stats --models")

        // Decoys that must be ignored.
        lines.append("10001 3599 /usr/local/bin/opencode stats --days 7") // not stale yet
        lines.append("10002 7200 /usr/local/bin/opencode status")          // not `stats`
        lines.append("10003 7200 /usr/local/bin/node server.js")            // not opencode
        lines.append("10004 7200 /usr/local/bin/opencode login")           // not `stats`

        // Pad the list with filler so the total output comfortably exceeds a 64KB pipe.
        var fillerIndex = 0
        var fillerSize = 0
        let targetSize = 150_000
        while fillerSize < targetSize {
            let filler = "99999\(fillerIndex) 100 /usr/bin/very/long/process/path/number/\(fillerIndex) --with --many --arguments --to --pad --the --output --and --ensure --we --exceed --64kb --pipe --buffer --limit --deadlock --reproduction"
            lines.append(filler)
            fillerSize += filler.utf8.count
            fillerIndex += 1
        }

        let output = lines.joined(separator: "\n")
        XCTAssertGreaterThan(output.utf8.count, 65_536, "Test input should exceed a 64KB pipe buffer")

        let selfPid = Int32(42) // Use a PID that does not collide with target/decoy PIDs.
        let stalePids = OpenCodeZenProvider.identifyStaleOpenCodeStatsPids(
            in: output,
            staleThresholdSeconds: 3600,
            selfPid: selfPid
        )

        XCTAssertEqual(stalePids.map(\.pid).sorted(), [12345, 12346, 12347])
        XCTAssertTrue(stalePids.allSatisfy { $0.etimes >= 3600 }, "All returned processes should be stale")
    }

    func testRunSynchronousCommandHandlesLargeOutputWithoutDeadlock() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/seq")
        process.arguments = ["1", "100000"]

        let start = Date()
        let output = OpenCodeZenProvider.runSynchronousCommand(process: process)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertNotNil(output)
        XCTAssertLessThan(elapsed, 5.0, "Synchronous command should complete without deadlocking")
        XCTAssertGreaterThan(output?.utf8.count ?? 0, 65_536, "Output should exceed a 64KB pipe buffer")
        XCTAssertTrue(output?.contains("100000") ?? false)
    }

    func testRunSynchronousCommandReturnsNilOnFailure() {
        let output = OpenCodeZenProvider.runSynchronousCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/false"),
            arguments: []
        )
        XCTAssertNil(output)
    }

    func testFindBinaryViaWhichFindsKnownCommand() {
        let path = OpenCodeZenProvider.findBinary(named: "ls", usingWhich: true)
        XCTAssertNotNil(path)
        XCTAssertEqual(path?.path, "/bin/ls")
    }

    func testFindBinaryViaWhichReturnsNilForMissingCommand() {
        let path = OpenCodeZenProvider.findBinary(
            named: "definitely_not_a_real_command_12345",
            usingWhich: true
        )
        XCTAssertNil(path)
    }

    func testFindBinaryViaLoginShellFindsKnownCommand() {
        let path = OpenCodeZenProvider.findBinary(named: "ls", usingWhich: false)
        XCTAssertNotNil(path)
        XCTAssertEqual(path?.path, "/bin/ls")
    }

    func testFindBinaryViaLoginShellReturnsNilForMissingCommand() {
        let path = OpenCodeZenProvider.findBinary(
            named: "definitely_not_a_real_command_12345",
            usingWhich: false
        )
        XCTAssertNil(path)
    }

    func testFindBinaryViaWhichFindsBinaryInCustomPath() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode_zen_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let fakeBinary = tempDir.appendingPathComponent("opencode_test_binary")
        let script = "#!/bin/sh\necho hello\n"
        try script.write(to: fakeBinary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeBinary.path)

        let path = OpenCodeZenProvider.findBinary(
            named: "opencode_test_binary",
            usingWhich: true,
            environment: ["PATH": tempDir.path]
        )

        XCTAssertNotNil(path)
        XCTAssertEqual(path?.path, fakeBinary.path)
    }

    func testFindBinaryViaLoginShellFindsBinaryInCustomPath() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode_zen_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let fakeBinary = tempDir.appendingPathComponent("opencode_test_binary")
        let script = "#!/bin/sh\necho hello\n"
        try script.write(to: fakeBinary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeBinary.path)

        let path = OpenCodeZenProvider.findBinary(
            named: "opencode_test_binary",
            usingWhich: false,
            environment: ["PATH": tempDir.path]
        )

        XCTAssertNotNil(path)
        XCTAssertEqual(path?.path, fakeBinary.path)
    }

    func testFindBinaryViaWhichHelperFindsOpenCode() {
        let provider = OpenCodeZenProvider()
        let start = Date()
        let path = provider.findBinaryViaWhich()
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 5.0, "Helper should not deadlock")
        if let path = path {
            XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        }
    }

    func testFindBinaryViaLoginShellHelperFindsOpenCode() {
        let provider = OpenCodeZenProvider()
        let start = Date()
        let path = provider.findBinaryViaLoginShell()
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 5.0, "Helper should not deadlock")
        if let path = path {
            XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        }
    }
}
