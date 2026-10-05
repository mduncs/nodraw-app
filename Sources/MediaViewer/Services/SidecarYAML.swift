import Foundation
import Yams

/// Sidecars written before explicit offsets used local wall time.
enum SidecarYAML {
    static func load(yaml: String) throws -> Any? {
        try Yams.load(yaml: yaml, .default, constructor)
    }

    private static let constructor: Constructor = {
        // A custom scalar map replaces Yams' defaults rather than extending them.
        var scalars = Constructor.defaultScalarMap
        scalars[.timestamp] = { scalar in
            guard let date = Date.construct(from: scalar) else { return nil }
            // Keep Yams' full timestamp grammar, including short offsets like -6.
            if scalar.string.contains(":"),
               scalar.string.range(of: #"(?:Z|[-+][0-9]{1,2}(?::[0-9]{2})?)$"#, options: .regularExpression) != nil {
                return date
            }

            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(secondsFromGMT: 0)!
            var components = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            components.timeZone = TimeZone.current
            // Construct in the local zone so its offset is resolved for this date's DST.
            // Add the fraction separately to retain Yams' subsecond precision.
            let fraction = date.timeIntervalSinceReferenceDate - floor(date.timeIntervalSinceReferenceDate)
            return utc.date(from: components)?.addingTimeInterval(fraction)
        }
        return Constructor(scalars)
    }()
}
