import Foundation

/// Only timings and counters; no command names, arguments, paths, or environments.
enum Diagnostics {
    private static var samples: [String: [Double]] = [:]
    private static let names: Set<String> = ["parse_ms", "suggestion_ms", "generator_ms", "caret_ms"]
    private static var counters: [String: Int] = [:]
    static func record(_ name: String, value: Double) {
        guard names.contains(name), value.isFinite, value >= 0, value <= 120000 else { return }
        var values = samples[name, default: []]
        values.append(value)
        if values.count > 200 { values.removeFirst(values.count - 200) }
        samples[name] = values
    }
    static func increment(_ name: String) { counters[name, default: 0] += 1 }
    static func summary() -> String {
        let timings = samples.keys.sorted().map { name -> String in
            let values = samples[name]!.sorted()
            let median = values[min(values.count - 1, values.count / 2)]
            let p95 = values[min(values.count - 1, Int(Double(values.count - 1) * 0.95))]
            return "\(name): p50 \(Int(median)) ms, p95 \(Int(p95)) ms (\(values.count) samples)"
        }
        return (timings + counters.keys.sorted().map { "\($0): \(counters[$0]!)" }).joined(separator: "\n")
    }
}
