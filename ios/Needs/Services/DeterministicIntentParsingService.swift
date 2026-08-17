import Foundation

public actor DeterministicIntentParsingService: IntentParsingService {
    private struct CategoryRule: Sendable {
        let category: String
        let terms: [String]
        let normalizedName: String
    }

    private let rules: [CategoryRule] = [
        .init(category: "trash_bags", terms: ["trash bag", "garbage bag", "bin bag"], normalizedName: "trash bags"),
        .init(category: "toothpaste", terms: ["toothpaste"], normalizedName: "toothpaste"),
        .init(category: "toilet_paper", terms: ["toilet paper", "bath tissue"], normalizedName: "toilet paper"),
        .init(category: "eggs", terms: ["egg"], normalizedName: "eggs"),
        .init(category: "milk", terms: ["milk"], normalizedName: "milk"),
        .init(category: "bottled_water", terms: ["bottled water", "water bottle"], normalizedName: "bottled water"),
        .init(category: "paper_towels", terms: ["paper towel"], normalizedName: "paper towels"),
        .init(category: "dish_soap", terms: ["dish soap", "dishwashing liquid"], normalizedName: "dish soap"),
        .init(category: "laundry_detergent", terms: ["laundry detergent", "washing detergent"], normalizedName: "laundry detergent"),
        .init(category: "shampoo", terms: ["shampoo"], normalizedName: "shampoo"),
        .init(category: "batteries", terms: ["battery", "batteries"], normalizedName: "batteries"),
        .init(category: "pasta", terms: ["pasta", "spaghetti", "penne"], normalizedName: "pasta"),
        .init(category: "coffee", terms: ["coffee"], normalizedName: "coffee")
    ]

    public init() {}

    public func parse(_ text: String) async throws -> NeedIntent {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AppError.invalidInput("Need text is empty") }
        let lower = trimmed.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let rule = rules.first { rule in rule.terms.contains { lower.contains($0) } }
        let category = rule?.category ?? slug(from: lower)
        let baseName = rule?.normalizedName ?? trimmed.lowercased()
        var attributes: [String: String] = [:]

        if containsAny(lower, ["large", "big", "tall"]) { attributes["size"] = "large" }
        if containsAny(lower, ["small", "compact"]) { attributes["size"] = "small" }
        if lower.contains("black") { attributes["color"] = "black" }
        if lower.contains("white") { attributes["color"] = "white" }
        if containsAny(lower, ["strong", "durable", "won't rip", "wont rip", "heavy duty"]) {
            attributes["durability"] = "high"
        }
        if containsAny(lower, ["sensitive", "sensitivity"]) { attributes["benefit"] = "sensitivity" }
        if lower.contains("whitening") { attributes["benefit"] = "whitening" }
        if lower.contains("organic") { attributes["organic"] = "true" }
        if containsAny(lower, ["whole milk", "full fat"]) { attributes["fat"] = "whole" }
        if lower.contains("2%") { attributes["fat"] = "2_percent" }
        if lower.contains("aa ") || lower.hasSuffix("aa") { attributes["battery_size"] = "AA" }
        if lower.contains("aaa") { attributes["battery_size"] = "AAA" }

        var clarification: ClarificationQuestion?
        if category == "batteries", attributes["battery_size"] == nil {
            clarification = ClarificationQuestion(
                prompt: "Which size?",
                options: ["AA", "AAA", "Other"],
                attributeKey: "battery_size"
            )
        }

        let normalizedAttributes = attributes.values.sorted().joined(separator: " ")
        let normalizedQuery = [normalizedAttributes, baseName].filter { !$0.isEmpty }.joined(separator: " ")
        return NeedIntent(
            category: category,
            normalizedQuery: normalizedQuery,
            attributes: attributes,
            quantity: inferredQuantity(from: lower),
            confidence: rule == nil ? 0.58 : 0.95,
            clarification: clarification
        )
    }

    private func containsAny(_ value: String, _ options: [String]) -> Bool {
        options.contains { value.contains($0) }
    }

    private func inferredQuantity(from text: String) -> Int {
        let words = text.split(whereSeparator: { !$0.isNumber })
        guard let raw = words.first, let quantity = Int(raw), (1...99).contains(quantity) else { return 1 }
        return quantity
    }

    private func slug(from text: String) -> String {
        let words = text
            .replacingOccurrences(of: "i need", with: "")
            .replacingOccurrences(of: "get me", with: "")
            .replacingOccurrences(of: "we're out of", with: "")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .prefix(4)
        let slug = words.joined(separator: "_")
        return slug.isEmpty ? "other" : slug
    }
}
