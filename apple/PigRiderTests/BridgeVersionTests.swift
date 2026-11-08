import Foundation
import Testing

@Test func bridgeVersionIsBundledAsAPositiveInteger() throws {
    let url = try #require(Bundle.main.url(forResource: "BRIDGE_VERSION", withExtension: nil))
    let text = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect((Int(text) ?? 0) > 0)
}
