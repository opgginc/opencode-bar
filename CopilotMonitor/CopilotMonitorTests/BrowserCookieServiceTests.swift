import XCTest
@testable import OpenCode_Bar

final class BrowserCookieServiceTests: XCTestCase {
    func testRunProcessAndReadStdoutHandlesLargeOutputWithoutDeadlock() throws {
        let service = BrowserCookieService.shared
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        let expectedLength = 128 * 1024
        process.arguments = ["-c", "printf '%*s' \(expectedLength) '' | tr ' ' 'A'"]

        let data = try service.runProcessAndReadStdout(process)

        XCTAssertEqual(data.count, expectedLength)
        XCTAssertEqual(String(data: data, encoding: .utf8), String(repeating: "A", count: expectedLength))
    }

    func testRunProcessAndReadStdoutThrowsOnNonzeroExit() {
        let service = BrowserCookieService.shared
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "exit 1"]

        XCTAssertThrowsError(try service.runProcessAndReadStdout(process)) { error in
            guard let cookieError = error as? BrowserCookieError,
                  case .keychainAccessFailed = cookieError else {
                XCTFail("Expected keychainAccessFailed, got \(error)")
                return
            }
        }
    }
}
