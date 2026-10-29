import Foundation

/// Consecutive calls with the same number and the same kind of outcome, shown as one row: "Ali (3)".
struct RecentGroup: Identifiable, Hashable {
    let records: [CallRecord]
    var id: UUID { records[0].id }
    var latest: CallRecord { records[0] }
    var ids: Set<UUID> { Set(records.map(\.id)) }

    static func == (a: RecentGroup, b: RecentGroup) -> Bool { a.records.map(\.id) == b.records.map(\.id) }
    func hash(into hasher: inout Hasher) { hasher.combine(records.map(\.id)) }

    /// `records` newest first, as `CallLog` keeps them. A call without a number (private caller) never joins another.
    static func group(_ records: [CallRecord]) -> [RecentGroup] {
        var groups: [[CallRecord]] = []
        for record in records {
            if let last = groups.last?.first, !record.number.isEmpty, last.number == record.number,
               last.isMissed == record.isMissed, last.direction == record.direction {
                groups[groups.count - 1].append(record)
            } else {
                groups.append([record])
            }
        }
        return groups.map(RecentGroup.init)
    }
}
