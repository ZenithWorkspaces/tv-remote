import Foundation

enum Runtime {
    /// The unit-test host loads XCTest. Skip network scans there so CI stays quiet.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }
}
