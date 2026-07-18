import Foundation

enum CodexScratchWorkspaceDetector {
    static func sessionRoot(for path: String) -> String? {
        guard (path as NSString).isAbsolutePath else { return nil }

        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let components = (normalizedPath as NSString).pathComponents
        var detectedRoot: String?

        for codexIndex in components.indices where components[codexIndex] == "Codex" {
            let dateIndex = codexIndex + 1
            let sessionIndex = codexIndex + 2
            guard sessionIndex < components.count,
                isValidDateComponent(components[dateIndex])
            else { continue }

            detectedRoot = NSString.path(
                withComponents: Array(components[...sessionIndex])
            )
        }

        return detectedRoot
    }

    private static func isValidDateComponent(_ component: String) -> Bool {
        let parts = component.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
            parts[0].count == 4,
            parts[1].count == 2,
            parts[2].count == 2,
            let year = Int(parts[0]),
            let month = Int(parts[1]),
            let day = Int(parts[2])
        else { return false }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day
        )
        guard let date = calendar.date(from: components) else { return false }
        let resolved = calendar.dateComponents([.year, .month, .day], from: date)
        return resolved.year == year && resolved.month == month && resolved.day == day
    }
}
