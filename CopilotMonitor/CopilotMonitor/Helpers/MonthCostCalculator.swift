import Foundation

/// Monthly cost-equivalent calculation (F2b Layer 4).
///
/// Formula:
///     costRMB = (input * inputRate + output * outputRate + cacheRead * cacheReadRate) / 1e6
/// where `*Rate` is the F2a `PayAsYouGoRate` value in RMB per million tokens.
///
/// `cacheWrite` is intentionally excluded (5 reference consensus:
/// Anthropic prompt cache writes are free; OpenAI cache-write cost is simplified away).
///
/// Lookup is by `(provider, model)`. Only representative models (the same models
/// PricingTable documents in its source comments) return a cost. Unknown models
/// return `nil` so the UI can display "Unknown" without blocking other fields.
struct MonthCostCalculator {

    /// `PricingTable.Type`: passes the metatype so the static call site
    /// `pricingTable.rate(for: providerId)` resolves to F2a's static method,
    /// even though PricingTable is a no-cases enum and cannot be instantiated
    /// as a value. Default keeps call sites terse; tests can override.
    let pricingTable: PricingTable.Type

    init(pricingTable: PricingTable.Type = PricingTable.self) {
        self.pricingTable = pricingTable
    }

    /// Compute the cost-equivalent for a single month_aggregate.
    ///
    /// Returns `nil` when:
    /// - the provider string is not one of the 5 known F2b providers,
    /// - the model does not match the representative model for that provider,
    /// - F2a PricingTable has no public rate for that provider
    ///   (e.g. `.copilot` Premium-request model).
    func calculate(provider: String, model: String, tokens: TokenBreakdown) -> Double? {
        guard let providerId = providerStringToIdentifier(provider) else { return nil }
        guard Self.representativeModel[providerId] == model else { return nil }
        guard let rate = pricingTable.rate(for: providerId),
              rate.input > 0 || rate.output > 0
        else { return nil }

        let inputCost = Double(tokens.input) * rate.input / 1_000_000
        let outputCost = Double(tokens.output) * rate.output / 1_000_000
        let cacheReadCost = Double(tokens.cacheRead) * (rate.cache ?? 0) / 1_000_000
        return inputCost + outputCost + cacheReadCost
    }

    /// Aggregate `month_aggregates` into a per-provider `MonthlyTotal`.
    /// Aggregates with unknown pricing are still preserved in `modelBreakdown`
    /// (with `costRMB == nil`) and `hasUnknownPricing` is set to `true`
    /// on the provider total when at least one aggregate is unknown.
    func calculateMonthlyTotals(_ aggregates: [MonthAggregate]) -> [MonthlyTotal] {
        var totals: [String: MonthlyTotal] = [:]
        for agg in aggregates {
            let cost = calculate(provider: agg.provider, model: agg.model, tokens: agg.tokens)
            let existing = totals[agg.provider]
            totals[agg.provider] = MonthlyTotal(
                provider: agg.provider,
                modelBreakdown: (existing?.modelBreakdown ?? []) + [
                    ModelCost(model: agg.model, tokens: agg.tokens, costRMB: cost)
                ],
                totalTokens: (existing?.totalTokens ?? TokenBreakdown())
                    .adding(agg.tokens),
                totalCostRMB: (existing?.totalCostRMB ?? 0) + (cost ?? 0),
                hasUnknownPricing: (existing?.hasUnknownPricing ?? false) || (cost == nil)
            )
        }
        return Array(totals.values)
    }

    /// F2a `PricingTable.rate(for:)` accepts `ProviderIdentifier`
    /// (`.kimi / .kimiCN / .claude / .zaiCodingPlan / .nanoGpt / .codex`).
    /// `MonthAggregate.provider` is a `String` (read from SQLite via `TokenUsageStore`).
    ///
    /// The "zai" string is F2b `Provider.zai.rawValue`; it must bridge to F2a's
    /// `ProviderIdentifier.zaiCodingPlan` — they are distinct enums.
    private func providerStringToIdentifier(_ s: String) -> ProviderIdentifier? {
        switch s.lowercased() {
        case "kimi":    return .kimi
        case "claude":  return .claude
        case "codex":   return .codex
        case "zai":     return .zaiCodingPlan
        case "nanogpt": return .nanoGpt
        default:        return nil
        }
    }

    /// Representative model name per provider. Source: F2a `PricingTable.swift`
    /// line 33-96 in-line docs (one rate per provider, attributed to a single
    /// representative model). When F2a updates its representative model, this
    /// mapping must be updated to match.
    private static let representativeModel: [ProviderIdentifier: String] = [
        .kimi:          "kimi-k2.6",
        .kimiCN:        "kimi-k2.6",
        .claude:        "claude-sonnet-4-5",
        .zaiCodingPlan: "glm-4.6",
        .nanoGpt:       "gpt-4o",
        .codex:         "gpt-4o",
    ]
}

/// Per-provider monthly rollup. One entry per `Provider` raw value seen in
/// `month_aggregates`. `modelBreakdown` preserves every (model, tokens, costRMB)
/// triple for UI display; `hasUnknownPricing` is true iff any single model
/// in the breakdown had no F2a PricingTable rate.
struct MonthlyTotal {
    let provider: String
    let modelBreakdown: [ModelCost]
    let totalTokens: TokenBreakdown
    let totalCostRMB: Double
    let hasUnknownPricing: Bool
}

/// Per-model rollup row inside a `MonthlyTotal.modelBreakdown`.
/// `costRMB == nil` signals that the model had no representative rate in
/// PricingTable, so the row contributes to `hasUnknownPricing` but not to
/// `totalCostRMB`.
struct ModelCost {
    let model: String
    let tokens: TokenBreakdown
    let costRMB: Double?
}

extension TokenBreakdown {
    /// Component-wise add. Used by `MonthCostCalculator.calculateMonthlyTotals`
    /// to roll up per-(provider, model) tokens into the per-provider total.
    func adding(_ other: TokenBreakdown) -> TokenBreakdown {
        TokenBreakdown(
            input: input + other.input,
            output: output + other.output,
            cacheRead: cacheRead + other.cacheRead,
            cacheWrite: cacheWrite + other.cacheWrite,
            reasoning: reasoning + other.reasoning
        )
    }
}
