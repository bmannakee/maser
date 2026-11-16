// Tests for the words saying how long ago the Overview's data was loaded.

import Foundation
import Testing

@testable import MaserCore

/// Tests for `LoadedAge`.
@Suite struct LoadedAgeTests {
    /// A fixed load time, so the tests don't depend on the clock.
    private static let loadedAt = Date(timeIntervalSince1970: 1_794_500_000)

    /// The text `seconds` after the load.
    private static func text(after seconds: TimeInterval) -> String {
        LoadedAge.text(loadedAt: loadedAt, now: loadedAt + seconds, timeZone: TimeZone(identifier: "UTC") ?? .gmt)
    }

    @Test("REQ-OVR-005: Says how long ago the data was loaded, to the minute and then the hour") func wording() {
        #expect(Self.text(after: 0) == "Loaded just now")
        #expect(Self.text(after: 59) == "Loaded just now")
        #expect(Self.text(after: 60) == "Loaded 1 minute ago")
        #expect(Self.text(after: 119) == "Loaded 1 minute ago")
        #expect(Self.text(after: 180) == "Loaded 3 minutes ago")
        #expect(Self.text(after: 59 * 60 + 59) == "Loaded 59 minutes ago")
        #expect(Self.text(after: 60 * 60) == "Loaded 1 hour ago")
        #expect(Self.text(after: 2 * 60 * 60) == "Loaded 2 hours ago")
        #expect(Self.text(after: 24 * 60 * 60 - 1) == "Loaded 23 hours ago")
    }

    @Test("REQ-OVR-005: Gives the date from a day on, and never a time in the future") func edges() {
        let day = Self.text(after: 24 * 60 * 60)
        #expect(day.hasPrefix("Loaded on ") && day.contains("2026") && day.contains(" at "))
        #expect(Self.text(after: -300) == "Loaded just now")
    }
}
