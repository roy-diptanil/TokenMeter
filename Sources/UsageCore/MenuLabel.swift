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
        func kindLetter(_ k: AccountKind) -> String { k == .claude ? "C" : "X" }
        var letters = top.map { kindLetter($0.a.kind) }
        if Set(letters).count < letters.count {   // same kind twice: disambiguate by label initial, then by digit
            let initials = top.map { String($0.a.label.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased() }
            letters = Set(initials).count == initials.count && !initials.contains("")
                ? initials : letters.enumerated().map { "\($0.element)\($0.offset + 1)" }
        }
        return zip(top, letters).map { it, l in
            LabelSegment(text: "\(l) \(Int(it.remaining.rounded()))%", remaining: it.remaining, level: level(remaining: it.remaining))
        }
    }

    public static func text(_ s: [LabelSegment]) -> String {
        let t = s.filter { !$0.isAlert }.map(\.text).joined(separator: " · ")
        guard s.contains(where: \.isAlert) else { return t }
        return t.isEmpty ? "!" : t + " !"
    }
}
