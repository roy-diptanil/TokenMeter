import Foundation

/// Menu-bar label model: remaining % for the (up to) two most-constrained accounts.
public struct LabelSegment: Equatable {
    public enum Level: Equatable { case normal, amber, red }
    public var text: String        // e.g. "C 21%"
    public var remaining: Double   // 0...100
    public var level: Level
    public var isAlert = false     // the trailing "!" marking an account that needs sign-in
    public init(text: String, remaining: Double, level: Level, isAlert: Bool = false) {
        self.text = text; self.remaining = remaining; self.level = level; self.isAlert = isAlert
    }
}

public enum MenuLabelLogic {
    public static func level(remaining r: Double) -> LabelSegment.Level { r <= 10 ? .red : (r <= 25 ? .amber : .normal) }

    public static func build(accounts: [Account], snapshots: [String: AccountSnapshot], limit: Int = 2) -> [LabelSegment] {
        struct Item { var a: Account; var remaining: Double; var order: Int }
        var items: [Item] = []
        for (i, a) in accounts.enumerated() {
            guard let used = snapshots[a.id]?.cap?.percent, used.isFinite else { continue }
            items.append(Item(a: a, remaining: min(max(100 - used, 0), 100), order: i))
        }
        // lowest remaining first; ties keep registry order
        items.sort { $0.remaining != $1.remaining ? $0.remaining < $1.remaining : $0.order < $1.order }
        let top = Array(items.prefix(limit))
        let letters = letters(for: top.map(\.a))
        return zip(top, letters).map { it, l in
            LabelSegment(text: "\(l) \(Int(it.remaining.rounded()))%", remaining: it.remaining, level: level(remaining: it.remaining))
        }
    }

    /// Segment letters: kind letter; on a clash label initials; if those clash too (or are empty), kind letter + position.
    static func letters(for accts: [Account]) -> [String] {
        func kindLetter(_ k: AccountKind) -> String { k == .claude ? "C" : "X" }
        let letters = accts.map { kindLetter($0.kind) }
        guard Set(letters).count < letters.count else { return letters }
        let initials = accts.map { String($0.label.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased() }
        return Set(initials).count == initials.count && !initials.contains("")
            ? initials : letters.enumerated().map { "\($0.element)\($0.offset + 1)" }
    }

    public static let maxSelected = 3

    /// The user's chosen accounts (up to 3), in registry order, whatever their remaining %. Accounts with no data show "C --".
    /// Ids of accounts that no longer exist are ignored.
    public static func buildSelected(accounts: [Account], snapshots: [String: AccountSnapshot], selectedIDs: [String]) -> [LabelSegment] {
        let chosen = Array(accounts.filter { selectedIDs.contains($0.id) }.prefix(maxSelected))
        return zip(chosen, letters(for: chosen)).map { a, l in
            if let used = snapshots[a.id]?.cap?.percent, used.isFinite {
                let rem = min(max(100 - used, 0), 100)
                return LabelSegment(text: "\(l) \(Int(rem.rounded()))%", remaining: rem, level: level(remaining: rem))
            }
            return LabelSegment(text: "\(l) --", remaining: 100, level: .normal)
        }
    }

    public static func text(_ s: [LabelSegment]) -> String {
        let t = s.filter { !$0.isAlert }.map(\.text).joined(separator: " · ")
        guard s.contains(where: \.isAlert) else { return t }
        return t.isEmpty ? "!" : t + " !"
    }
}
