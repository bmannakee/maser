// How old the data on screen is, in words: "Loaded 3 minutes ago".
//
// The Overview shows when its data was loaded, so the user can tell how old the checks, mergeability and conversation
// are before deciding on them (HAZ-11). The wording is here, rather than in the view, so it can be tested; the view
// asks for it again each minute after the load.

import Foundation

/// Words for how long ago data was loaded.
public enum LoadedAge {
    /// Describes how long ago something was loaded, to the minute below an hour and to the hour below a day.
    ///
    /// Under a minute is "just now". From a day on, it gives the date and time instead, as "on Nov 12, 2026 at 2:06 PM".
    /// A load time after `now`, from a clock change, counts as just now.
    ///
    /// - Parameters:
    ///   - loadedAt: When the data was loaded.
    ///   - now: The time to measure from.
    ///   - timeZone: The time zone for a date, the current one unless a test sets it.
    /// - Returns: Text such as "Loaded just now" or "Loaded 3 minutes ago".
    public static func text(loadedAt: Date, now: Date, timeZone: TimeZone = .current) -> String {
        let seconds = max(0, now.timeIntervalSince(loadedAt))
        let minutes = Int(seconds / 60)
        let hours = minutes / 60
        switch minutes {
        case 0: return "Loaded just now"
        case 1: return "Loaded 1 minute ago"
        case 2..<60: return "Loaded \(minutes) minutes ago"
        case 60..<120: return "Loaded 1 hour ago"
        case 120..<(24 * 60): return "Loaded \(hours) hours ago"
        default:
            var date = Date.FormatStyle(date: .abbreviated, time: .omitted)
            var time = Date.FormatStyle(date: .omitted, time: .shortened)
            date.timeZone = timeZone
            time.timeZone = timeZone
            return "Loaded on \(loadedAt.formatted(date)) at \(loadedAt.formatted(time))"
        }
    }
}
