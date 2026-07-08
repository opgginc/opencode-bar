import Foundation

/// 30s tick 增量刷新 (F2b Layer 3 协调).
/// 7 个 TokenExtractor 并发触发 → 归一化 → 写 Store → 重算 month_aggregates.
actor RefreshActor {
    private let store: TokenUsageStore
    private let calc: MonthCostCalculator
    private let extractors: [TokenExtractorProtocol]
    private var tickTask: Task<Void, Never>?
    private let intervalSeconds: UInt64

    init(store: TokenUsageStore, pricingTable: PricingTable.Type = PricingTable.self,
         intervalSeconds: UInt64 = 30) {
        self.store = store
        self.calc = MonthCostCalculator(pricingTable: pricingTable)
        self.intervalSeconds = intervalSeconds
        self.extractors = [
            OpenCodeExtractor(),
            ClaudeCodeExtractor(),
            CodexExtractor(),
            KimiCLILegacyExtractor(),
            KimiCodeExtractor(),
            ZAIExtractor(),
            NanoGPTExtractor(),
        ]
    }

    func start() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: intervalSeconds * 1_000_000_000)
            }
        }
    }

    func stop() {
        tickTask?.cancel()
        tickTask = nil
    }

    /// 单次 tick: 7 个 extractor 并发 → upsert → refresh aggregates
    private func tick() async {
        let rawEventsPerExtractor = await withTaskGroup(of: [TokenEvent].self) { group in
            for extractor in extractors {
                group.addTask { (try? extractor.extractAll()) ?? [] }
            }
            var all: [TokenEvent] = []
            for await events in group { all.append(contentsOf: events) }
            return all
        }

        for raw in rawEventsPerExtractor {
            try? await store.upsertEvent(raw)
        }

        try? await store.refreshMonthAggregates()
    }

    /// Manual tick trigger (for testing or on-demand refresh).
    func tickNow() async {
        await tick()
    }

    /// 当前月 provider 维度汇总 (UI consumption).
    func fetchMonthlyTotals() async -> [MonthlyTotal] {
        let aggs = await store.fetchMonthAggregates()
        return calc.calculateMonthlyTotals(aggs)
    }

    /// 单 provider 当前月 cost (UI consumption).
    func monthlyTotal(for provider: String) async -> MonthlyTotal? {
        let totals = await fetchMonthlyTotals()
        return totals.first { $0.provider == provider }
    }
}