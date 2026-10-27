import Foundation

nonisolated enum LyricEmphasisTiming {
    static let releaseLeadMs = 120
    struct Entry: Equatable, Sendable { let index: Int; let start: Int; let end: Int }

    static func entries(rows: [LyricDisplayRow]) -> [Entry] {
        let ordered = rows.indices.filter {
            rows[$0].startMs != nil && !rows[$0].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.sorted { rows[$0].startMs! == rows[$1].startMs! ? $0 < $1 : rows[$0].startMs! < rows[$1].startMs! }
        return ordered.compactMap { index in
            let row = rows[index]
            guard let start = row.startMs else { return nil }
            let next = ordered.first { candidate in
                let other = rows[candidate]
                return !other.isSecondaryAgent && other.streamKey == row.streamKey && other.startMs! > start
            }.flatMap { rows[$0].startMs }
            let sourceEnd = row.endMs ?? next ?? start + 9_000
            var end = sourceEnd
            if !row.isSecondaryAgent, let next, next - sourceEnd < 7_000 {
                // Keep short inter-phrase gaps bright, but complete the fade before
                // the following lead starts. Duets and backing retain separate clocks.
                end = max(start + 1, next - releaseLeadMs)
            }
            return end > start ? Entry(index: index, start: start, end: end) : nil
        }
    }
}
